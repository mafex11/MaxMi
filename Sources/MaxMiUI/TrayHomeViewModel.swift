import Foundation
import Observation

@MainActor
@Observable
public final class TrayHomeViewModel {
    public private(set) var status = TrayStatusDTO(
        state: .capturing, title: "MaxMi is ready", detail: "Waiting for an eligible window", captureCount: 0
    )
    public private(set) var results: [TraySearchResultDTO] = []
    public private(set) var isSearching = false
    public private(set) var searchError: String?
    public var query = ""

    private let loadStatus: @MainActor @Sendable () async -> TrayStatusDTO
    private let search: @Sendable (String) async throws -> [TraySearchResultDTO]
    private var searchTask: Task<Void, Never>?

    public init(
        loadStatus: @escaping @MainActor @Sendable () async -> TrayStatusDTO,
        search: @escaping @Sendable (String) async throws -> [TraySearchResultDTO]
    ) {
        self.loadStatus = loadStatus
        self.search = search
    }

    public func refresh() async {
        status = await loadStatus()
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch()
        }
    }

    public func scheduleSearch() {
        searchTask?.cancel()
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            results = []
            isSearching = false
            searchError = nil
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            do {
                let loaded = try await search(value)
                guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return }
                results = loaded
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchError = "Local search is unavailable"
            }
            isSearching = false
        }
    }
}

