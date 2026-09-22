import MaxMiCore
import Observation

@MainActor
@Observable
public final class TodoPanelViewModel {
    public static let openItemLimit = 25

    public private(set) var items: [TodoPanelItem] = []
    public private(set) var checkinFirstLine: String?
    public private(set) var selectedIndex: Int?

    private let repository: any TodoPanelRepository
    private let now: @Sendable () -> EpochMs

    public init(
        repository: any TodoPanelRepository,
        now: @escaping @Sendable () -> EpochMs
    ) {
        self.repository = repository
        self.now = now
    }

    public func refresh() async {
        async let loadedItems = repository.openItems(limit: Self.openItemLimit)
        async let headerLine = repository.todayCheckinFirstLine(nowMs: now())
        items = await loadedItems
        checkinFirstLine = await headerLine
        selectedIndex = items.isEmpty ? nil : 0
    }

    public func moveSelection(by offset: Int) {
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex ?? 0
        selectedIndex = (current + offset % items.count + items.count) % items.count
    }

    public func select(index: Int) {
        selectedIndex = items.indices.contains(index) ? index : selectedIndex
    }

    public func markSelectedDone() async {
        guard let id = selectedItemID() else { return }
        await repository.markDone(id: id, nowMs: now())
        removeSelectedItem(id: id)
    }

    public func dismissSelected() async {
        guard let id = selectedItemID() else { return }
        await repository.dismiss(id: id, nowMs: now())
        removeSelectedItem(id: id)
    }

    private func selectedItemID() -> String? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex].id
    }

    private func removeSelectedItem(id: String) {
        guard let selectedIndex else { return }
        items.removeAll { $0.id == id }
        if items.isEmpty {
            self.selectedIndex = nil
        } else {
            self.selectedIndex = min(selectedIndex, items.count - 1)
        }
    }
}
