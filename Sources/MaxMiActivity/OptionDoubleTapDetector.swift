import MaxMiCore

public struct OptionDoubleTapDetector: Sendable {
    public static let maxTapHoldMs: EpochMs = 250
    public static let minTapDownIntervalMs: EpochMs = 40
    public static let maxTapDownIntervalMs: EpochMs = 350

    public enum Event: Sendable, Equatable {
        case optionDown(EpochMs)
        case optionUp(EpochMs)
        case otherKeyOrModifier(EpochMs)
    }

    private var firstTapDownMs: EpochMs?
    private var activeTapDownMs: EpochMs?

    public init() {}

    public mutating func consume(_ event: Event) -> Bool {
        switch event {
        case .optionDown(let nowMs):
            guard activeTapDownMs == nil else {
                reset()
                activeTapDownMs = nowMs
                return false
            }
            if let firstTapDownMs,
               nowMs - firstTapDownMs < Self.minTapDownIntervalMs
                || nowMs - firstTapDownMs > Self.maxTapDownIntervalMs {
                self.firstTapDownMs = nil
            }
            activeTapDownMs = nowMs
            return false

        case .optionUp(let nowMs):
            guard let downMs = activeTapDownMs else {
                return false
            }
            activeTapDownMs = nil
            guard nowMs - downMs <= Self.maxTapHoldMs else {
                firstTapDownMs = nil
                return false
            }
            if let firstTapDownMs,
               downMs - firstTapDownMs >= Self.minTapDownIntervalMs,
               downMs - firstTapDownMs <= Self.maxTapDownIntervalMs {
                reset()
                return true
            }
            firstTapDownMs = downMs
            return false

        case .otherKeyOrModifier:
            reset()
            return false
        }
    }

    private mutating func reset() {
        firstTapDownMs = nil
        activeTapDownMs = nil
    }
}
