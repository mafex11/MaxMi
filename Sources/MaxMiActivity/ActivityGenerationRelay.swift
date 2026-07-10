import Foundation
import MaxMiCore

public struct PendingSession: Sendable {
    public let id: String
    public let appLabel: String
    public let evidence: [String]
    public let expectedSourceHash: String

    public init(id: String, appLabel: String, evidence: [String], expectedSourceHash: String) {
        self.id = id
        self.appLabel = appLabel
        self.evidence = evidence
        self.expectedSourceHash = expectedSourceHash
    }
}

public protocol ActivitySummaryRepository: Sendable {
    func sessionsNeedingSummary(nowMs: EpochMs) async -> [PendingSession]
    func saveSummary(sessionID: String, summary: String, expectedSourceHash: String, nowMs: EpochMs) async
    func markFailed(sessionID: String, error: String, nowMs: EpochMs) async
}

public protocol ActivityGenerationRelay: Sendable {
    func summarizeSession(appLabel: String, evidence: [String]) async throws -> String
}
