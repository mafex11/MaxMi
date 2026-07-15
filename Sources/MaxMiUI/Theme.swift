import SwiftUI

public enum Theme {
    // MARK: - Colors (always dark, branded — matched to Minimi's popover palette)
    // Sampled from Minimi 1.0.x: bg #242525, card #2f2f2f, muted-green CTA #41503b,
    // white primary text, ~#6d6d6d secondary.
    public static let background = Color(red: 0.141, green: 0.145, blue: 0.145)   // #242525
    public static let surface = Color(red: 0.184, green: 0.184, blue: 0.184)      // #2f2f2f
    public static let text = Color.white
    public static let secondaryText = Color(red: 0.427, green: 0.427, blue: 0.427) // #6d6d6d
    public static let tertiaryText = Color.white.opacity(0.45)
    public static let accent = Color(red: 0.255, green: 0.314, blue: 0.231)        // #41503b muted green
    public static let accentText = Color.white
    public static let success = Color(red: 0.259, green: 0.384, blue: 0.208)       // #426235 status dot
    public static let destructive = Color.red
    public static let warning = Color.orange
    public static let divider = Color.white.opacity(0.08)
    public static let badgeBackground = Color.white.opacity(0.08)

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

public extension View {
    /// Minimal, consistent settings section header: small, uppercase, muted.
    func sectionTitle() -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundColor(Theme.secondaryText)
    }
}
