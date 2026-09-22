import MaxMiActivity
import MaxMiCore
import MaxMiStore

struct StoreReminderRepository: ReminderRepository, @unchecked Sendable {
    let store: Store

    init(store: Store) {
        self.store = store
    }

    func dueReminders(nowMs: EpochMs) async -> [ReminderItem] {
        await Task.detached(priority: .utility) {
            do {
                let items = try self.store.dueReminders(nowMs: nowMs)
                let sourceApps = try self.store.sourceApps(
                    forVersionIDs: Set(items.flatMap(\.sourceRefs))
                )
                return items.map {
                    ReminderItem(
                        id: $0.id,
                        title: $0.title,
                        sourceApp: $0.sourceRefs.first.flatMap { sourceApps[$0] },
                        detectedAtMs: $0.detectedAtMs
                    )
                }
            } catch {
                return []
            }
        }.value
    }

    func markReminded(_ id: String, nowMs: EpochMs) async {
        await Task.detached(priority: .utility) {
            try? self.store.markReminded(id, nowMs: nowMs)
        }.value
    }
}
