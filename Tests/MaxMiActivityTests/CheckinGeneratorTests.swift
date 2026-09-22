import XCTest
@testable import MaxMiActivity
import MaxMiCore

private struct SavedCheckin: Sendable {
    let input: DailyCheckinInput
    let summary: String
    let dayBucket: Int64
    let nowMs: EpochMs
}

private struct RetryCall: Sendable {
    let dayBucket: Int64
    let nextAttemptAtMs: EpochMs
}

private actor CheckinGeneratorRepoState {
    private var checkins: [Int64: CheckinRecord]
    private var savedCheckins: [SavedCheckin] = []
    private var retryCallValues: [RetryCall] = []
    private var retryStates: [Int64: (attempts: Int, nextAttemptAtMs: EpochMs?)] = [:]
    private var retryStateReadBuckets: [Int64] = []

    init(existing: CheckinRecord?) {
        if let existing {
            checkins = [existing.dayBucket: existing]
        } else {
            checkins = [:]
        }
    }

    func currentCheckin(dayBucket: Int64) -> CheckinRecord? {
        checkins[dayBucket]
    }

    func save(_ value: SavedCheckin) {
        savedCheckins.append(value)
        checkins[value.dayBucket] = CheckinRecord(
            dayBucket: value.dayBucket,
            generatedAtMs: value.nowMs,
            summary: value.summary,
            openItemIDs: value.input.openItems.map(\.id),
            resolvedYesterdayCount: value.input.resolvedYesterdayCount,
            dismissedAtMs: nil,
            promptVersion: DailyCheckinGenerator.promptVersion
        )
    }

    func retryState(dayBucket: Int64) -> (attempts: Int, nextAttemptAtMs: EpochMs?) {
        retryStateReadBuckets.append(dayBucket)
        return retryStates[dayBucket] ?? (0, nil)
    }

    func recordRetry(dayBucket: Int64, nowMs: EpochMs) {
        let state = retryStates[dayBucket] ?? (0, nil)
        let delay = min(EpochMs(30_000 * (1 << min(state.attempts, 10))), 3_600_000)
        retryStates[dayBucket] = (state.attempts + 1, nowMs + delay)
        retryCallValues.append(.init(dayBucket: dayBucket, nextAttemptAtMs: nowMs + delay))
    }

    func clearRetry(dayBucket: Int64) {
        retryStates[dayBucket] = nil
    }

    func readSaved() -> [SavedCheckin] {
        savedCheckins
    }

    func readRetryCalls() -> [RetryCall] {
        retryCallValues
    }

    func readRetryStateBuckets() -> [Int64] {
        retryStateReadBuckets
    }
}

private final class CheckinGeneratorRepoMock: CheckinRepository, @unchecked Sendable {
    private let state: CheckinGeneratorRepoState

    init(existing: CheckinRecord? = nil) {
        state = CheckinGeneratorRepoState(existing: existing)
    }

    var saved: [SavedCheckin] {
        get async {
            await state.readSaved()
        }
    }

    var retryCalls: [RetryCall] {
        get async {
            await state.readRetryCalls()
        }
    }

    var retryStateBuckets: [Int64] {
        get async {
            await state.readRetryStateBuckets()
        }
    }

    func currentCheckin(dayBucket: Int64) async -> CheckinRecord? {
        await state.currentCheckin(dayBucket: dayBucket)
    }

    func openItems(limit: Int) async -> [CheckinOpenItem] {
        []
    }

    func resolvedYesterday(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) async -> (count: Int, titles: [String]) {
        (0, [])
    }

    func fallbackApps(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) async -> [CheckinFallbackApp] {
        []
    }

    func calendarEvents(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) async -> [CalendarEvent] {
        []
    }

    func save(
        input: DailyCheckinInput,
        summary: String,
        dayBucket: Int64,
        nowMs: EpochMs
    ) async throws {
        await state.save(.init(input: input, summary: summary, dayBucket: dayBucket, nowMs: nowMs))
    }

    func retryState(dayBucket: Int64) async -> (attempts: Int, nextAttemptAtMs: EpochMs?) {
        await state.retryState(dayBucket: dayBucket)
    }

    func recordRetry(dayBucket: Int64, nowMs: EpochMs) async {
        await state.recordRetry(dayBucket: dayBucket, nowMs: nowMs)
    }

    func clearRetry(dayBucket: Int64) async {
        await state.clearRetry(dayBucket: dayBucket)
    }

    func appVisits(fromMs: EpochMs, toMs: EpochMs)
        throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)] {
        []
    }

    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent] {
        []
    }

    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta] {
        [:]
    }
}

private actor CheckinRelayMock: CheckinGenerationRelay {
    private let result: Result<String, RelayError>
    private(set) var callCount = 0

    init(result: Result<String, RelayError>) {
        self.result = result
    }

    func generateCheckin(_ input: DailyCheckinInput) async throws -> String {
        callCount += 1
        return try result.get()
    }
}

private func builder(repo: any CheckinRepository) -> CheckinInputBuilder {
    let zone = TimeZone(identifier: "UTC")!
    return CheckinInputBuilder(
        repo: repo,
        timeZone: zone,
        dayBucket: { ms, _ in ms / 86_400_000 }
    )
}

private func storedCheckin(summary: String) -> CheckinRecord {
    CheckinRecord(
        dayBucket: 20_833,
        generatedAtMs: 1_800_000_000_000,
        summary: summary,
        openItemIDs: [],
        resolvedYesterdayCount: 0,
        dismissedAtMs: nil,
        promptVersion: DailyCheckinGenerator.promptVersion
    )
}

final class CheckinGeneratorTests: XCTestCase {
    func testFailureLeavesNoRowAndDefersRetryWithoutBlockingLaterCall() async {
        let repo = CheckinGeneratorRepoMock()
        let relay = CheckinRelayMock(result: .failure(RelayError.httpStatus(429)))
        let generator = DailyCheckinGenerator(repo: repo, relay: relay, builder: builder(repo: repo))

        await generator.generateIfMissing(nowMs: 1_800_000_000_000)
        await generator.generateIfMissing(nowMs: 1_800_000_001_000)

        let callCount = await relay.callCount
        let savedCount = await repo.saved.count
        let retryCalls = await repo.retryCalls
        let retryStateBuckets = await repo.retryStateBuckets
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(savedCount, 0)
        XCTAssertEqual(retryCalls.map(\.nextAttemptAtMs), [1_800_000_030_000])
        XCTAssertEqual(retryStateBuckets.last, retryCalls.last?.dayBucket)
    }

    func testSuccessfulGenerationIsNotRepeatedForSameDay() async {
        let repo = CheckinGeneratorRepoMock()
        let relay = CheckinRelayMock(result: .success("You should review the migration."))
        let generator = DailyCheckinGenerator(repo: repo, relay: relay, builder: builder(repo: repo))

        await generator.generateIfMissing(nowMs: 1_800_000_000_000)
        await generator.generateIfMissing(nowMs: 1_800_000_001_000)

        let callCount = await relay.callCount
        let saved = await repo.saved
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(saved.count, 1)
    }

    func testManualRegenerateOverwritesTodaysRow() async {
        let repo = CheckinGeneratorRepoMock(existing: storedCheckin(summary: "Old"))
        let relay = CheckinRelayMock(result: .success("You should review the migration."))
        let generator = DailyCheckinGenerator(repo: repo, relay: relay, builder: builder(repo: repo))

        await generator.regenerate(nowMs: 1_800_000_000_000)

        let saved = await repo.saved
        XCTAssertEqual(saved.last?.summary, "You should review the migration.")
    }

    func testRefusalOutputLeavesNoRowAndSchedulesRetry() async {
        let repo = CheckinGeneratorRepoMock()
        let relay = CheckinRelayMock(result: .success("I'm unable to create a check-in."))
        let generator = DailyCheckinGenerator(repo: repo, relay: relay, builder: builder(repo: repo))

        await generator.generateIfMissing(nowMs: 1_800_000_000_000)

        let saved = await repo.saved
        let retryCalls = await repo.retryCalls
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(retryCalls.map(\.nextAttemptAtMs), [1_800_000_030_000])
    }
}
