import Foundation
@testable import MaxMiStore
import MaxMiCore

extension Store {
    func claimNextAgentRun(
        maxVersions: Int,
        leaseMs: EpochMs,
        nowMs: EpochMs
    ) throws -> AgentPage? {
        try claimNextAgentRun(
            maxVersions: maxVersions,
            leaseMs: leaseMs,
            nowMs: nowMs,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }
}
