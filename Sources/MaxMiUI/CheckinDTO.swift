import MaxMiCore

public enum CheckinCardState: Sendable, Equatable {
    case pending
    case ready(summary: String, generatedAtMs: EpochMs)
    case empty(summary: String, generatedAtMs: EpochMs)
    case dismissed
}

public struct CheckinOpenItemDTO: Sendable, Equatable {
    public let title: String
    public let ageDays: Int

    public init(title: String, ageDays: Int) {
        self.title = title
        self.ageDays = ageDays
    }
}

public struct CheckinDTO: Sendable, Equatable {
    public let dayBucket: Int64
    public let generatedAtMs: EpochMs?
    public let summary: String?
    public let dismissedAtMs: EpochMs?
    public let isEmptySummary: Bool
    public let openItems: [CheckinOpenItemDTO]

    public init(
        dayBucket: Int64,
        generatedAtMs: EpochMs?,
        summary: String?,
        dismissedAtMs: EpochMs?,
        isEmptySummary: Bool,
        openItems: [CheckinOpenItemDTO] = []
    ) {
        self.dayBucket = dayBucket
        self.generatedAtMs = generatedAtMs
        self.summary = summary
        self.dismissedAtMs = dismissedAtMs
        self.isEmptySummary = isEmptySummary
        self.openItems = openItems
    }
}
