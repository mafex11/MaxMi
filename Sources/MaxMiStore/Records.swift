import MaxMiCore

public struct PendingVersion: Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let hourBucket: Int64
    public let content: String
    public let contentHash: String
    public let sourceApp: String
    public let sourceKey: String
    public let previousFrozenContent: String?   // latest frozen version of same thread, by hour_bucket
}

public struct PendingDerivative: Sendable, Equatable {
    public let id: String
    public let content: String
}
