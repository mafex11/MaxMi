import Foundation
import MaxMiCore

public enum ReminderTimeValidator {
    public static let maximumFutureMs: EpochMs = 48 * 60 * 60 * 1_000

    public static func accept(
        _ value: String?,
        nowMs: EpochMs,
        timeZone: TimeZone
    ) -> EpochMs? {
        guard let value else {
            return nil
        }
        guard value.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            logRejected()
            return nil
        }

        let date = parse(value, timeZone: timeZone)
        guard let date else {
            logRejected()
            return nil
        }

        let acceptedMs = EpochMs(date.timeIntervalSince1970 * 1_000)
        guard acceptedMs > nowMs, acceptedMs <= nowMs + maximumFutureMs else {
            logRejected()
            return nil
        }
        return acceptedMs
    }

    private static func parse(_ value: String, timeZone: TimeZone) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
            .withColonSeparatorInTimeZone,
        ]
        return formatter.date(from: value)
    }

    private static func logRejected() {
        SafeLogger.shared.log(
            .debug,
            subsystem: .agent,
            event: .agentRunFailed,
            fields: SafeLogFields(operation: SafeLogToken(validating: "remind_at_rejected"))
        )
    }
}
