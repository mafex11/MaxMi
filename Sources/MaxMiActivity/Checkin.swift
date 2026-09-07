import Foundation
import MaxMiCore

public struct CheckinRecord: Sendable, Equatable {
    public let dayBucket: Int64
    public let generatedAtMs: EpochMs
    public let summary: String?
    public let openItemIDs: [String]
    public let resolvedYesterdayCount: Int
    public let dismissedAtMs: EpochMs?
    public let promptVersion: String

    public init(
        dayBucket: Int64,
        generatedAtMs: EpochMs,
        summary: String?,
        openItemIDs: [String],
        resolvedYesterdayCount: Int,
        dismissedAtMs: EpochMs?,
        promptVersion: String
    ) {
        self.dayBucket = dayBucket
        self.generatedAtMs = generatedAtMs
        self.summary = summary
        self.openItemIDs = openItemIDs
        self.resolvedYesterdayCount = resolvedYesterdayCount
        self.dismissedAtMs = dismissedAtMs
        self.promptVersion = promptVersion
    }
}

public struct CheckinOpenItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let details: String?
    public let sourceApp: String?
    public let ageDays: Int

    public init(id: String, title: String, details: String?, sourceApp: String?, ageDays: Int) {
        self.id = id
        self.title = title
        self.details = details
        self.sourceApp = sourceApp
        self.ageDays = ageDays
    }
}

public struct CheckinFallbackApp: Sendable, Equatable {
    public let appLabel: String
    public let sourceTitle: String?

    public init(appLabel: String, sourceTitle: String?) {
        self.appLabel = appLabel
        self.sourceTitle = sourceTitle
    }
}

public struct DailyCheckinInput: Sendable, Equatable {
    public let localDate: String
    public let weekday: String
    public let yesterdayTimeline: String
    public let fallbackApps: [CheckinFallbackApp]
    public let openItems: [CheckinOpenItem]
    public let resolvedYesterdayCount: Int
    public let resolvedYesterdayTitles: [String]
    public let calendarEvents: [CalendarEvent]

    public init(
        localDate: String,
        weekday: String,
        yesterdayTimeline: String,
        fallbackApps: [CheckinFallbackApp],
        openItems: [CheckinOpenItem],
        resolvedYesterdayCount: Int,
        resolvedYesterdayTitles: [String],
        calendarEvents: [CalendarEvent]
    ) {
        self.localDate = localDate
        self.weekday = weekday
        self.yesterdayTimeline = yesterdayTimeline
        self.fallbackApps = fallbackApps
        self.openItems = openItems
        self.resolvedYesterdayCount = resolvedYesterdayCount
        self.resolvedYesterdayTitles = resolvedYesterdayTitles
        self.calendarEvents = calendarEvents
    }
}

public protocol CheckinRepository: TimelineRepository {
    func currentCheckin(dayBucket: Int64) async -> CheckinRecord?
    func openItems(limit: Int) async -> [CheckinOpenItem]
    func resolvedYesterday(fromMs: EpochMs, toMs: EpochMs, limit: Int) async
        -> (count: Int, titles: [String])
    func fallbackApps(fromMs: EpochMs, toMs: EpochMs, limit: Int) async -> [CheckinFallbackApp]
    func calendarEvents(fromMs: EpochMs, toMs: EpochMs, limit: Int) async -> [CalendarEvent]
    func save(input: DailyCheckinInput, summary: String, dayBucket: Int64, nowMs: EpochMs) async throws
    func retryState(dayBucket: Int64) async -> (attempts: Int, nextAttemptAtMs: EpochMs?)
    func recordRetry(dayBucket: Int64, nowMs: EpochMs) async
    func clearRetry(dayBucket: Int64) async
}

public protocol CheckinGenerationRelay: Sendable {
    func generateCheckin(_ input: DailyCheckinInput) async throws -> String
}

public enum CheckinInputBuildError: Error, Sendable {
    case yesterdayBoundaryUnavailable
}

public struct CheckinInputBuilder: Sendable {
    private let repo: any CheckinRepository
    private let clock: @Sendable () -> EpochMs
    private let timeZone: TimeZone
    private let dayBucket: @Sendable (EpochMs, TimeZone) -> Int64

    public init(
        repo: any CheckinRepository,
        clock: @escaping @Sendable () -> EpochMs,
        timeZone: TimeZone,
        dayBucket: @escaping @Sendable (EpochMs, TimeZone) -> Int64
    ) {
        self.repo = repo
        self.clock = clock
        self.timeZone = timeZone
        self.dayBucket = dayBucket
    }

    public func build(nowMs: EpochMs) async throws -> (dayBucket: Int64, input: DailyCheckinInput) {
        let effectiveNowMs = nowMs
        let now = Date(timeIntervalSince1970: Double(effectiveNowMs) / 1_000)
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let todayStart = calendar.startOfDay(for: now)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else {
            throw CheckinInputBuildError.yesterdayBoundaryUnavailable
        }
        let todayStartMs = EpochMs(todayStart.timeIntervalSince1970 * 1_000)
        let yesterdayFromMs = EpochMs(yesterdayStart.timeIntervalSince1970 * 1_000)
        let yesterdayToMs = todayStartMs - 1
        let todayBucket = dayBucket(effectiveNowMs, timeZone)
        let timeline = try? TimelineBuilder(repo: repo).build(
            fromMs: yesterdayFromMs,
            toMs: yesterdayToMs
        )
        let timelineText = timeline.map { TimelineBuilder.render($0, budgetChars: 2_500) } ?? ""
        let resolved = await repo.resolvedYesterday(
            fromMs: yesterdayFromMs,
            toMs: yesterdayToMs,
            limit: 10
        )
        let fallbackApps: [CheckinFallbackApp]
        if timelineText.isEmpty {
            fallbackApps = await repo.fallbackApps(
                fromMs: yesterdayFromMs,
                toMs: yesterdayToMs,
                limit: 5
            )
        } else {
            fallbackApps = []
        }
        let openItems = Array((await repo.openItems(limit: 15)).prefix(15))
        let calendarEvents = Array((await repo.calendarEvents(
            fromMs: todayStartMs,
            toMs: effectiveNowMs,
            limit: 8
        )).prefix(8))
        let weekdayFormatter = DateFormatter()
        let dateFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.timeZone = timeZone
        weekdayFormatter.dateFormat = "EEEE"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .medium
        return (
            todayBucket,
            DailyCheckinInput(
                localDate: dateFormatter.string(from: now),
                weekday: weekdayFormatter.string(from: now),
                yesterdayTimeline: timelineText,
                fallbackApps: fallbackApps,
                openItems: openItems,
                resolvedYesterdayCount: resolved.count,
                resolvedYesterdayTitles: Array(resolved.titles.prefix(10)),
                calendarEvents: calendarEvents
            )
        )
    }
}

private enum CheckinGenerationError: Error {
    case refusalOrEmptyResponse
}

public actor DailyCheckinGenerator {
    public static let promptVersion = "checkin-v1"

    private let repo: any CheckinRepository
    private let relay: any CheckinGenerationRelay
    private let builder: CheckinInputBuilder
    private let timeZone: TimeZone

    public init(
        repo: any CheckinRepository,
        relay: any CheckinGenerationRelay,
        builder: CheckinInputBuilder,
        timeZone: TimeZone = .current
    ) {
        self.repo = repo
        self.relay = relay
        self.builder = builder
        self.timeZone = timeZone
    }

    public func generateIfMissing(nowMs: EpochMs) async {
        let dayBucket = localDayBucket(nowMs: nowMs)
        guard await repo.currentCheckin(dayBucket: dayBucket) == nil else { return }

        let retryState = await repo.retryState(dayBucket: dayBucket)
        if let nextAttemptAtMs = retryState.nextAttemptAtMs, nextAttemptAtMs > nowMs {
            return
        }

        await generate(nowMs: nowMs)
    }

    public func regenerate(nowMs: EpochMs) async {
        await generate(nowMs: nowMs)
    }

    public static func normalizedModelText(_ response: String, maxWords: Int = 90) -> String {
        var wordsRemaining = maxWords
        let lines = response.split(whereSeparator: \.isNewline).prefix(6).compactMap { rawLine -> String? in
            guard wordsRemaining > 0 else { return nil }
            let words = rawLine.split(whereSeparator: \.isWhitespace).prefix(wordsRemaining)
            guard !words.isEmpty else { return nil }
            wordsRemaining -= words.count
            return words.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }

    private func generate(nowMs: EpochMs) async {
        let built: (dayBucket: Int64, input: DailyCheckinInput)
        do {
            built = try await builder.build(nowMs: nowMs)
        } catch is CheckinInputBuildError {
            logFailure(operation: "checkin_input_failed")
            return
        } catch {
            logFailure(operation: "checkin_input_failed")
            return
        }

        do {
            let response = try await relay.generateCheckin(built.input)
            guard !Self.isRefusalOrEmpty(response) else {
                throw CheckinGenerationError.refusalOrEmptyResponse
            }
            let summary = Self.normalizedModelText(response)
            guard !summary.isEmpty else {
                throw CheckinGenerationError.refusalOrEmptyResponse
            }
            try await repo.save(
                input: built.input,
                summary: summary,
                dayBucket: built.dayBucket,
                nowMs: nowMs
            )
            await repo.clearRetry(dayBucket: built.dayBucket)
        } catch {
            logFailure(operation: "checkin_generation_failed")
            await repo.recordRetry(dayBucket: built.dayBucket, nowMs: nowMs)
        }
    }

    private func localDayBucket(nowMs: EpochMs) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(nowMs) / 1_000)
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return EpochMs(calendar.startOfDay(for: date).timeIntervalSince1970 * 1_000)
    }

    private static func isRefusalOrEmpty(_ response: String) -> Bool {
        guard response.rangeOfCharacter(from: .letters) != nil else { return true }
        let refusalPhrases = [
            "I can't",
            "I cannot",
            "I'm unable",
            "I am unable",
            "as an AI",
            "I'm sorry",
            "I am sorry",
        ]
        return refusalPhrases.contains {
            response.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    private func logFailure(operation: String) {
        SafeLogger.shared.log(
            .error,
            subsystem: .agent,
            event: .agentRunFailed,
            fields: SafeLogFields(operation: SafeLogToken(validating: operation))
        )
    }
}
