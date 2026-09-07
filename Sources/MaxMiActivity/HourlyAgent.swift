import Foundation
import MaxMiCore

public struct ReviewVersion: Sendable, Codable, Equatable {
    public let versionID: String
    public let threadID: String
    public let sourceApp: String
    public let sourceTitle: String?
    public let sourceKey: String
    public let kind: CaptureContentKind
    public let wordCount: Int
    public let committedAt: EpochMs
    public let compactContent: String
    public let deltaSummary: String?
    public let deltaChars: Int

    public init(
        versionID: String,
        threadID: String,
        sourceApp: String,
        sourceTitle: String?,
        sourceKey: String,
        kind: CaptureContentKind,
        wordCount: Int,
        committedAt: EpochMs,
        compactContent: String,
        deltaSummary: String?,
        deltaChars: Int
    ) {
        self.versionID = versionID
        self.threadID = threadID
        self.sourceApp = sourceApp
        self.sourceTitle = sourceTitle
        self.sourceKey = sourceKey
        self.kind = kind
        self.wordCount = wordCount
        self.committedAt = committedAt
        self.compactContent = compactContent
        self.deltaSummary = deltaSummary
        self.deltaChars = deltaChars
    }
}

public struct ReviewOpenItem: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let details: String?
    public let sourceApp: String?
    public let createdAt: EpochMs

    public init(
        id: String,
        title: String,
        details: String?,
        sourceApp: String?,
        createdAt: EpochMs
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.sourceApp = sourceApp
        self.createdAt = createdAt
    }
}

public struct AgentReviewInput: Sendable {
    public let runID: String
    public let versions: [ReviewVersion]
    public let timelineText: String
    public let openItems: [ReviewOpenItem]
    public let localTimeISO: String
    public let timeRange: (fromMs: EpochMs, toMs: EpochMs)

    public init(
        runID: String,
        versions: [ReviewVersion],
        timelineText: String,
        openItems: [ReviewOpenItem],
        localTimeISO: String,
        timeRange: (fromMs: EpochMs, toMs: EpochMs)
    ) {
        self.runID = runID
        self.versions = versions
        self.timelineText = timelineText
        self.openItems = openItems
        self.localTimeISO = localTimeISO
        self.timeRange = timeRange
    }
}

public struct AgentLeasedPage: Sendable {
    public let runID: String
    public let versions: [ReviewVersion]
    public let timelineText: String
    public let openItems: [ReviewOpenItem]
    public let localTimeISO: String
    public let fromMs: EpochMs
    public let toMs: EpochMs

    public init(
        runID: String,
        versions: [ReviewVersion],
        timelineText: String,
        openItems: [ReviewOpenItem],
        localTimeISO: String,
        fromMs: EpochMs,
        toMs: EpochMs
    ) {
        self.runID = runID
        self.versions = versions
        self.timelineText = timelineText
        self.openItems = openItems
        self.localTimeISO = localTimeISO
        self.fromMs = fromMs
        self.toMs = toMs
    }
}

public enum HourlyReviewBudget {
    public static let maximum = 40_000
    public static let versionCompactCap = 2_000
    public static let versionCompactFloor = 600
    public static let versionDeltaCap = 400
    public static let timelineCap = 6_000
    public static let timelineFloor = 4_000
    public static let itemTitleCap = 200
    public static let itemDetailsCap = 500
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

    public static func boundedInput(
        runID: String,
        versions: [ReviewVersion],
        timelineText: String,
        openItems: [ReviewOpenItem],
        localTimeISO: String,
        fromMs: EpochMs,
        toMs: EpochMs,
        maxChars: Int = HourlyReviewBudget.maximum
    ) -> AgentReviewInput {
        var retained = versions.map {
            $0.replacingCompactContent(
                String($0.compactContent.prefix(HourlyReviewBudget.versionCompactCap))
            )
        }
        var timeline = String(timelineText.prefix(HourlyReviewBudget.timelineCap))

        func smallestDeltaOffset() -> Int? {
            retained.enumerated().min {
                $0.element.deltaChars == $1.element.deltaChars
                    ? $0.element.versionID < $1.element.versionID
                    : $0.element.deltaChars < $1.element.deltaChars
            }?.offset
        }

        func smallestShrinkableDeltaOffset() -> Int? {
            retained.enumerated().filter {
                $0.element.compactContent.count > HourlyReviewBudget.versionCompactFloor
            }.min {
                $0.element.deltaChars == $1.element.deltaChars
                    ? $0.element.versionID < $1.element.versionID
                    : $0.element.deltaChars < $1.element.deltaChars
            }?.offset
        }

        func candidate() -> AgentReviewInput {
            AgentReviewInput(
                runID: runID,
                versions: retained,
                timelineText: timeline,
                openItems: openItems,
                localTimeISO: localTimeISO,
                timeRange: (fromMs, toMs)
            )
        }

        while AgentPrompts.untrustedPayloadCharacters(for: candidate()) > maxChars,
              let index = smallestShrinkableDeltaOffset() {
            let old = retained[index].compactContent
            let reducedCount = max(HourlyReviewBudget.versionCompactFloor, old.count - 1)
            retained[index] = retained[index].replacingCompactContent(
                String(old.prefix(reducedCount))
            )
        }

        while AgentPrompts.untrustedPayloadCharacters(for: candidate()) > maxChars,
              retained.count > 1,
              let index = smallestDeltaOffset() {
            retained.remove(at: index)
        }

        while AgentPrompts.untrustedPayloadCharacters(for: candidate()) > maxChars,
              timeline.count > (retained.isEmpty ? 0 : HourlyReviewBudget.timelineFloor) {
            timeline.removeLast()
        }

        return candidate()
    }

    public func runIfDue() async {
        var pagesProcessed = 0

        while pagesProcessed < maxPagesPerTick {
            guard let page = await repo.claimNextPage() else {
                break
            }

            let input = Self.boundedInput(
                runID: page.runID,
                versions: page.versions,
                timelineText: page.timelineText,
                openItems: page.openItems,
                localTimeISO: page.localTimeISO,
                fromMs: page.fromMs,
                toMs: page.toMs
            )

            do {
                let renewalTask = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 40_000_000_000)
                        guard !Task.isCancelled else { break }
                        await repo.renew(runID: page.runID)
                    }
                }

                let ops = try await relay.reviewActivity(input)
                renewalTask.cancel()
                try await repo.complete(runID: page.runID, ops: ops)
            } catch {
                SafeLogger.shared.log(
                    .error,
                    subsystem: .agent,
                    event: .agentRunFailed,
                    error: error
                )
                await repo.fail(runID: page.runID, error: error.localizedDescription)
                break
            }

            pagesProcessed += 1
        }
    }
}

private extension ReviewVersion {
    func replacingCompactContent(_ value: String) -> ReviewVersion {
        ReviewVersion(
            versionID: versionID,
            threadID: threadID,
            sourceApp: sourceApp,
            sourceTitle: sourceTitle,
            sourceKey: sourceKey,
            kind: kind,
            wordCount: wordCount,
            committedAt: committedAt,
            compactContent: value,
            deltaSummary: deltaSummary,
            deltaChars: deltaChars
        )
    }
}
