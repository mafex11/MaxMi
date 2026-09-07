import Foundation
import MaxMiCore
import Observation

@MainActor
@Observable
public final class CheckinViewModel {
    public private(set) var state: CheckinCardState
    public private(set) var openItems: [CheckinOpenItemDTO] = []
    public private(set) var isRegenerating = false

    private let load: @Sendable () async -> CheckinDTO?
    private let dismiss: @Sendable () async throws -> Void
    private let regenerate: @Sendable () async throws -> Void

    public init(
        load: @escaping @Sendable () async -> CheckinDTO?,
        dismiss: @escaping @Sendable () async throws -> Void,
        regenerate: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> EpochMs,
        timeZone: TimeZone
    ) {
        self.load = load
        self.dismiss = dismiss
        self.regenerate = regenerate
        state = .pending
    }

    public func refresh() async {
        guard let dto = await load() else {
            openItems = []
            state = .pending
            return
        }
        openItems = dto.openItems
        if dto.dismissedAtMs != nil {
            state = .dismissed
        } else if dto.isEmptySummary, let generatedAtMs = dto.generatedAtMs {
            state = .empty(summary: dto.summary ?? "", generatedAtMs: generatedAtMs)
        } else if let summary = dto.summary, let generatedAtMs = dto.generatedAtMs {
            state = .ready(summary: summary, generatedAtMs: generatedAtMs)
        } else {
            state = .pending
        }
    }

    public func dismissToday() async {
        guard !isRegenerating else { return }
        do {
            try await dismiss()
            await refresh()
        } catch {
        }
    }

    public func regenerateToday() async {
        guard !isRegenerating else { return }
        let previous = state
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            try await regenerate()
            await refresh()
        } catch {
            state = previous
        }
    }
}
