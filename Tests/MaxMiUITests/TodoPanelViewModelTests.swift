import XCTest
@testable import MaxMiUI
import MaxMiCore

private actor TodoPanelRepositoryState {
    private var items: [TodoPanelItem]
    private var doneIDs: [String] = []
    private var dismissedIDs: [String] = []
    private let checkinLine: String?

    init(items: [TodoPanelItem], checkinLine: String?) {
        self.items = items
        self.checkinLine = checkinLine
    }

    func openItems() -> [TodoPanelItem] {
        items
    }

    func checkin() -> String? {
        checkinLine
    }

    func markDone(_ id: String) {
        doneIDs.append(id)
        items.removeAll { $0.id == id }
    }

    func dismiss(_ id: String) {
        dismissedIDs.append(id)
        items.removeAll { $0.id == id }
    }

    func reads() -> (done: [String], dismissed: [String]) {
        (doneIDs, dismissedIDs)
    }
}

private struct TodoPanelRepositoryFake: TodoPanelRepository {
    let state: TodoPanelRepositoryState

    func openItems(limit: Int) async -> [TodoPanelItem] {
        let ordered = await state.openItems().sorted {
            $0.detectedAtMs == $1.detectedAtMs ? $0.id > $1.id : $0.detectedAtMs > $1.detectedAtMs
        }
        return Array(ordered.prefix(limit))
    }

    func todayCheckinFirstLine(nowMs: EpochMs) async -> String? {
        _ = nowMs
        return await state.checkin()
    }

    func markDone(id: String, nowMs: EpochMs) async {
        _ = nowMs
        await state.markDone(id)
    }

    func dismiss(id: String, nowMs: EpochMs) async {
        _ = nowMs
        await state.dismiss(id)
    }
}

@MainActor
final class TodoPanelViewModelTests: XCTestCase {
    func testRefreshOrdersNewestFirstAndCapsAtTwentyFive() async {
        let items = (0..<30).map { offset in
            TodoPanelItem(
                id: "item-\(offset)",
                title: "Item \(offset)",
                details: nil,
                sourceApp: "Fixture",
                detectedAtMs: EpochMs(offset),
                remindAtMs: nil,
                remindedAtMs: nil
            )
        }
        let state = TodoPanelRepositoryState(items: items.shuffled(), checkinLine: nil)
        let viewModel = TodoPanelViewModel(
            repository: TodoPanelRepositoryFake(state: state),
            now: { 10_000 }
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.items.count, TodoPanelViewModel.openItemLimit)
        XCTAssertEqual(viewModel.items.map(\.id), (5..<30).reversed().map { "item-\($0)" })
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testDoneAndDismissCallRepositoryAndRemoveRows() async {
        let state = TodoPanelRepositoryState(
            items: [
                item(id: "first", detectedAtMs: 2),
                item(id: "second", detectedAtMs: 1),
            ],
            checkinLine: nil
        )
        let viewModel = TodoPanelViewModel(
            repository: TodoPanelRepositoryFake(state: state),
            now: { 100 }
        )
        await viewModel.refresh()

        await viewModel.markSelectedDone()
        viewModel.moveSelection(by: 1)
        await viewModel.dismissSelected()

        let calls = await state.reads()
        XCTAssertEqual(calls.done, ["first"])
        XCTAssertEqual(calls.dismissed, ["second"])
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertNil(viewModel.selectedIndex)
    }

    func testKeyboardSelectionWrapsInBothDirections() async {
        let state = TodoPanelRepositoryState(
            items: [item(id: "one", detectedAtMs: 3), item(id: "two", detectedAtMs: 2), item(id: "three", detectedAtMs: 1)],
            checkinLine: nil
        )
        let viewModel = TodoPanelViewModel(
            repository: TodoPanelRepositoryFake(state: state),
            now: { 1 }
        )
        await viewModel.refresh()

        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.selectedIndex, 2)
        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testRefreshExposesEmptyStateAndCheckinHeaderLine() async {
        let emptyState = TodoPanelRepositoryState(items: [], checkinLine: "You reviewed the release plan.")
        let emptyViewModel = TodoPanelViewModel(
            repository: TodoPanelRepositoryFake(state: emptyState),
            now: { 50 }
        )
        await emptyViewModel.refresh()

        XCTAssertTrue(emptyViewModel.items.isEmpty)
        XCTAssertNil(emptyViewModel.selectedIndex)
        XCTAssertEqual(emptyViewModel.checkinFirstLine, "You reviewed the release plan.")
    }

    private func item(id: String, detectedAtMs: EpochMs) -> TodoPanelItem {
        TodoPanelItem(
            id: id,
            title: id,
            details: nil,
            sourceApp: "Fixture",
            detectedAtMs: detectedAtMs,
            remindAtMs: nil,
            remindedAtMs: nil
        )
    }
}
