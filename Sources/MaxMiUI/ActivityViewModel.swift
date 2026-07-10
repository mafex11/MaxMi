import Foundation
import MaxMiCore
import Observation

@MainActor
@Observable
public final class ActivityViewModel {
    public private(set) var groups: [(day: String, rows: [SessionRow])] = []

    private let load: @Sendable () async -> [TimelineSessionDTO]
    private let now: () -> Int64

    public init(load: @escaping @Sendable () async -> [TimelineSessionDTO], now: @escaping () -> Int64) {
        self.load = load
        self.now = now
    }

    public func refresh() async {
        let dtos = await load()
        let nowMs = now()

        // Map DTOs to rows with precomputed display fields
        let rows = dtos.map { dto in
            SessionRow(
                id: dto.id,
                appLabel: dto.appLabel,
                timeAgo: formatTimeAgo(startedAtMs: dto.startedAtMs, nowMs: nowMs),
                dayGroup: dayGroupLabel(startedAtMs: dto.startedAtMs, nowMs: nowMs),
                summary: dto.summary ?? "Activity in \(dto.appLabel)",
                evidence: dto.evidence
            )
        }

        // Sort by startedAtMs descending (newest first)
        let sorted = rows.sorted { lhs, rhs in
            let lhsMs = dtos.first(where: { $0.id == lhs.id })?.startedAtMs ?? 0
            let rhsMs = dtos.first(where: { $0.id == rhs.id })?.startedAtMs ?? 0
            return lhsMs > rhsMs
        }

        // Group by day
        var grouped: [String: [SessionRow]] = [:]
        for row in sorted {
            grouped[row.dayGroup, default: []].append(row)
        }

        // Sort groups: Today, Yesterday, then dates
        let groupOrder = ["Today", "Yesterday"]
        let sortedGroups = grouped.sorted { lhs, rhs in
            if let lhsIndex = groupOrder.firstIndex(of: lhs.key) {
                if let rhsIndex = groupOrder.firstIndex(of: rhs.key) {
                    return lhsIndex < rhsIndex
                }
                return true
            }
            if groupOrder.contains(rhs.key) {
                return false
            }
            return lhs.key > rhs.key
        }

        groups = sortedGroups.map { (day: $0.key, rows: $0.value) }
    }

    private func formatTimeAgo(startedAtMs: EpochMs, nowMs: EpochMs) -> String {
        let deltaMs = nowMs - startedAtMs
        let minutes = deltaMs / 60_000
        let hours = deltaMs / 3_600_000

        if minutes < 60 {
            return "\(minutes)m ago"
        } else {
            return "\(hours)h ago"
        }
    }

    private func dayGroupLabel(startedAtMs: EpochMs, nowMs: EpochMs) -> String {
        let calendar = Calendar.current
        let startDate = Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0)
        let nowDate = Date(timeIntervalSince1970: Double(nowMs) / 1000.0)

        let startDay = calendar.startOfDay(for: startDate)
        let nowDay = calendar.startOfDay(for: nowDate)

        let dayDiff = calendar.dateComponents([.day], from: startDay, to: nowDay).day ?? 0

        switch dayDiff {
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: startDate)
        }
    }
}
