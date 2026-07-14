import Foundation
import MaxMiCore
import MaxMiStore

public struct RetrievalOptions: Sendable, Equatable {
    public var sourceApps: [String]
    public var source: String?
    public var contentKinds: [CaptureContentKind]
    public var lookbackMinutes: Int?
    public var startTime: String?
    public var endTime: String?
    public var cursor: String?
    public var timezone: String?
    public var threadID: String?

    public init(
        sourceApps: [String] = [],
        source: String? = nil,
        contentKinds: [CaptureContentKind] = [],
        lookbackMinutes: Int? = nil,
        startTime: String? = nil,
        endTime: String? = nil,
        cursor: String? = nil,
        timezone: String? = nil,
        threadID: String? = nil
    ) {
        self.sourceApps = sourceApps
        self.source = source
        self.contentKinds = contentKinds
        self.lookbackMinutes = lookbackMinutes
        self.startTime = startTime
        self.endTime = endTime
        self.cursor = cursor
        self.timezone = timezone
        self.threadID = threadID
    }

    static func parse(_ arguments: [String: Any]) -> Result<RetrievalOptions, RetrievalInputError> {
        let sourceApps: [String]
        if let values = arguments["source_apps"] as? [String] {
            sourceApps = values
        } else if let value = arguments["source_app"] as? String {
            sourceApps = [value]
        } else {
            sourceApps = []
        }
        let kinds: [CaptureContentKind]
        if let rawKinds = arguments["content_kinds"] as? [String] {
            kinds = rawKinds.compactMap(CaptureContentKind.init(rawValue:))
            if kinds.count != rawKinds.count {
                let valid = CaptureContentKind.allRetrievable.map(\.rawValue).joined(separator: ", ")
                return .failure(.message("content_kinds contains an unknown value; use: \(valid)"))
            }
        } else {
            kinds = []
        }
        return .success(RetrievalOptions(
            sourceApps: sourceApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            source: arguments["source"] as? String,
            contentKinds: kinds,
            lookbackMinutes: Self.intArg(arguments["lookback_minutes"]),
            startTime: arguments["start_time"] as? String,
            endTime: arguments["end_time"] as? String,
            cursor: arguments["cursor"] as? String,
            timezone: arguments["timezone"] as? String,
            threadID: arguments["thread_id"] as? String
        ))
    }

    func resolved(tool: String, query: String? = nil, now: Date) throws -> ResolvedRetrieval {
        if lookbackMinutes != nil && (startTime != nil || endTime != nil) {
            throw RetrievalInputError.message("lookback_minutes cannot be combined with start_time or end_time")
        }
        if let lookbackMinutes, lookbackMinutes <= 0 {
            throw RetrievalInputError.message("lookback_minutes must be greater than zero")
        }
        let zone: TimeZone
        if let timezone, !timezone.isEmpty {
            guard let parsed = TimeZone(identifier: timezone) else {
                throw RetrievalInputError.message("timezone must be a valid IANA identifier, for example Asia/Kolkata")
            }
            zone = parsed
        } else {
            zone = .current
        }

        let scope = ContentHash.sha256Hex(scopeMaterial(tool: tool, query: query))
        let decoded = try cursor.map(PageCursor.decode)
        if let decoded {
            guard decoded.version == 1, decoded.tool == tool, decoded.scope == scope else {
                throw RetrievalInputError.message("cursor does not belong to this tool/query/filter set")
            }
            guard decoded.offset >= 0 else { throw RetrievalInputError.message("cursor offset is invalid") }
        }
        let asOfMs = decoded?.asOfMs ?? EpochMs(now.timeIntervalSince1970 * 1000)
        let explicitStart = try startTime.map(Self.parseTimestamp)
        let explicitEnd = try endTime.map(Self.parseTimestamp)
        let startAtMs: EpochMs?
        if let lookbackMinutes {
            startAtMs = asOfMs - EpochMs(lookbackMinutes) * 60_000
        } else {
            startAtMs = explicitStart
        }
        let endAtMs = min(explicitEnd ?? asOfMs, asOfMs)
        if let startAtMs, startAtMs > endAtMs {
            throw RetrievalInputError.message("start_time must be earlier than end_time/as_of")
        }
        return ResolvedRetrieval(
            filter: RetrievalFilter(
                sourceApps: sourceApps,
                startAtMs: startAtMs,
                endAtMs: endAtMs,
                contentKinds: contentKinds
            ),
            offset: decoded?.offset ?? 0,
            asOfMs: asOfMs,
            timezone: zone,
            tool: tool,
            scope: scope
        )
    }

    private func scopeMaterial(tool: String, query: String?) -> String {
        [
            tool,
            query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            sourceApps.map { $0.lowercased() }.sorted().joined(separator: "\u{1f}"),
            source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            contentKinds.map(\.rawValue).sorted().joined(separator: "\u{1f}"),
            lookbackMinutes.map(String.init) ?? "",
            startTime ?? "",
            endTime ?? "",
            timezone ?? "",
            threadID ?? "",
        ].joined(separator: "\u{1e}")
    }

    private static func parseTimestamp(_ value: String) throws -> EpochMs {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) ?? fallback.date(from: value) else {
            throw RetrievalInputError.message("timestamps must be ISO-8601/RFC3339 with a timezone, for example 2026-07-14T09:30:00+05:30")
        }
        return EpochMs(date.timeIntervalSince1970 * 1000)
    }

    static func intArg(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? Double).map(Int.init) ?? (value as? NSNumber)?.intValue
    }
}

public struct ResolvedRetrieval: Sendable {
    public let filter: RetrievalFilter
    public let offset: Int
    public let asOfMs: EpochMs
    public let timezone: TimeZone
    let tool: String
    let scope: String

    func nextCursor(consumed: Int) -> String {
        PageCursor(version: 1, tool: tool, scope: scope, offset: offset + consumed, asOfMs: asOfMs).encoded()
    }
}

public enum RetrievalInputError: Error, Equatable, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        guard case .message(let message) = self else { return nil }
        return message
    }
}

private struct PageCursor: Codable {
    let version: Int
    let tool: String
    let scope: String
    let offset: Int
    let asOfMs: EpochMs

    func encoded() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String) throws -> PageCursor {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let cursor = try? JSONDecoder().decode(PageCursor.self, from: data) else {
            throw RetrievalInputError.message("cursor is malformed")
        }
        return cursor
    }
}

private extension CaptureContentKind {
    static var allRetrievable: [CaptureContentKind] {
        [.webpage, .conversation, .document, .terminal, .email, .calendar, .task, .meeting, .voiceNote, .generic]
    }
}

