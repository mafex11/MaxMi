import Foundation

public struct SegmentDecision: Sendable, Equatable {
    public let closePrevious: Bool
    public let openNew: Bool

    public init(closePrevious: Bool, openNew: Bool) {
        self.closePrevious = closePrevious
        self.openNew = openNew
    }
}

public enum SessionSegmenter {
    /// Pure: given the current open session's app + last-activity time, and the new event's app + time,
    /// decide whether to close the old session and/or open a new one. gapMs = inactivity threshold.
    public static func decide(
        openApp: String?,
        lastActivityMs: EpochMs?,
        eventApp: String,
        eventMs: EpochMs,
        gapMs: EpochMs = 5*60_000
    ) -> SegmentDecision {
        // No open session → open only
        guard let openApp = openApp, let lastActivityMs = lastActivityMs else {
            return SegmentDecision(closePrevious: false, openNew: true)
        }

        // Different app → close old + open new
        if openApp != eventApp {
            return SegmentDecision(closePrevious: true, openNew: true)
        }

        // Same app: check gap
        let elapsed = eventMs - lastActivityMs
        if elapsed > gapMs {
            // Same app after gap → new session
            return SegmentDecision(closePrevious: true, openNew: true)
        } else {
            // Same app within gap → continue
            return SegmentDecision(closePrevious: false, openNew: false)
        }
    }
}
