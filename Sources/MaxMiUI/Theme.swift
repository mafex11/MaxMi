import SwiftUI

public enum Theme {
    // MARK: - Colors (always dark, branded)
    public static let background = Color(white: 0.08)
    public static let surface = Color(white: 0.12)
    public static let text = Color.white
    public static let secondaryText = Color.white.opacity(0.6)
    public static let accent = Color(red: 0.3, green: 0.6, blue: 1.0)

    // MARK: - Spacing (8pt grid)
    public static let spacing1: CGFloat = 8
    public static let spacing2: CGFloat = 16
    public static let spacing3: CGFloat = 24
    public static let spacing4: CGFloat = 32

    // MARK: - Animation
    public static let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)
}
