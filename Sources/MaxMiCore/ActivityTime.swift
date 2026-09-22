import Foundation

public enum ActivityTime {
    public static func dayBucket(forMs nowMs: EpochMs, timeZone: TimeZone) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(nowMs) / 1_000)
        return EpochMs(calendar.startOfDay(for: date).timeIntervalSince1970 * 1_000)
    }

    public static func ageDescription(detectedAtMs: EpochMs, nowMs: EpochMs) -> String {
        let elapsedHours = max(0, nowMs - detectedAtMs) / 3_600_000
        if elapsedHours < 24 {
            return "\(elapsedHours)h"
        }
        return "\(elapsedHours / 24)d"
    }
}
