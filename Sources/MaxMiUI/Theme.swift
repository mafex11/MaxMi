import SwiftUI

public enum Theme {
    // MARK: - Colors (always dark, branded)
    public static let background = Color(white: 0.08)
    public static let surface = Color(white: 0.12)
    public static let text = Color.white
    public static let secondaryText = Color.white.opacity(0.8)
    public static let tertiaryText = Color.white.opacity(0.6)
    public static let accent = Color(red: 0.3, green: 0.6, blue: 1.0)
    public static let success = Color.green
    public static let destructive = Color.red
    public static let warning = Color.orange
    public static let divider = Color.white.opacity(0.2)
    public static let badgeBackground = Color.white.opacity(0.2)

    // MARK: - Spacing (8pt grid)
    public static let spacing0: CGFloat = 0
    public static let spacingHalf: CGFloat = 4
    public static let spacing1: CGFloat = 8
    public static let spacing2: CGFloat = 16
    public static let spacing3: CGFloat = 24
    public static let spacing4: CGFloat = 32

    // MARK: - Corner Radius
    public static let cornerRadiusSmall: CGFloat = 4
    public static let cornerRadius: CGFloat = 8
    public static let cornerRadiusLarge: CGFloat = 12

    // MARK: - Typography (sizes)
    public static let iconSizeSmall: CGFloat = 20
    public static let iconSizeMedium: CGFloat = 28
    public static let iconSizeLarge: CGFloat = 48

    // MARK: - Animation
    public static let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)
}
