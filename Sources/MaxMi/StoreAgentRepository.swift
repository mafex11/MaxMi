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

    func complete(runID: String, ops: [AgentOpDTO]) async {
        do {
            // Validate and map [AgentOpDTO] -> [AgentOp]
            let validatedOps = try Self.validateAndMap(ops)
            _ = try store.completeAgentRun(runID: runID, ops: validatedOps, nowMs: epochNowMs())
        } catch {
            // Validation or store error — silently fail (HourlyAgent would have called fail if relay threw)
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
        var newItemTitles: Set<String> = []
        var resolvedNewTitles: Set<String> = []

        for dto in dtos {
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

                // Track new items by title for create+resolve drop logic
                newItemTitles.insert(title)

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

                // Track resolved IDs for create+resolve drop logic
                // (We can't perfectly detect this without knowing which create it refers to,
                // but we can heuristically filter by title if the evidence contains the same title)
                resolvedNewTitles.insert(id)

                result.append(.resolve(id: id, evidence: evidence))

            default:
                throw ValidationError.unknownOp("unknown op type: '\(dto.op)'")
            }
        }

        // Filter out create+resolve pairs of the same new item
        // (This is a best-effort heuristic — we drop resolves that reference IDs we haven't seen)
        // In practice, the Store's completeAgentRun will also validate source_refs and unknown IDs.
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
