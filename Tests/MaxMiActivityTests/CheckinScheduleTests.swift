import XCTest
@testable import MaxMiActivity
import MaxMiCore

private actor CheckinTriggerProbeState {
    private var automaticCalls: [EpochMs] = []
    private var manualCalls: [EpochMs] = []
    private var hasCheckin = false
    private var captureTicks = 0
    private var blocksAutomaticGeneration = false
    private var generationStartedContinuation: CheckedContinuation<Void, Never>?
    private var generationReleaseContinuation: CheckedContinuation<Void, Never>?

    func automaticGenerationStarted(nowMs: EpochMs) async {
        automaticCalls.append(nowMs)
        hasCheckin = true
        generationStartedContinuation?.resume()
        generationStartedContinuation = nil
        guard blocksAutomaticGeneration else { return }
        await withCheckedContinuation { continuation in
            generationReleaseContinuation = continuation
        }
    }

    func manualGenerationStarted(nowMs: EpochMs) {
        manualCalls.append(nowMs)
    }

    func waitForAutomaticGenerationStart() async {
        if !automaticCalls.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            generationStartedContinuation = continuation
        }
    }

    func releaseAutomaticGeneration() {
        generationReleaseContinuation?.resume()
        generationReleaseContinuation = nil
    }

    func setHasCheckin(_ value: Bool) {
        hasCheckin = value
    }

    func setBlocksAutomaticGeneration(_ value: Bool) {
        blocksAutomaticGeneration = value
    }

    func checkinExists() -> Bool {
        hasCheckin
    }

    func recordCaptureTick() {
        captureTicks += 1
    }

    func readAutomaticCalls() -> [EpochMs] {
        automaticCalls
    }

    func readManualCalls() -> [EpochMs] {
        manualCalls
    }

    func readCaptureTicks() -> Int {
        captureTicks
    }
}

private actor CheckinTriggerProbe: CheckinGenerating {
    private let state: CheckinTriggerProbeState

    init(state: CheckinTriggerProbeState) {
        self.state = state
    }

    func hasCheckinForToday(nowMs: EpochMs) async -> Bool {
        await state.checkinExists()
    }

    func generateIfMissing(nowMs: EpochMs) async {
        await state.automaticGenerationStarted(nowMs: nowMs)
    }

    func regenerate(nowMs: EpochMs) async {
        await state.manualGenerationStarted(nowMs: nowMs)
    }
}

final class CheckinScheduleTests: XCTestCase {
    func testAutomaticCheckinStartsAtEightLocalOnlyWhenRowMissing() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let beforeDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 3, hour: 7, minute: 59, second: 59
        )))
        let atDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 3, hour: 8, minute: 0, second: 0
        )))
        let beforeEight = EpochMs(beforeDate.timeIntervalSince1970 * 1_000)
        let atEight = EpochMs(atDate.timeIntervalSince1970 * 1_000)

        XCTAssertFalse(CheckinSchedule.isAutomaticGenerationEligible(
            nowMs: beforeEight, timeZone: zone, hasCheckinForToday: false
        ))
        XCTAssertTrue(CheckinSchedule.isAutomaticGenerationEligible(
            nowMs: atEight, timeZone: zone, hasCheckinForToday: false
        ))
        XCTAssertFalse(CheckinSchedule.isAutomaticGenerationEligible(
            nowMs: atEight, timeZone: zone, hasCheckinForToday: true
        ))
    }

    func testTriggerSkipsAutomaticGenerationBeforeEightAndAfterTodayExists() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let state = CheckinTriggerProbeState()
        let generator = CheckinTriggerProbe(state: state)
        let trigger = CheckinTrigger(
            generator: generator,
            isActivitySynthesisEnabled: { true },
            timeZone: zone
        )
        let beforeEight = try localTimeMs(
            year: 2026, month: 9, day: 3, hour: 7, minute: 59, second: 59, timeZone: zone
        )
        let atEight = try localTimeMs(
            year: 2026, month: 9, day: 3, hour: 8, minute: 0, second: 0, timeZone: zone
        )

        await trigger.tick(nowMs: beforeEight)
        let beforeCalls = await state.readAutomaticCalls()
        XCTAssertTrue(beforeCalls.isEmpty)

        await state.setHasCheckin(true)
        await trigger.tick(nowMs: atEight)
        let existingCalls = await state.readAutomaticCalls()
        XCTAssertTrue(existingCalls.isEmpty)
    }

    func testTriggerGeneratesAtEightAtMostOnceAfterTheCheckinIsSaved() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let state = CheckinTriggerProbeState()
        let generator = CheckinTriggerProbe(state: state)
        let trigger = CheckinTrigger(
            generator: generator,
            isActivitySynthesisEnabled: { true },
            timeZone: zone
        )
        let atEight = try localTimeMs(
            year: 2026, month: 9, day: 3, hour: 8, minute: 0, second: 0, timeZone: zone
        )

        await trigger.tick(nowMs: atEight)
        await trigger.tick(nowMs: atEight + 30_000)

        let automaticCalls = await state.readAutomaticCalls()
        XCTAssertEqual(automaticCalls, [atEight])
    }

    func testTriggerSkipsAutomaticAndManualGenerationWhenActivitySynthesisIsDisabled() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let state = CheckinTriggerProbeState()
        let generator = CheckinTriggerProbe(state: state)
        let trigger = CheckinTrigger(
            generator: generator,
            isActivitySynthesisEnabled: { false },
            timeZone: zone
        )
        let atEight = try localTimeMs(
            year: 2026, month: 9, day: 3, hour: 8, minute: 0, second: 0, timeZone: zone
        )

        await trigger.tick(nowMs: atEight)
        await trigger.regenerateNow(nowMs: atEight)

        let automaticCalls = await state.readAutomaticCalls()
        let manualCalls = await state.readManualCalls()
        XCTAssertTrue(automaticCalls.isEmpty)
        XCTAssertTrue(manualCalls.isEmpty)
    }

    func testManualRegenerationBypassesAutomaticScheduleAndExistingRow() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let state = CheckinTriggerProbeState()
        await state.setHasCheckin(true)
        let generator = CheckinTriggerProbe(state: state)
        let trigger = CheckinTrigger(
            generator: generator,
            isActivitySynthesisEnabled: { true },
            timeZone: zone
        )
        let beforeEight = try localTimeMs(
            year: 2026, month: 9, day: 3, hour: 7, minute: 59, second: 59, timeZone: zone
        )

        await trigger.regenerateNow(nowMs: beforeEight)

        let manualCalls = await state.readManualCalls()
        XCTAssertEqual(manualCalls, [beforeEight])
    }

    func testDetachedAutomaticGenerationDoesNotBlockTheNextCaptureTick() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let state = CheckinTriggerProbeState()
        let generator = CheckinTriggerProbe(state: state)
        let trigger = CheckinTrigger(
            generator: generator,
            isActivitySynthesisEnabled: { true },
            timeZone: zone
        )
        let atEight = try localTimeMs(
            year: 2026, month: 9, day: 3, hour: 8, minute: 0, second: 0, timeZone: zone
        )
        await state.setBlocksAutomaticGeneration(true)

        let task = Task.detached {
            await trigger.tick(nowMs: atEight)
        }
        await state.waitForAutomaticGenerationStart()
        await state.recordCaptureTick()

        let captureTicks = await state.readCaptureTicks()
        XCTAssertEqual(captureTicks, 1)

        await state.releaseAutomaticGeneration()
        await task.value
    }

    private func localTimeMs(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        timeZone: TimeZone
    ) throws -> EpochMs {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
        return EpochMs(date.timeIntervalSince1970 * 1_000)
    }
}
