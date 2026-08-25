import SwiftUI

/// The nodeterm dark look (SPEC §9): black canvas, purple accent, rounded cards. Matching the
/// official app's palette so the self-host client reads as the same product.
public enum Theme {
    /// systemBlue is the desktop accent, but the phone app uses the nodeterm purple.
    public static let accent = Color(red: 0.655, green: 0.545, blue: 0.980)   // #A78BFA
    public static let accentDim = Color(red: 0.545, green: 0.451, blue: 0.855)

    public static let background = Color.black
    public static let card = Color(red: 0.086, green: 0.086, blue: 0.098)      // ~#161619
    public static let cardElevated = Color(red: 0.130, green: 0.130, blue: 0.145)
    public static let separator = Color.white.opacity(0.08)

    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.60)
    public static let textTertiary = Color.white.opacity(0.38)

    // Badge colors (SPEC §6.3).
    public static let running = Color(red: 0.30, green: 0.78, blue: 0.47)       // green pulse
    public static let needsYou = Color(red: 0.98, green: 0.65, blue: 0.20)      // amber
    public static let unread = accent

    public static let corner: CGFloat = 16
}

/// A rounded card surface used throughout HOME/SETTINGS (SPEC §9).
public struct CardBackground: ViewModifier {
    var elevated: Bool = false
    public func body(content: Content) -> some View {
        content
            .background(elevated ? Theme.cardElevated : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
    }
}

public extension View {
    func card(elevated: Bool = false) -> some View { modifier(CardBackground(elevated: elevated)) }
}
