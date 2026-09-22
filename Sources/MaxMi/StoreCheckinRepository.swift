import Foundation
import MaxMiActivity
import MaxMiCore
import MaxMiStore

struct StoreCheckinRepository: CheckinRepository, @unchecked Sendable {
    let store: Store
    private let timelineRepository: StoreTimelineRepository
    private let clock: @Sendable () -> EpochMs
    private let timeZone: TimeZone

    init(
        store: Store,
        clock: @escaping @Sendable () -> EpochMs = epochNowMs,
        timeZone: TimeZone = .current
    ) {
        self.store = store
        timelineRepository = StoreTimelineRepository(store: store)
        self.clock = clock
        self.timeZone = timeZone
    }

    func currentCheckin(dayBucket: Int64) async -> CheckinRecord? {
        do {
            guard let checkin = try store.checkin(dayBucket: dayBucket) else { return nil }
            return CheckinRecord(
                dayBucket: checkin.dayBucket,
                generatedAtMs: checkin.generatedAtMs,
                summary: checkin.summary,
                openItemIDs: checkin.openItemIDs,
                resolvedYesterdayCount: checkin.resolvedYesterdayCount,
                dismissedAtMs: checkin.dismissedAtMs,
                promptVersion: checkin.promptVersion
            )
        } catch {
            return nil
        }
    }

    func openItems(limit: Int) async -> [CheckinOpenItem] {
        do {
            return try store.openCheckinItems(limit: limit).map { item in
                CheckinOpenItem(
                    id: item.id,
                    title: item.title,
                    details: item.details,
                    sourceApp: item.sourceApp,
                    ageDays: ageDays(detectedAtMs: item.detectedAtMs)
                )
            }
        } catch {
            return []
        }
    }

    func resolvedYesterday(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) async -> (count: Int, titles: [String]) {
        do {
            return try store.resolvedCheckinItems(fromMs: fromMs, toMs: toMs, limit: limit)
        } catch {
            return (0, [])
        }
    }

    func fallbackApps(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) async -> [CheckinFallbackApp] {
        do {
            return try store.checkinTopApps(fromMs: fromMs, toMs: toMs, limit: limit).map {
                CheckinFallbackApp(appLabel: $0.appLabel, sourceTitle: $0.sourceTitle)
            }
        } catch {
            return []
        }
    }

    func calendarEvents(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) async -> [CalendarEvent] {
        do {
            return try store.checkinCalendarCaptures(fromMs: fromMs, toMs: toMs, limit: limit)
        } catch {
            return []
        }
    }

    func save(
        input: DailyCheckinInput,
        summary: String,
        dayBucket: Int64,
        nowMs: EpochMs
    ) async throws {
        try store.saveCheckin(
            dayBucket: dayBucket,
            generatedAtMs: nowMs,
            summary: summary,
            openItemIDs: input.openItems.map(\.id),
            resolvedYesterdayCount: input.resolvedYesterdayCount,
            promptVersion: DailyCheckinGenerator.promptVersion
        )
    }

    func retryState(dayBucket: Int64) async -> (attempts: Int, nextAttemptAtMs: EpochMs?) {
        do {
            return try store.checkinRetryState(dayBucket: dayBucket)
        } catch {
            return (0, nil)
        }
    }

    func recordRetry(dayBucket: Int64, nowMs: EpochMs) async {
        try? store.recordCheckinRetry(dayBucket: dayBucket, nowMs: nowMs)
    }

    func clearRetry(dayBucket: Int64) async {
        try? store.clearCheckinRetry(dayBucket: dayBucket)
    }

    func appVisits(fromMs: EpochMs, toMs: EpochMs)
        throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)] {
        try timelineRepository.appVisits(fromMs: fromMs, toMs: toMs)
    }

    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent] {
        try timelineRepository.captureEvents(fromMs: fromMs, toMs: toMs)
    }

    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta] {
        try timelineRepository.threadMetadata(threadIDs: threadIDs)
    }

    private func ageDays(detectedAtMs: EpochMs) -> Int {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let detectedAt = Date(timeIntervalSince1970: Double(detectedAtMs) / 1_000)
        let now = Date(timeIntervalSince1970: Double(clock()) / 1_000)
        let detectedDay = calendar.startOfDay(for: detectedAt)
        let currentDay = calendar.startOfDay(for: now)
        return max(0, calendar.dateComponents([.day], from: detectedDay, to: currentDay).day ?? 0)
    }
}
