import Foundation
import MaxMiCore

public actor GeminiThrottle {
    public static let shared = GeminiThrottle()

    private var lastRequestTime: Date?
    private var backoffUntil: Date?
    private var consecutiveFailures = 0

    public init() {}

    public func waitIfNeeded() async {
        // Reserve the next allowed request time SYNCHRONOUSLY before any await to prevent reentrancy races
        let now = Date()
        let nextAllowed: Date

        if let backoff = backoffUntil, backoff > now {
            nextAllowed = backoff
        } else if let last = lastRequestTime {
            let minInterval = 0.1
            let elapsed = now.timeIntervalSince(last)
            if elapsed < minInterval {
                nextAllowed = last.addingTimeInterval(minInterval)
            } else {
                nextAllowed = now
            }
        } else {
            nextAllowed = now
        }

        // Reserve this slot before sleeping
        lastRequestTime = max(nextAllowed, now)

        // Now sleep if needed
        let delay = nextAllowed.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    public func recordSuccess() {
        consecutiveFailures = 0
        backoffUntil = nil
    }

    public func recordFailure(statusCode: Int) {
        if statusCode == 429 {
            consecutiveFailures += 1
            let baseDelay = 1.0
            let maxDelay = 60.0
            let exponential = min(baseDelay * pow(2.0, Double(consecutiveFailures - 1)), maxDelay)
            let jitter = Double.random(in: 0...(exponential * 0.1))
            backoffUntil = Date().addingTimeInterval(exponential + jitter)
        }
    }
}
