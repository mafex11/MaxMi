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
    private let existing: CheckinRecord?
    private var savedCheckins: [SavedCheckin] = []
    private var retryCallValues: [RetryCall] = []
    private var retryAttempts = 0
    private var retryDeadline: EpochMs?

    init(existing: CheckinRecord?) {
        self.existing = existing
    }

    func currentCheckin() -> CheckinRecord? {
        existing
    }

    func save(_ value: SavedCheckin) {
        savedCheckins.append(value)
    }

    func retryState() -> (attempts: Int, nextAttemptAtMs: EpochMs?) {
        (retryAttempts, retryDeadline)
    }

    func recordRetry(dayBucket: Int64, nowMs: EpochMs) {
        let delay = min(EpochMs(30_000 * (1 << min(retryAttempts, 10))), 3_600_000)
        retryAttempts += 1
        retryDeadline = nowMs + delay
        retryCallValues.append(.init(dayBucket: dayBucket, nextAttemptAtMs: nowMs + delay))
    }

    func clearRetry() {
        retryAttempts = 0
        retryDeadline = nil
    }

    func readSaved() -> [SavedCheckin] {
        savedCheckins
    }

    func readRetryCalls() -> [RetryCall] {
        retryCallValues
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

    func currentCheckin(dayBucket: Int64) async -> CheckinRecord? {
        await state.currentCheckin()
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
        await state.retryState()
    }

    func recordRetry(dayBucket: Int64, nowMs: EpochMs) async {
        await state.recordRetry(dayBucket: dayBucket, nowMs: nowMs)
    }

    func clearRetry(dayBucket: Int64) async {
        await state.clearRetry()
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
        clock: { 1_800_000_000_000 },
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
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(savedCount, 0)
        XCTAssertEqual(retryCalls.map(\.nextAttemptAtMs), [1_800_000_030_000])
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
