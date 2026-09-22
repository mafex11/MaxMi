import CoreGraphics

public enum OutsideClickPolicy {
    public static func shouldClose(clickLocation: CGPoint, panelFrame: CGRect) -> Bool {
        !panelFrame.contains(clickLocation)
    }
}
