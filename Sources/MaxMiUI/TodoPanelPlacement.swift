import CoreGraphics

public enum TodoPanelPlacement {
    public static func centeredFrame(
        panelSize: CGSize,
        screenVisibleFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: screenVisibleFrame.midX - panelSize.width / 2,
            y: screenVisibleFrame.midY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}
