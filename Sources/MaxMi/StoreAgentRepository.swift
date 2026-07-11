import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiActivity

struct StoreAgentRepository: AgentRepository, @unchecked Sendable {
    let store: Store

    func claimNextPage() async -> AgentLeasedPage? {
        do {
            guard let page = try store.claimNextAgentRun(maxSessions: 50, leaseMs: 120_000, nowMs: epochNowMs()) else {
                return nil
            }

            // Pair summaries + sourceIDs into [ReviewSession]
            let sessions = zip(page.sourceIDs, page.summaries).map { id, summary in
                ReviewSession(id: id, summary: summary)
            }

            return AgentLeasedPage(runID: page.runID, sessions: sessions, openItems: page.openItems)
        } catch {
            return nil
        }
    }

    func complete(runID: String, ops: [AgentOpDTO]) async throws {
        // Validate and map [AgentOpDTO] -> [AgentOp]
        let validatedOps = try Self.validateAndMap(ops)
        _ = try store.completeAgentRun(runID: runID, ops: validatedOps, nowMs: epochNowMs())
    }

    func renew(runID: String) async {
        do {
            try store.renewAgentRunLease(runID: runID, leaseMs: 120_000, nowMs: epochNowMs())
        } catch {
            // Best effort
        }
    }

    func fail(runID: String, error: String) async {
        do {
            try store.failAgentRun(runID: runID, error: error, nowMs: epochNowMs())
        } catch {
            // Best effort
        }
    }

    // MARK: - DTO Validation & Mapping

    /// Validates and maps [AgentOpDTO] -> [AgentOp].
    /// Throws ValidationError if ops are malformed.
    /// Filters out invalid ops (e.g., create+resolve of same item, invalid source_refs).
    static func validateAndMap(_ dtos: [AgentOpDTO]) throws -> [AgentOp] {
        var result: [AgentOp] = []
        var newItemIndices: Set<Int> = []
        var resolveTargetIndices: Set<Int> = []

        for (i, dto) in dtos.enumerated() {
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
                if let details = details, details.count > 2000 {
                    throw ValidationError.fieldTooLong("details exceeds 2000 chars")
                }

                let sourceRefs = dto.sourceRefs ?? []
                newItemIndices.insert(i)
                result.append(.create(kind: kind, title: title, details: details, sourceRefs: sourceRefs))

            case "update":
                guard let id = dto.id, !id.isEmpty else {
                    throw ValidationError.missingField("update op requires non-empty 'id'")
                }

                let title = dto.title.flatMap { $0.isEmpty ? nil : $0 }
                if let title = title, title.count > 500 {
                    throw ValidationError.fieldTooLong("title exceeds 500 chars")
                }

                let details = dto.details.flatMap { $0.isEmpty ? nil : $0 }
                if let details = details, details.count > 2000 {
                    throw ValidationError.fieldTooLong("details exceeds 2000 chars")
                }

                // At least one field must be present
                guard title != nil || details != nil else {
                    throw ValidationError.missingField("update op requires at least one of 'title' or 'details'")
                }

                result.append(.update(id: id, title: title, details: details))

            case "resolve":
                guard let id = dto.id, !id.isEmpty else {
                    throw ValidationError.missingField("resolve op requires non-empty 'id'")
                }
                guard let evidence = dto.evidence, !evidence.isEmpty else {
                    throw ValidationError.missingField("resolve op requires non-empty 'evidence'")
                }
                guard evidence.count <= 2000 else {
                    throw ValidationError.fieldTooLong("evidence exceeds 2000 chars")
                }

                resolveTargetIndices.insert(i)
                result.append(.resolve(id: id, evidence: evidence))

            default:
                throw ValidationError.unknownOp("unknown op type: '\(dto.op)'")
            }
        }

        // Drop resolve ops that target items created in the same batch (same-run conflict)
        let conflictIndices = newItemIndices.intersection(resolveTargetIndices)
        if !conflictIndices.isEmpty {
            result = result.enumerated().filter { !conflictIndices.contains($0.offset) }.map { $0.element }
        }

        return result
    }

    enum ValidationError: Error, LocalizedError {
        case unknownOp(String)
        case missingField(String)
        case fieldTooLong(String)

        var errorDescription: String? {
            switch self {
            case .unknownOp(let msg): return msg
            case .missingField(let msg): return msg
            case .fieldTooLong(let msg): return msg
            }
        }
    }
}
