import Foundation
import CoreGraphics

/// Pure, testable placement math for the right-lane meeting recorder panel.
/// macOS coordinate system: origin at bottom-left. visibleFrame.maxY = TOP edge.
public enum RightLanePlacement {
    /// Given a screen visibleFrame and panel size, return the docked right-edge origin.
    ///
    /// - Parameters:
    ///   - visibleFrame: The screen's visible frame (origin bottom-left in macOS coords).
    ///   - panelSize: The panel's size.
    ///   - topInset: Distance DOWN from the top edge (maxY) to the panel's top edge. Default 80pt.
    ///   - margin: Margin from the right edge. Default 16pt.
    /// - Returns: The panel's origin point (bottom-left corner in macOS coords).
    public static func origin(inScreen visibleFrame: CGRect, panelSize: CGSize, topInset: CGFloat = 80, margin: CGFloat = 16) -> CGPoint {
        // Right-docked: x = right edge - panel width - margin
        let x = visibleFrame.maxX - panelSize.width - margin

        // Top inset from the top: macOS origin is bottom-left, so top = maxY.
        // Panel's origin.y is its BOTTOM edge. To place the panel's TOP at (maxY - topInset):
        // origin.y = (maxY - topInset) - panelSize.height
        let y = visibleFrame.maxY - topInset - panelSize.height

        return CGPoint(x: x, y: y)
    }

    /// Choose the best screen for the panel.
    ///
    /// - Parameters:
    ///   - meetingWindow: The meeting app's window frame, if available.
    ///   - screens: Array of screen frames (visibleFrame for each screen).
    ///   - cursor: The current cursor position.
    /// - Returns: The chosen screen's frame.
    ///
    /// Strategy:
    /// 1. If meetingWindow is provided and intersects a screen, return that screen.
    /// 2. Else, return the screen containing the cursor.
    /// 3. Else, return the first screen (fallback).
    public static func chooseScreen(meetingWindow: CGRect?, screens: [CGRect], cursor: CGPoint) -> CGRect {
        guard !screens.isEmpty else {
            // Fallback to a default rect if no screens (shouldn't happen)
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }

        // 1. Check if meeting window intersects any screen
        if let window = meetingWindow {
            for screen in screens {
                if screen.intersects(window) {
                    return screen
                }
            }
        }

        // 2. Fall back to the screen containing the cursor
        for screen in screens {
            if screen.contains(cursor) {
                return screen
            }
        }

        // 3. Fall back to the first screen
        return screens[0]
    }
}
