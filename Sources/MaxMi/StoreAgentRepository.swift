import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiActivity

struct StoreAgentRepository: AgentRepository, @unchecked Sendable {
    let store: Store

    func claimNextPage() async -> AgentLeasedPage? {
        let page: AgentPage
        do {
            guard let claimedPage = try store.claimNextAgentRun(
                maxVersions: 50,
                leaseMs: 120_000,
                nowMs: epochNowMs()
            ) else {
                return nil
            }
            page = claimedPage
        } catch {
            SafeLogger.shared.log(
                .error,
                subsystem: .agent,
                event: .agentRunFailed,
                error: error
            )
            return nil
        }

        do {
            let timeline = try TimelineBuilder(repo: StoreTimelineRepository(store: store)).build(
                fromMs: page.fromMs,
                toMs: page.toMs
            )
            let text = TimelineBuilder.render(timeline, budgetChars: HourlyReviewBudget.timelineCap)

            return AgentLeasedPage(
                runID: page.runID,
                versions: page.versions,
                timelineText: text,
                openItems: page.openItems,
                localTimeISO: localTimeISO(for: page.toMs),
                fromMs: page.fromMs,
                toMs: page.toMs
            )
        } catch {
            SafeLogger.shared.log(
                .error,
                subsystem: .agent,
                event: .agentRunFailed,
                error: error
            )
            await fail(runID: page.runID, error: error.localizedDescription)
            return nil
        }
    }

    func complete(runID: String, ops: [ValidatedAgentOp]) async throws {
        _ = try store.completeAgentRun(runID: runID, ops: ops, nowMs: epochNowMs())
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

    private func localTimeISO(for ms: EpochMs) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
    }
}
