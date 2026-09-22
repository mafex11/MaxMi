import AppKit
import MaxMiCore

public enum OptionEventMapper {
    private static let otherModifierFlags: NSEvent.ModifierFlags = [
        .shift, .control, .command, .function,
    ]

    public static func map(
        flags: NSEvent.ModifierFlags,
        isOptionDown: Bool,
        timestampMs: EpochMs
    ) -> OptionDoubleTapDetector.Event? {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection(otherModifierFlags).isEmpty else {
            return .otherKeyOrModifier(timestampMs)
        }

        let nextOptionIsDown = flags.contains(.option)
        guard nextOptionIsDown != isOptionDown else {
            return nil
        }
        return nextOptionIsDown ? .optionDown(timestampMs) : .optionUp(timestampMs)
    }
}
