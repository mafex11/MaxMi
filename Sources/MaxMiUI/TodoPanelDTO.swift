import MaxMiCore

public struct TodoPanelItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let details: String?
    public let sourceApp: String?
    public let detectedAtMs: EpochMs
    public let remindAtMs: EpochMs?
    public let remindedAtMs: EpochMs?

    public init(
        id: String,
        title: String,
        details: String?,
        sourceApp: String?,
        detectedAtMs: EpochMs,
        remindAtMs: EpochMs?,
        remindedAtMs: EpochMs?
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.sourceApp = sourceApp
        self.detectedAtMs = detectedAtMs
        self.remindAtMs = remindAtMs
        self.remindedAtMs = remindedAtMs
    }
}

public protocol TodoPanelRepository: Sendable {
    /// Returns the newest open items, already sorted by `detectedAtMs`
    /// descending with `id` descending as a tiebreaker, and already bounded
    /// to `limit`.
    func openItems(limit: Int) async -> [TodoPanelItem]
    func todayCheckinFirstLine(nowMs: EpochMs) async -> String?
    func markDone(id: String, nowMs: EpochMs) async
    func dismiss(id: String, nowMs: EpochMs) async
}
