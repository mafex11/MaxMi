import SwiftUI

public enum Theme {
    // MARK: - Colors (devmafex.com palette — olive-greenish-black + warm neutral)
    // Converted from the portfolio's OKLCH tokens (DESIGN.md / globals.css, .dark mode) to sRGB.
    // bg oklch(0.185 0.021 130), card 0.225, muted 0.295, text 0.920, olive accent 0.485 0.060 125.
    public static let background = Color(red: 0.061, green: 0.0808, blue: 0.0416)  // olive-greenish-black
    public static let surface = Color(red: 0.096, green: 0.1168, blue: 0.0761)     // card
    public static let text = Color(red: 0.9079, green: 0.8955, blue: 0.8618)       // warm-neutral
    public static let secondaryText = Color(red: 0.632, green: 0.6204, blue: 0.5889) // muted-foreground
    public static let tertiaryText = Color(red: 0.632, green: 0.6204, blue: 0.5889).opacity(0.7)
    public static let accent = Color(red: 0.3417, green: 0.3966, blue: 0.2472)     // olive ring
    public static let accentText = Color(red: 0.9079, green: 0.8955, blue: 0.8618)
    public static let success = Color(red: 0.3417, green: 0.3966, blue: 0.2472)    // olive (status dot)
    public static let destructive = Color(red: 1.0, green: 0.3912, blue: 0.4039)   // warm red
    public static let warning = Color.orange
    public static let muted = Color(red: 0.161, green: 0.1835, blue: 0.1403)       // subtle fills
    public static let divider = Color(red: 0.88, green: 0.9, blue: 0.86).opacity(0.12)
    public static let badgeBackground = Color(red: 0.161, green: 0.1835, blue: 0.1403)

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
