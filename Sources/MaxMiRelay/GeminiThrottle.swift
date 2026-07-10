import Foundation
import MaxMiCore

public actor GeminiThrottle {
    private var lastRequestTime: Date?
    private var backoffUntil: Date?
    private var consecutiveFailures = 0

    public init() {}

    public func waitIfNeeded() async {
        if let backoff = backoffUntil, backoff > Date() {
            let delay = backoff.timeIntervalSinceNow
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            let minInterval = 0.1
            if elapsed < minInterval {
                try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
            }
        }

        lastRequestTime = Date()
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
