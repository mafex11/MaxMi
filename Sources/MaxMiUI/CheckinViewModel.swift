import Foundation
import MaxMiCore
import Observation

@MainActor
@Observable
public final class CheckinViewModel {
    public private(set) var state: CheckinCardState
    public private(set) var openItems: [CheckinOpenItemDTO] = []
    public private(set) var isRegenerating = false

    private let load: @Sendable (Int64) async -> CheckinDTO?
    private let dismiss: @Sendable (Int64, EpochMs) async throws -> Void
    private let regenerate: @Sendable () async throws -> Void
    private let now: @Sendable () -> EpochMs
    private let timeZone: TimeZone
    private let dayBucket: @Sendable (EpochMs, TimeZone) -> Int64

    public init(
        load: @escaping @Sendable (Int64) async -> CheckinDTO?,
        dismiss: @escaping @Sendable (Int64, EpochMs) async throws -> Void,
        regenerate: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> EpochMs,
        timeZone: TimeZone,
        dayBucket: @escaping @Sendable (EpochMs, TimeZone) -> Int64
    ) {
        self.load = load
        self.dismiss = dismiss
        self.regenerate = regenerate
        self.now = now
        self.timeZone = timeZone
        self.dayBucket = dayBucket
        state = .pending
    }

    public func refresh() async {
        let today = dayBucket(now(), timeZone)
        guard let dto = await load(today) else {
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
            let nowMs = now()
            try await dismiss(dayBucket(nowMs, timeZone), nowMs)
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
