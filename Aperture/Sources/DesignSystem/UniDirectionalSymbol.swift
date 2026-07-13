import SwiftUI

/// **RTL-safe SF Symbol names** for navigation and disclosure chrome.
///
/// Fixed-direction symbols (`chevron.right`, `chevron.left`,
/// `arrow.up.right`) do **not** flip when `layoutDirection == .rightToLeft`.
/// Apple’s mirrored pair (`chevron.forward` / `chevron.backward`,
/// `arrow.up.forward`) do — they point with the reading direction.
///
/// Use these names for:
/// - list-row disclosure (push / open detail)
/// - toolbar back
/// - “opens outside the app” external links
///
/// Do **not** use these for semantic money direction (Send = up-and-out,
/// Receive = down-and-in) — those stay `arrow.up.right` / `arrow.down.left`
/// because they describe the action, not layout.
enum UniDirectionalSymbol {
    /// Trailing disclosure on a list row / push navigation.
    /// Replaces fixed `chevron.right`.
    static let disclosure = "chevron.forward"

    /// Back / pop (toolbar leading).
    /// Replaces fixed `chevron.left`.
    static let back = "chevron.backward"

    /// Link that leaves the app (About legal rows, etc.).
    /// Replaces fixed `arrow.up.right`.
    static let external = "arrow.up.forward"

    /// External open as a square glyph (buttons that open a URL).
    /// Replaces fixed `arrow.up.right.square`.
    static let externalSquare = "arrow.up.forward.square"

    /// Inline “from → to” flow arrow (addresses, transfers).
    /// Replaces fixed `arrow.right`.
    static let flow = "arrow.forward"
}

/// Standard trailing disclosure chevron used on inset list rows.
/// Size and tertiary tint match Settings / wallet detail chrome.
/// Automatically mirrors in RTL via `chevron.forward`.
struct UniDisclosureChevron: View {
    var size: CGFloat = 13
    var weight: Font.Weight = .semibold
    var color: Color = UniColors.Icon.tertiary

    var body: some View {
        Image(systemName: UniDirectionalSymbol.disclosure)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Standard external-link glyph (About, legal, open in Safari).
/// Automatically mirrors in RTL via `arrow.up.forward`.
struct UniExternalLinkGlyph: View {
    var size: CGFloat = 12
    var weight: Font.Weight = .semibold
    var color: Color = UniColors.Icon.tertiary

    var body: some View {
        Image(systemName: UniDirectionalSymbol.external)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}
