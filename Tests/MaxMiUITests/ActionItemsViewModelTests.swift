import XCTest
@testable import MaxMiUI

@MainActor
final class ActionItemsViewModelTests: XCTestCase {
    func testRefreshLoadsItems() async {
        let vm = ActionItemsViewModel(
            load: { @Sendable in
                let open = [
                    ActionItemDTO(id: "1", title: "Task 1", details: "Details 1", status: "open", timeAgo: "5m ago"),
                    ActionItemDTO(id: "2", title: "Task 2", details: nil, status: "open", timeAgo: "10m ago")
                ]
                let archived = [
                    ActionItemDTO(id: "3", title: "Task 3", details: "Old", status: "resolved", timeAgo: "1h ago")
                ]
                return (open: open, archived: archived)
            },
            onResolve: { _ in },
            onDismiss: { _ in },
        )

        await vm.refresh()

        XCTAssertEqual(vm.open.count, 2)
        XCTAssertEqual(vm.open[0].id, "1")
        XCTAssertEqual(vm.archived.count, 1)
        XCTAssertEqual(vm.archived[0].id, "3")
    }

    func testResolveCallsOnResolveAndRefreshesOnSuccess() async {
        actor TestState {
            var resolveCalled = false
            var refreshCount = 0

            func markResolved() { resolveCalled = true }
            func incrementRefresh() -> Int {
                refreshCount += 1
                return refreshCount
            }
            func getRefreshCount() -> Int { refreshCount }
            func isResolved() -> Bool { resolveCalled }
        }

        let state = TestState()

        let vm = ActionItemsViewModel(
            load: { @Sendable in
                let count = await state.incrementRefresh()
                if count == 1 {
                    return (
                        open: [ActionItemDTO(id: "1", title: "Task", details: nil, status: "open", timeAgo: "5m")],
                        archived: []
                    )
                } else {
                    return (open: [], archived: [])
                }
            },
            onResolve: { @Sendable id in
                XCTAssertEqual(id, "1")
                await state.markResolved()
            },
            onDismiss: { _ in },
        )

        await vm.refresh()
        XCTAssertEqual(vm.open.count, 1)

        await vm.resolve("1")

        let resolved = await state.isResolved()
        let refreshCount = await state.getRefreshCount()
        XCTAssertTrue(resolved)
        XCTAssertEqual(refreshCount, 2, "Should refresh after successful resolve")
        XCTAssertEqual(vm.open.count, 0, "Item removed only after refresh")
    }

    func testResolveFailureKeepsItem() async {
        actor TestState {
            var refreshCount = 0
            func incrementRefresh() { refreshCount += 1 }
            func getRefreshCount() -> Int { refreshCount }
        }

        let state = TestState()

        let vm = ActionItemsViewModel(
            load: { @Sendable in
                await state.incrementRefresh()
                return (
                    open: [ActionItemDTO(id: "1", title: "Task", details: nil, status: "open", timeAgo: "5m")],
                    archived: []
                )
            },
            onResolve: { @Sendable _ in
                throw NSError(domain: "test", code: 1)
            },
            onDismiss: { _ in },
        )

        await vm.refresh()
        XCTAssertEqual(vm.open.count, 1)

        var count = await state.getRefreshCount()
        XCTAssertEqual(count, 1)

        await vm.resolve("1")

        count = await state.getRefreshCount()
        XCTAssertEqual(count, 1, "Should not refresh after failed resolve")
        XCTAssertEqual(vm.open.count, 1, "Item stays on failure")
    }

    func testDismissCallsOnDismissAndRefreshesOnSuccess() async {
        actor TestState {
            var dismissCalled = false
            var refreshCount = 0

            func markDismissed() { dismissCalled = true }
            func incrementRefresh() -> Int {
                refreshCount += 1
                return refreshCount
            }
            func getRefreshCount() -> Int { refreshCount }
            func isDismissed() -> Bool { dismissCalled }
        }

        let state = TestState()

        let vm = ActionItemsViewModel(
            load: { @Sendable in
                let count = await state.incrementRefresh()
                if count == 1 {
                    return (
                        open: [ActionItemDTO(id: "1", title: "Task", details: nil, status: "open", timeAgo: "5m")],
                        archived: []
                    )
                } else {
                    return (open: [], archived: [])
                }
            },
            onResolve: { _ in },
            onDismiss: { @Sendable id in
                XCTAssertEqual(id, "1")
                await state.markDismissed()
            },
        )

        await vm.refresh()
        XCTAssertEqual(vm.open.count, 1)

        await vm.dismiss("1")

        let dismissed = await state.isDismissed()
        let refreshCount = await state.getRefreshCount()
        XCTAssertTrue(dismissed)
        XCTAssertEqual(refreshCount, 2, "Should refresh after successful dismiss")
        XCTAssertEqual(vm.open.count, 0, "Item removed only after refresh")
    }

    func testDismissFailureKeepsItem() async {
        actor TestState {
            var refreshCount = 0
            func incrementRefresh() { refreshCount += 1 }
            func getRefreshCount() -> Int { refreshCount }
        }

        let state = TestState()

        let vm = ActionItemsViewModel(
            load: { @Sendable in
                await state.incrementRefresh()
                return (
                    open: [ActionItemDTO(id: "1", title: "Task", details: nil, status: "open", timeAgo: "5m")],
                    archived: []
                )
            },
            onResolve: { _ in },
            onDismiss: { @Sendable _ in
                throw NSError(domain: "test", code: 1)
            },
        )

        await vm.refresh()
        XCTAssertEqual(vm.open.count, 1)

        var count = await state.getRefreshCount()
        XCTAssertEqual(count, 1)

        await vm.dismiss("1")

        count = await state.getRefreshCount()
        XCTAssertEqual(count, 1, "Should not refresh after failed dismiss")
        XCTAssertEqual(vm.open.count, 1, "Item stays on failure")
    }
}
