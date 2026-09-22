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
    public static let openItemCap = 15
}

public struct AgentOpDTO: Sendable, Codable {
    public let op: String
    public let id: String?
    public let kind: String?
    public let title: String?
    public let details: String?
    public let evidence: String?
    public let sourceRefs: [String]?
    public let remindAt: String?

    private enum CodingKeys: String, CodingKey {
        case op, id, kind, title, details, evidence, sourceRefs
        case remindAt = "remind_at"
    }

    public init(
        op: String,
        id: String?,
        kind: String?,
        title: String?,
        details: String?,
        evidence: String?,
        sourceRefs: [String]?,
        remindAt: String? = nil
    ) {
        self.op = op
        self.id = id
        self.kind = kind
        self.title = title
        self.details = details
        self.evidence = evidence
        self.sourceRefs = sourceRefs
        self.remindAt = remindAt
    }
}

public enum ReminderChange: Sendable, Equatable {
    case unchanged
    case set(EpochMs)
}

public enum ValidatedAgentOp: Sendable {
    case create(
        kind: String,
        title: String,
        details: String?,
        sourceRefs: [String],
        reminder: ReminderChange = .unchanged
    )
    case update(
        id: String,
        title: String?,
        details: String?,
        reminder: ReminderChange = .unchanged
    )
    case resolve(id: String, evidence: String)
}

public enum AgentOperationValidator {
    public static func validateAndMap(
        _ dtos: [AgentOpDTO],
        nowMs: EpochMs,
        timeZone: TimeZone
    ) throws -> [ValidatedAgentOp] {
        try dtos.map { dto in
            let hasReminderField = dto.remindAt != nil
            let reminder: ReminderChange
            if let rawReminder = dto.remindAt,
               let accepted = ReminderTimeValidator.accept(
                   rawReminder,
                   nowMs: nowMs,
                   timeZone: timeZone
               ) {
                reminder = .set(accepted)
            } else {
                reminder = .unchanged
            }

            switch dto.op {
            case "create":
                guard let kind = dto.kind, !kind.isEmpty else {
                    throw ValidationError.missingField("create op requires non-empty 'kind'")
                }
                guard let title = dto.title, !title.isEmpty else {
                    throw ValidationError.missingField("create op requires non-empty 'title'")
                }
                guard title.count <= 500 else {
                    throw ValidationError.fieldTooLong("title exceeds 500 chars")
                }
                let details = dto.details.flatMap { $0.isEmpty ? nil : $0 }
                if let details, details.count > 2_000 {
                    throw ValidationError.fieldTooLong("details exceeds 2000 chars")
                }
                return .create(
                    kind: kind,
                    title: title,
                    details: details,
                    sourceRefs: dto.sourceRefs ?? [],
                    reminder: reminder
                )

            case "update":
                guard let id = dto.id, !id.isEmpty else {
                    throw ValidationError.missingField("update op requires non-empty 'id'")
                }
                let title = dto.title.flatMap { $0.isEmpty ? nil : $0 }
                let details = dto.details.flatMap { $0.isEmpty ? nil : $0 }
                if let title, title.count > 500 {
                    throw ValidationError.fieldTooLong("title exceeds 500 chars")
                }
                if let details, details.count > 2_000 {
                    throw ValidationError.fieldTooLong("details exceeds 2000 chars")
                }
                guard title != nil || details != nil || hasReminderField else {
                    throw ValidationError.missingField(
                        "update op requires title, details, or remind_at"
                    )
                }
                return .update(id: id, title: title, details: details, reminder: reminder)

            case "resolve":
                guard let id = dto.id, !id.isEmpty else {
                    throw ValidationError.missingField("resolve op requires non-empty 'id'")
                }
                guard let evidence = dto.evidence, !evidence.isEmpty else {
                    throw ValidationError.missingField("resolve op requires non-empty 'evidence'")
                }
                guard evidence.count <= 2_000 else {
                    throw ValidationError.fieldTooLong("evidence exceeds 2000 chars")
                }
                return .resolve(id: id, evidence: evidence)

            default:
                throw ValidationError.unknownOp("unknown op type: '\(dto.op)'")
            }
        }
    }

    public enum ValidationError: Error, LocalizedError {
        case unknownOp(String)
        case missingField(String)
        case fieldTooLong(String)

        public var errorDescription: String? {
            switch self {
            case .unknownOp(let message), .missingField(let message), .fieldTooLong(let message):
                return message
            }
        }
    }
}

public protocol AgentRepository: Sendable {
    func claimNextPage() async -> AgentLeasedPage?
    func complete(runID: String, ops: [ValidatedAgentOp]) async throws
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
    private let renewalSleep: @Sendable (UInt64) async throws -> Void
    private let clock: @Sendable () -> EpochMs
    private let timeZone: TimeZone

    public init(
        repo: any AgentRepository,
        relay: any AgentGenerationRelay,
        maxPagesPerTick: Int = 4,
        renewalSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        clock: @escaping @Sendable () -> EpochMs = epochNowMs,
        timeZone: TimeZone
    ) {
        self.repo = repo
        self.relay = relay
        self.maxPagesPerTick = maxPagesPerTick
        self.renewalSleep = renewalSleep
        self.clock = clock
        self.timeZone = timeZone
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
        boundedInput(
            runID: runID,
            versions: versions,
            timelineText: timelineText,
            openItems: openItems,
            localTimeISO: localTimeISO,
            fromMs: fromMs,
            toMs: toMs,
            maxChars: maxChars,
            nonce: AgentPrompts.budgetNonce
        )
    }

    static func boundedInput(
        runID: String,
        versions: [ReviewVersion],
        timelineText: String,
        openItems: [ReviewOpenItem],
        localTimeISO: String,
        fromMs: EpochMs,
        toMs: EpochMs,
        maxChars: Int,
        nonce: String
    ) -> AgentReviewInput {
        var retained = versions.map {
            $0.replacingCompactContent(
                String($0.compactContent.prefix(HourlyReviewBudget.versionCompactCap))
            )
        }
        var timeline = String(timelineText.prefix(HourlyReviewBudget.timelineCap))
        let retainedOpenItems = Array(openItems.prefix(HourlyReviewBudget.openItemCap))

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
                openItems: retainedOpenItems,
                localTimeISO: localTimeISO,
                timeRange: (fromMs, toMs)
            )
        }

        while let index = smallestShrinkableDeltaOffset() {
            let overflow = AgentPrompts.renderedUntrustedPayload(for: candidate(), nonce: nonce).count - maxChars
            guard overflow > 0 else { break }
            let old = retained[index].compactContent
            let reducible = old.count - HourlyReviewBudget.versionCompactFloor
            let reducedCount = old.count - min(max(overflow, 1), reducible)
            retained[index] = retained[index].replacingCompactContent(
                String(old.prefix(reducedCount))
            )
        }

        while AgentPrompts.renderedUntrustedPayload(for: candidate(), nonce: nonce).count > maxChars,
              retained.count > 1,
              let index = smallestDeltaOffset() {
            retained.remove(at: index)
        }

        while timeline.count > HourlyReviewBudget.timelineFloor {
            let overflow = AgentPrompts.renderedUntrustedPayload(for: candidate(), nonce: nonce).count - maxChars
            guard overflow > 0 else { break }
            let reducible = timeline.count - HourlyReviewBudget.timelineFloor
            timeline = String(timeline.dropLast(min(max(overflow, 1), reducible)))
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
                        do {
                            try await renewalSleep(40_000_000_000)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { break }
                        await repo.renew(runID: page.runID)
                    }
                }
                defer { renewalTask.cancel() }

                let rawOps = try await relay.reviewActivity(input)
                let validatedOps = try AgentOperationValidator.validateAndMap(
                    rawOps,
                    nowMs: clock(),
                    timeZone: timeZone
                )
                try await repo.complete(runID: page.runID, ops: validatedOps)
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
