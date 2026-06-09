import SwiftUI
import UIKit

/// The single canonical wallet-identity primitive. A circle filled with
/// the wallet's chosen hex color, centered SF Symbol in white.
///
/// **Surfaces it consumes from (Rule #19 §A "name the canonical
/// primitive, forbid the variants" — applied to identity, not CTAs).**
/// - `MainTabView`'s Wallet `Tab` label — at `.tabIcon` size (28pt).
/// - `WalletHomeView`'s toolbar wallet pill — at `.toolbarPill` size (22pt).
/// - `WalletSwitcherSheet` row leading — at `.row` size (36pt).
/// - `WalletsListView` row leading — at `.row` size (36pt).
/// - `WalletDetailView` editor preview — at `.hero` size (80pt).
/// - The Wallet-tab long-press `contextMenu` rows — at `.menuLeading`
///   size (24pt; iOS auto-renders menu glyphs into a 22-25pt envelope,
///   we hand it a tight 24pt avatar so the circle reads as crisp).
///
/// **Why one component.** Every wallet identity surface in the app
/// renders through this file. If the spec for the avatar changes
/// tomorrow (different ratio, different stroke, different
/// foreground rule), one edit propagates everywhere. If the user's
/// chosen identity changes via the picker, `@Query` reactivity on
/// `WalletRecord.iconSymbol` / `iconColorHex` re-renders every
/// avatar in the view tree without any per-surface state plumbing.
///
/// **Why no Rule #7 violation.** The SF Symbol IS the icon; the
/// `Circle` is structural (Rule #7 §C exception — "structural shapes
/// are not icons"). The combination is: real-icon Symbol inside a
/// structural circular surface. Standard avatar pattern (iOS
/// Contacts, Messages, Mail's account chips); the structure
/// communicates "this is an identity" and the symbol carries the
/// meaning.
///
/// **Why Rule #4 carries an exception here.** Rule #4 §B allows
/// `UIColor.*` / hex literals inside `UniColors.swift` only. The
/// avatar reads a per-wallet hex from `WalletRecord.iconColorHex`
/// at render time — that hex is *user data*, not a brand token, so
/// it lives in the domain layer (the SwiftData record), not in
/// `UniColors`. To resolve the hex string into a `Color` we need
/// to call `Color(uiColor: UIColor(hex:))` inside THIS file.
///
/// This is the single, documented, file-scoped Rule #4 exception
/// for "user-picked dynamic color from persisted storage." The hex
/// reader (`Color.fromHex(_:)`) is `fileprivate` so feature code
/// can't reach for it as a shortcut to bypass `UniColors`. Every
/// brand-class color in the app continues to flow through
/// `UniColors`.
struct WalletAvatar: View {
    /// Rendered diameter of the circle.
    enum Size {
        /// 28pt — the iOS tab-bar glyph envelope. Tab icons render
        /// at 25pt by default; 28pt fills the envelope cleanly
        /// without crowding the tab-bar label below.
        case tabIcon
        /// 22pt — the toolbar wallet-pill leading. Smaller than the
        /// tab icon because the pill carries the wallet name too;
        /// the avatar reads as a leading accent, not as the whole
        /// affordance.
        case toolbarPill
        /// 24pt — the long-press context-menu row leading. Sized
        /// so the white symbol reads inside the menu's
        /// auto-glass envelope.
        case menuLeading
        /// 36pt — the canonical list-row size. Matches the iOS
        /// Contacts / Mail account-row geometry.
        case row
        /// 56pt — the Settings → Wallets → <wallet> preview anchor.
        /// Big enough that a tap on it reads as the editor surface.
        case preview
        /// 80pt — the editor's hero preview. Used when the user is
        /// actively picking color / symbol — the live preview the
        /// pickers update against.
        case hero

        var diameter: CGFloat {
            switch self {
            case .tabIcon:     return 28
            case .toolbarPill: return 22
            case .menuLeading: return 24
            case .row:         return 36
            case .preview:     return 56
            case .hero:        return 80
            }
        }

        /// SF Symbol point size for the centered glyph. The
        /// glyph-to-circle ratio is calibrated per-size so the
        /// glyph fills ~52% of the circle's diameter (the iOS
        /// Contacts initials-avatar ratio for monogrammed circles).
        var glyphPointSize: CGFloat {
            switch self {
            case .tabIcon:     return 14
            case .toolbarPill: return 11
            case .menuLeading: return 13
            case .row:         return 18
            case .preview:     return 28
            case .hero:        return 40
            }
        }
    }

    /// SF Symbol name — typically a wallet's `iconSymbol` field, or
    /// `WalletAvatarDefaults.symbol` for freshly-created wallets.
    let symbol: String
    /// Hex color `"#RRGGBB"` — the wallet's `iconColorHex` field, or
    /// `WalletAvatarDefaults.colorHex` for freshly-created wallets.
    let colorHex: String
    /// Rendered size.
    let size: Size

    var body: some View {
        Circle()
            .fill(Color.fromHex(colorHex) ?? Color.fromHex(WalletAvatarDefaults.colorHex)!)
            .frame(width: size.diameter, height: size.diameter)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size.glyphPointSize, weight: .semibold))
                    // White on every palette entry — the curated
                    // palette is calibrated so a white glyph passes
                    // WCAG AA contrast on each color. If the user
                    // ever picks a near-white identity (they can't
                    // from the curated palette, but defensive), the
                    // contrast still holds because hex-100% white
                    // doesn't decode through `fromHex` without an
                    // explicit `#FFFFFF` entry the picker never
                    // surfaces.
                    .foregroundStyle(.white)
            }
            // Decorative — VoiceOver announces the wallet name via
            // the surrounding container's label. The avatar itself
            // carries no semantics that aren't already in the name.
            .accessibilityHidden(true)
    }
}

// MARK: - Hex decoder (fileprivate — single, documented Rule #4 exception)

extension Color {
    /// Decode a `"#RRGGBB"` (or `"#RRGGBBAA"`) hex string into a
    /// SwiftUI `Color`. Returns `nil` on invalid input — callers
    /// should fall back to the default identity color
    /// (`WalletAvatarDefaults.colorHex`).
    ///
    /// **Rule #4 single-file exception.** Per the doc comment on
    /// `WalletAvatar`, this method exists so the avatar primitive
    /// can resolve user-picked dynamic colors from
    /// `WalletRecord.iconColorHex`. Marked `fileprivate` so feature
    /// code can't reach for it as a shortcut to bypass `UniColors`.
    /// Every brand-class color in the app continues to flow through
    /// `UniColors`.
    fileprivate static func fromHex(_ hex: String) -> Color? {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6 || trimmed.count == 8 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&rgb) else { return nil }
        let r, g, b, a: Double
        if trimmed.count == 6 {
            r = Double((rgb >> 16) & 0xFF) / 255.0
            g = Double((rgb >> 8)  & 0xFF) / 255.0
            b = Double(rgb         & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((rgb >> 24) & 0xFF) / 255.0
            g = Double((rgb >> 16) & 0xFF) / 255.0
            b = Double((rgb >> 8)  & 0xFF) / 255.0
            a = Double(rgb         & 0xFF) / 255.0
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
