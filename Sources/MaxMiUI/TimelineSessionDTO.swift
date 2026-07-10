import Foundation
import MaxMiCore

public struct TimelineSessionDTO: Identifiable, Sendable {
    public let id: String
    public let appLabel: String
    public let summary: String?
    public let startedAtMs: Int64
    public let evidence: [String]

    public init(id: String, appLabel: String, summary: String?, startedAtMs: Int64, evidence: [String]) {
        self.id = id
        self.appLabel = appLabel
        self.summary = summary
        self.startedAtMs = startedAtMs
        self.evidence = evidence
    }
}

public struct SessionRow: Identifiable, Sendable {
    public let id: String
    public let appLabel: String
    public let timeAgo: String
    public let dayGroup: String
    public let summary: String
    public let evidence: [String]

    public init(id: String, appLabel: String, timeAgo: String, dayGroup: String, summary: String, evidence: [String]) {
        self.id = id
        self.appLabel = appLabel
        self.timeAgo = timeAgo
        self.dayGroup = dayGroup
        self.summary = summary
        self.evidence = evidence
    }
}
