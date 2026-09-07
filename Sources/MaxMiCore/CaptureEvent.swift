import Foundation

/// What kind of thing happened. The raw values are the `capture_events.kind` CHECK constraint's
/// vocabulary, so they must match the migration exactly.
public enum CaptureEventKind: String, Sendable, Codable, CaseIterable {
    case focus = "focus"
    case navigation = "navigation"
    case contentDelta = "content_delta"
    case typing = "typing"
    case dialog = "dialog"
}

/// Encrypted like every other payload: a window title is content.
public struct FocusEventPayload: Codable, Sendable, Equatable {
    public let bundleID: String
    public let appLabel: String
    public let windowTitle: String?

    public init(bundleID: String, appLabel: String, windowTitle: String?) {
        self.bundleID = bundleID
        self.appLabel = appLabel
        self.windowTitle = windowTitle
    }
}

public struct NavigationEventPayload: Codable, Sendable, Equatable {
    /// nil for the first capture of a thread — there is no previous URL to report.
    public let fromURL: String?
    public let toURL: String

    public init(fromURL: String?, toURL: String) {
        self.fromURL = fromURL
        self.toURL = toURL
    }

    private enum CodingKeys: String, CodingKey {
        case fromURL
        case toURL
        case oldURL
        case newURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fromURL = try container.decodeIfPresent(String.self, forKey: .fromURL)
            ?? container.decodeIfPresent(String.self, forKey: .oldURL)
        guard let toURL = try container.decodeIfPresent(String.self, forKey: .toURL)
            ?? container.decodeIfPresent(String.self, forKey: .newURL) else {
            throw DecodingError.keyNotFound(
                CodingKeys.toURL,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Expected toURL or newURL"
                )
            )
        }
        self.toURL = toURL
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fromURL, forKey: .fromURL)
        try container.encode(toURL, forKey: .toURL)
    }
}

/// One meaningful change to the focused field's value. Produced by `TypingObserver`
/// (`MaxMiCapture`), stored as a `typing` event, and read back by `TimelineBuilder`
/// (`MaxMiActivity`) — which is why it lives here rather than next to the observer.
public struct TypingEvent: Codable, Sendable, Equatable {
    /// The inserted run's trailing `TypingObserver.maxReplacedTailChars` characters when
    /// `replaced == false`; the new value's trailing same-sized tail when `replaced == true`.
    public let insertedText: String
    public let fieldRole: String
    public let fieldIdentifier: String?
    /// Character count of the field's whole value after the change.
    public let totalLength: Int
    /// True when the change was not a pure insertion — paste, replace, select-all-retype, clear.
    public let replaced: Bool

    public init(insertedText: String, fieldRole: String, fieldIdentifier: String?,
                totalLength: Int, replaced: Bool) {
        self.insertedText = insertedText
        self.fieldRole = fieldRole
        self.fieldIdentifier = fieldIdentifier
        self.totalLength = totalLength
        self.replaced = replaced
    }
}

public struct DialogEventPayload: Codable, Sendable, Equatable {
    public let blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// Whole blocks from the front, until the rendered form would exceed
    /// `CaptureEventRetention.dialogPayloadCap`. The first block is always kept: a dialog whose
    /// single block is longer than the cap must still say what it was.
    public static func capped(_ blocks: [Block]) -> [Block] {
        var kept: [Block] = []
        var used = 0
        for block in blocks {
            let cost = ContentRenderer.renderBlock(block).count + (kept.isEmpty ? 0 : 1)
            if !kept.isEmpty, used + cost > CaptureEventRetention.dialogPayloadCap { break }
            kept.append(block)
            used += cost
        }
        return kept
    }
}

/// MaxMi's only automatic age-based deletion (spec 12 Q5). Thirty days because events are
/// derived signals rather than memories, and the Activity window may look back a month. Memory
/// retention itself is unchanged — still Forever by default.
public enum CaptureEventRetention {
    public static let days = 30
    /// The trim runs at most this often, so a capture does not pay for a DELETE.
    public static let trimIntervalMs: EpochMs = 3_600_000
    public static let lastTrimSettingsKey = "capture_events_last_trim_at"
    /// Rendered-character cap on a `dialog` payload.
    public static let dialogPayloadCap = 1_000

    public static func cutoffMs(nowMs: EpochMs) -> EpochMs {
        nowMs - EpochMs(days) * 86_400_000
    }
}
