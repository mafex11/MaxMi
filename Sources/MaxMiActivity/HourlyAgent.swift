import Foundation
import MaxMiCore

public struct ReviewSession: Sendable {
    public let id: String
    public let summary: String

    public init(id: String, summary: String) {
        self.id = id
        self.summary = summary
    }
}

public struct AgentReviewInput: Sendable {
    public let sessions: [ReviewSession]
    public let openItems: [(id: String, title: String)]

    public init(sessions: [ReviewSession], openItems: [(id: String, title: String)]) {
        self.sessions = sessions
        self.openItems = openItems
    }
}

public struct AgentLeasedPage: Sendable {
    public let runID: String
    public let sessions: [ReviewSession]
    public let openItems: [(id: String, title: String)]

    public init(runID: String, sessions: [ReviewSession], openItems: [(id: String, title: String)]) {
        self.runID = runID
        self.sessions = sessions
        self.openItems = openItems
    }
}

public struct AgentOpDTO: Sendable, Codable {
    public let op: String
    public let id: String?
    public let kind: String?
    public let title: String?
    public let details: String?
    public let evidence: String?
    public let sourceRefs: [String]?

    public init(op: String, id: String?, kind: String?, title: String?, details: String?, evidence: String?, sourceRefs: [String]?) {
        self.op = op
        self.id = id
        self.kind = kind
        self.title = title
        self.details = details
        self.evidence = evidence
        self.sourceRefs = sourceRefs
    }
}

public protocol AgentRepository: Sendable {
    func claimNextPage() async -> AgentLeasedPage?
    func complete(runID: String, ops: [AgentOpDTO]) async throws
    func fail(runID: String, error: String) async
    func renew(runID: String) async
}

public protocol AgentGenerationRelay: Sendable {
    func reviewActivity(_ input: AgentReviewInput) async throws -> [AgentOpDTO]
}

public struct HourlyAgent: Sendable {
    private let repo: any AgentRepository
    private let relay: any AgentGenerationRelay
    private let maxPagesPerTick: Int

    public init(repo: any AgentRepository, relay: any AgentGenerationRelay, maxPagesPerTick: Int = 4) {
        self.repo = repo
        self.relay = relay
        self.maxPagesPerTick = maxPagesPerTick
    }

    public func runIfDue() async {
        var pagesProcessed = 0

        while pagesProcessed < maxPagesPerTick {
            guard let page = await repo.claimNextPage() else {
                break
            }

            let input = AgentReviewInput(sessions: page.sessions, openItems: page.openItems)

            do {
                // Launch a renewal heartbeat that runs every ~40s while relay call is in flight
                let renewalTask = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 40_000_000_000) // 40s
                        guard !Task.isCancelled else { break }
                        await repo.renew(runID: page.runID)
                    }
                }

                let ops = try await relay.reviewActivity(input)
                renewalTask.cancel()
                try await repo.complete(runID: page.runID, ops: ops)
            } catch {
                await repo.fail(runID: page.runID, error: error.localizedDescription)
                break
            }

            pagesProcessed += 1
        }
    }
}
