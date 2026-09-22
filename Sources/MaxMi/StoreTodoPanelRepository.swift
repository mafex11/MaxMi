import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiUI

struct StoreTodoPanelRepository: TodoPanelRepository, @unchecked Sendable {
    let store: Store
    let timeZone: TimeZone

    init(store: Store, timeZone: TimeZone) {
        self.store = store
        self.timeZone = timeZone
    }

    func openItems(limit: Int) async -> [TodoPanelItem] {
        await Task.detached(priority: .userInitiated) {
            do {
                let items = try self.store.openActionItems(limit: limit)
                let sourceApps = try self.store.sourceApps(
                    forVersionIDs: Set(items.flatMap(\.sourceRefs))
                )
                return items.map { item in
                    TodoPanelItem(
                        id: item.id,
                        title: item.title,
                        details: item.details,
                        sourceApp: item.sourceRefs.lazy.compactMap { sourceApps[$0] }.first,
                        detectedAtMs: item.detectedAtMs,
                        remindAtMs: item.remindAtMs,
                        remindedAtMs: item.remindedAtMs
                    )
                }
            } catch {
                return []
            }
        }.value
    }

    func todayCheckinFirstLine(nowMs: EpochMs) async -> String? {
        await Task.detached(priority: .userInitiated) {
            do {
                let dayBucket = ActivityTime.dayBucket(forMs: nowMs, timeZone: self.timeZone)
                guard let summary = try self.store.checkin(dayBucket: dayBucket)?.summary else {
                    return nil
                }
                guard let firstLine = summary.split(whereSeparator: \.isNewline).first else {
                    return nil
                }
                let trimmed = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                return nil
            }
        }.value
    }

    func markDone(id: String, nowMs: EpochMs) async {
        await Task.detached(priority: .userInitiated) {
            try? self.store.resolveActionItem(id, nowMs: nowMs)
        }.value
    }

    func dismiss(id: String, nowMs: EpochMs) async {
        await Task.detached(priority: .userInitiated) {
            try? self.store.dismissActionItem(id, nowMs: nowMs)
        }.value
    }
}
