import Foundation
import XCTest
@testable import MaxMiUI
import MaxMiCore

private actor CheckinActionState {
    private var loadCount = 0
    private var didDismiss = false
    private var didRegenerate = false
    private var regenerateFailure = false

    func load() -> CheckinDTO? {
        loadCount += 1
        return nil
    }

    func dismiss() {
        didDismiss = true
    }

    func regenerate() throws {
        guard !regenerateFailure else {
            throw NSError(domain: "CheckinViewModelTests", code: 1)
        }
        didRegenerate = true
    }

    func setRegenerateFailure(_ value: Bool) {
        regenerateFailure = value
    }

    func readLoadCount() -> Int {
        loadCount
    }

    func readDidDismiss() -> Bool {
        didDismiss
    }

    func readDidRegenerate() -> Bool {
        didRegenerate
    }
}

@MainActor
final class CheckinViewModelTests: XCTestCase {
    private let fixedTimeZone = TimeZone(identifier: "Asia/Kolkata")!

    func testRefreshMapsReadyDismissedAndEmptyStates() async {
        let ready = CheckinDTO(
            dayBucket: 1, generatedAtMs: 100, summary: "You reviewed the migration.",
            dismissedAtMs: nil, isEmptySummary: false
        )
        let vm = CheckinViewModel(
            load: { _ in ready }, dismiss: { _, _ in }, regenerate: {},
            now: { 200 }, timeZone: fixedTimeZone
        )

        await vm.refresh()
        XCTAssertEqual(vm.state, .ready(summary: "You reviewed the migration.", generatedAtMs: 100))

        let dismissed = CheckinViewModel(
            load: { _ in
                CheckinDTO(
                    dayBucket: 1, generatedAtMs: 100, summary: "Hidden",
                    dismissedAtMs: 101, isEmptySummary: false
                )
            },
            dismiss: { _, _ in }, regenerate: {}, now: { 200 }, timeZone: fixedTimeZone
        )
        await dismissed.refresh()
        XCTAssertEqual(dismissed.state, .dismissed)

        let empty = CheckinViewModel(
            load: { _ in
                CheckinDTO(
                    dayBucket: 1, generatedAtMs: 100, summary: "Nothing meaningful yesterday.",
                    dismissedAtMs: nil, isEmptySummary: true
                )
            },
            dismiss: { _, _ in }, regenerate: {}, now: { 200 }, timeZone: fixedTimeZone
        )
        await empty.refresh()
        XCTAssertEqual(
            empty.state,
            .empty(summary: "Nothing meaningful yesterday.", generatedAtMs: 100)
        )
    }

    func testDismissAndRegenerateRefreshOnlyAfterSuccessfulActions() async {
        let state = CheckinActionState()
        let vm = CheckinViewModel(
            load: { _ in await state.load() },
            dismiss: { _, _ in await state.dismiss() },
            regenerate: { try await state.regenerate() },
            now: { 200 }, timeZone: fixedTimeZone
        )

        await vm.dismissToday()
        let didDismiss = await state.readDidDismiss()
        let loadCountAfterDismiss = await state.readLoadCount()
        XCTAssertTrue(didDismiss)
        XCTAssertEqual(loadCountAfterDismiss, 1)
        await vm.regenerateToday()
        let didRegenerate = await state.readDidRegenerate()
        let loadCountAfterRegenerate = await state.readLoadCount()
        XCTAssertTrue(didRegenerate)
        XCTAssertEqual(loadCountAfterRegenerate, 2)

        await state.setRegenerateFailure(true)
        await vm.regenerateToday()
        let loadCountAfterFailure = await state.readLoadCount()
        XCTAssertEqual(loadCountAfterFailure, 2)
    }

    func testLoadAndDismissUseTheSharedFixedZoneDayBucket() async {
        let state = CheckinBucketState()
        let nowMs: EpochMs = 1_800_000_000_000
        let timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let expectedBucket = ActivityTime.dayBucket(forMs: nowMs, timeZone: timeZone)
        let vm = CheckinViewModel(
            load: { bucket in
                await state.recordLoad(bucket)
                return nil
            },
            dismiss: { bucket, now in
                await state.recordDismiss(bucket: bucket, now: now)
            },
            regenerate: {},
            now: { nowMs },
            timeZone: timeZone
        )

        await vm.refresh()
        await vm.dismissToday()

        let loaded = await state.loadBuckets()
        let dismisses = await state.dismisses()
        XCTAssertEqual(loaded, [expectedBucket, expectedBucket])
        XCTAssertEqual(dismisses.count, 1)
        XCTAssertEqual(dismisses.first?.0, expectedBucket)
        XCTAssertEqual(dismisses.first?.1, nowMs)
    }
}

private actor CheckinBucketState {
    private var loaded: [Int64] = []
    private var dismissed: [(Int64, EpochMs)] = []

    func recordLoad(_ bucket: Int64) {
        loaded.append(bucket)
    }

    func recordDismiss(bucket: Int64, now: EpochMs) {
        dismissed.append((bucket, now))
    }

    func loadBuckets() -> [Int64] {
        loaded
    }

    func dismisses() -> [(Int64, EpochMs)] {
        dismissed
    }
}
