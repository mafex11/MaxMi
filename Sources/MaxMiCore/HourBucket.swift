import Foundation

public typealias EpochMs = Int64

public func epochNowMs() -> EpochMs {
    EpochMs(Date().timeIntervalSince1970 * 1000)
}

public enum HourBucket {
    public static func bucket(forMs ms: EpochMs) -> Int64 { ms / 3_600_000 }
}
