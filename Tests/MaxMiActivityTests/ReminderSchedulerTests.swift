import XCTest
@testable import MaxMiActivity
import MaxMiCore

private actor ReminderSchedulerState {
    private var due: [ReminderItem] = []
    private var posted: [(String, String, String)] = []
    private var marked: [(String, EpochMs)] = []
    private var dueLookupCount = 0
    private var blocksDueLookup = false
    private var didStartLookup = false
    private var lookupStarted: CheckedContinuation<Void, Never>?
    private var lookupRelease: CheckedContinuation<Void, Never>?

    func setDue(_ items: [ReminderItem]) {
        due = items
    }

    func readDue(nowMs: EpochMs) async -> [ReminderItem] {
        _ = nowMs
        dueLookupCount += 1
        didStartLookup = true
        lookupStarted?.resume()
        lookupStarted = nil
        if blocksDueLookup {
            await withCheckedContinuation { lookupRelease = $0 }
        }
        let current = due
        due = []
        return current
    }

    func mark(id: String, nowMs: EpochMs) {
        marked.append((id, nowMs))
    }

    func post(id: String, title: String, body: String) {
        posted.append((id, title, body))
    }

    func setBlocksDueLookup(_ value: Bool) {
        blocksDueLookup = value
    }

    func waitForLookupStart() async {
        if didStartLookup {
            return
        }
        await withCheckedContinuation { lookupStarted = $0 }
    }

    func releaseLookup() {
        lookupRelease?.resume()
        lookupRelease = nil
    }

    func posts() -> [(String, String, String)] {
        posted
    }

    func marks() -> [(String, EpochMs)] {
        marked
    }

    func dueLookups() -> Int {
        dueLookupCount
    }
}

private struct ReminderSchedulerRepositoryFake: ReminderRepository {
    let state: ReminderSchedulerState

    func dueReminders(nowMs: EpochMs) async -> [ReminderItem] {
        await state.readDue(nowMs: nowMs)
    }

    func markReminded(_ id: String, nowMs: EpochMs) async {
        await state.mark(id: id, nowMs: nowMs)
    }
}

private struct ReminderSchedulerNotifierFake: ReminderNotifier {
    let state: ReminderSchedulerState

    func post(id: String, title: String, body: String) async {
        await state.post(id: id, title: title, body: body)
    }
}

final class ReminderSchedulerTests: XCTestCase {
    func testTickPostsOnceAndMarksReminderThenSecondTickDoesNothing() async {
        let state = ReminderSchedulerState()
        let nowMs: EpochMs = 1_800_000_000_000
        await state.setDue([
            ReminderItem(id: "r1", title: "Send report", sourceApp: "Mail", detectedAtMs: nowMs - 3 * 3_600_000),
        ])
        let scheduler = ReminderScheduler(
            repository: ReminderSchedulerRepositoryFake(state: state),
            notifier: ReminderSchedulerNotifierFake(state: state),
            isActivitySynthesisEnabled: { true },
            clock: { nowMs }
        )

        await scheduler.tick()
        await scheduler.tick()

        let posts = await state.posts()
        let marks = await state.marks()
        XCTAssertEqual(posts.map(\.0), ["r1"])
        XCTAssertEqual(posts.first?.1, "Send report")
        XCTAssertEqual(posts.first?.2, "Mail · 3h")
        XCTAssertEqual(marks.map(\.0), ["r1"])
        XCTAssertEqual(marks.map(\.1), [nowMs])
    }

    func testDeniedNotifierStillMarksReminder() async {
        let state = ReminderSchedulerState()
        let nowMs: EpochMs = 1_800_000_000_000
        await state.setDue([
            ReminderItem(id: "denied", title: "Review plan", sourceApp: nil, detectedAtMs: nowMs - 2 * 86_400_000),
        ])
        let scheduler = ReminderScheduler(
            repository: ReminderSchedulerRepositoryFake(state: state),
            notifier: DeniedReminderNotifier(),
            isActivitySynthesisEnabled: { true },
            clock: { nowMs }
        )

        await scheduler.tick()

        let marks = await state.marks()
        XCTAssertEqual(marks.map(\.0), ["denied"])
        XCTAssertEqual(marks.map(\.1), [nowMs])
    }

    func testDisabledSynthesisDoesNoRepositoryOrNotifierWork() async {
        let state = ReminderSchedulerState()
        let scheduler = ReminderScheduler(
            repository: ReminderSchedulerRepositoryFake(state: state),
            notifier: ReminderSchedulerNotifierFake(state: state),
            isActivitySynthesisEnabled: { false },
            clock: { 1 }
        )

        await scheduler.tick()

        let posts = await state.posts()
        let marks = await state.marks()
        let dueLookups = await state.dueLookups()
        XCTAssertTrue(posts.isEmpty)
        XCTAssertTrue(marks.isEmpty)
        XCTAssertEqual(dueLookups, 0)
    }

    func testInFlightGuardRejectsConcurrentTicks() async {
        let state = ReminderSchedulerState()
        await state.setBlocksDueLookup(true)
        await state.setDue([
            ReminderItem(id: "one", title: "One", sourceApp: "MaxMi", detectedAtMs: 0),
        ])
        let scheduler = ReminderScheduler(
            repository: ReminderSchedulerRepositoryFake(state: state),
            notifier: ReminderSchedulerNotifierFake(state: state),
            isActivitySynthesisEnabled: { true },
            clock: { 10 }
        )

        async let first: Void = scheduler.tick()
        await state.waitForLookupStart()
        async let second: Void = scheduler.tick()
        await Task.yield()
        await state.releaseLookup()
        await first
        await second

        let posts = await state.posts()
        XCTAssertEqual(posts.map(\.0), ["one"])
    }
}

private struct DeniedReminderNotifier: ReminderNotifier {
    func post(id: String, title: String, body: String) async {
        _ = id
        _ = title
        _ = body
    }
}
