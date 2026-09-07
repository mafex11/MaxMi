import Foundation
import XCTest
@testable import MaxMiUI

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
    func testRefreshMapsReadyDismissedAndEmptyStates() async {
        let ready = CheckinDTO(
            dayBucket: 1, generatedAtMs: 100, summary: "You reviewed the migration.",
            dismissedAtMs: nil, isEmptySummary: false
        )
        let vm = CheckinViewModel(
            load: { ready }, dismiss: {}, regenerate: {},
            now: { 200 }, timeZone: .current
        )

        await vm.refresh()
        XCTAssertEqual(vm.state, .ready(summary: "You reviewed the migration.", generatedAtMs: 100))

        let dismissed = CheckinViewModel(
            load: {
                CheckinDTO(
                    dayBucket: 1, generatedAtMs: 100, summary: "Hidden",
                    dismissedAtMs: 101, isEmptySummary: false
                )
            },
            dismiss: {}, regenerate: {}, now: { 200 }, timeZone: .current
        )
        await dismissed.refresh()
        XCTAssertEqual(dismissed.state, .dismissed)

        let empty = CheckinViewModel(
            load: {
                CheckinDTO(
                    dayBucket: 1, generatedAtMs: 100, summary: "Nothing meaningful yesterday.",
                    dismissedAtMs: nil, isEmptySummary: true
                )
            },
            dismiss: {}, regenerate: {}, now: { 200 }, timeZone: .current
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
            load: { await state.load() },
            dismiss: { await state.dismiss() },
            regenerate: { try await state.regenerate() },
            now: { 200 }, timeZone: .current
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
}
