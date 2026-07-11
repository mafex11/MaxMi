import Foundation
import Observation

@MainActor
@Observable
public final class ActionItemsViewModel {
    public private(set) var open: [ActionItemDTO] = []
    public private(set) var archived: [ActionItemDTO] = []

    private let load: @Sendable () async -> (open: [ActionItemDTO], archived: [ActionItemDTO])
    private let onResolve: @Sendable (String) async throws -> Void
    private let onDismiss: @Sendable (String) async throws -> Void

    public init(
        load: @escaping @Sendable () async -> (open: [ActionItemDTO], archived: [ActionItemDTO]),
        onResolve: @escaping @Sendable (String) async throws -> Void,
        onDismiss: @escaping @Sendable (String) async throws -> Void
    ) {
        self.load = load
        self.onResolve = onResolve
        self.onDismiss = onDismiss
    }

    public func refresh() async {
        let result = await load()
        self.open = result.open
        self.archived = result.archived
    }

    public func resolve(_ id: String) async {
        do {
            try await onResolve(id)
            // Refresh only on success
            await refresh()
        } catch {
            // On failure, keep the item (don't refresh)
        }
    }

    public func dismiss(_ id: String) async {
        do {
            try await onDismiss(id)
            // Refresh only on success
            await refresh()
        } catch {
            // On failure, keep the item (don't refresh)
        }
    }
}
