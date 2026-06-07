import Foundation
import SwiftUI

/// Corner radius scale + semantic surface-radius roles, tuned to iOS 26's
/// own card / row / button rhythm and integrated with `ConcentricRectangle`.
///
/// **The scale (raw values).** A geometric ladder, each step about 1.4×
/// the previous one. Six points cover every surface kind UniApp ships
/// today; new surface kinds add a *role* (below) rather than a new value.
///
///     xs  6   tightest pill / chip
///     s   10  controls (UniTextField, list cells)
///     m   14  small cards, dense surfaces
///     l   18  standard content cards (the project's most-used radius)
///     xl  22  hero cards (Receive QR, splash-family surfaces)
///     xxl 28  full-screen feature surfaces
///
/// The previous scale topped out at `xl: 24` and `xxl: 32`. After auditing
/// against Apple's own iOS 26 surfaces (Wallet, Apple Cash, Maps "Place"
/// cards, Settings cards) the top two values were tightened — those cards
/// land at ~18–22pt, not 24–32pt. The 2-point tightening on `xl` (24→22)
/// removes the slightly toy-like rounded-pillow feel from hero cards
/// without losing their identity, and `xxl` (32→28) brings full-screen
/// feature surfaces into the same rhythm.
///
/// **The roles (what feature code should use).** Feature code reaches for
/// a semantic *role*, not a raw size, so the call site reads as intent.
/// "This is a card" is what the design system expresses; "this is 18 pt"
/// is what it implements. The roles below ARE the public surface:
///
/// | Role               | Raw  | Use for                                     |
/// |--------------------|------|---------------------------------------------|
/// | `UniRadius.card`   | 18   | Default content card — wallet rows, holdings, activity, banners. The most-used surface kind. |
/// | `UniRadius.hero`   | 22   | Hero cards — Receive QR card, splash-family brand surfaces. |
/// | `UniRadius.row`    | 14   | Inset-grouped row surfaces, dense list cells. |
/// | `UniRadius.control`| 10   | Buttons, text fields, chips. (Glass system buttons own their own capsule shape — this is for non-glass controls.) |
/// | `UniRadius.chip`   | 6    | Smallest pill / tag. |
///
/// New feature code should reference roles. The raw scale (`xs` … `xxl`)
/// remains available for components inside `DesignSystem/Components/`
/// that need a specific rung — those components publish their resolved
/// role to feature code.
///
/// **`ConcentricRectangle` integration (iOS 26 native concentric corners).**
/// iOS 26 introduces `ConcentricRectangle`, a `Shape` that automatically
/// inherits its corner radius from its parent's container shape — no more
/// hand-computed `max(0, parent − padding)` per call site. The canonical
/// pattern:
///
/// ```swift
/// UniCard { … }                              // sets .containerShape internally
///     .padding(.horizontal, UniSpacing.m)    // any inset
///
/// // inside the card's content:
/// ConcentricRectangle()                      // auto-inherits the card's radius − inset
///     .fill(UniColors.Material.elevated)
/// ```
///
/// `UniCard` now declares `.containerShape(.rect(cornerRadius: cornerRadius))`
/// on its background so any descendant `ConcentricRectangle()` resolves
/// without the call site needing to know the parent's radius. The legacy
/// `nested(parent:padding:)` helper below stays in the file for surfaces
/// that haven't migrated to `ConcentricRectangle()` yet — but it is
/// **deprecated** for new code.
///
/// References (consulted 2026-06-07 against the live iOS 26 SDK docs):
/// - `developer.apple.com/documentation/swiftui/concentricrectangle`
/// - `nilcoalescing.com/blog/ConcentricRectangleInSwiftUI/`
/// - `createwithswift.com/exploring-concentricity-in-swiftui/`
enum UniRadius {

    // MARK: - Raw scale

    /// 6 pt — tight chips, dense controls.
    static let xs: CGFloat = 6
    /// 10 pt — small buttons, controls.
    static let s: CGFloat = 10
    /// 14 pt — list rows, dense surfaces.
    static let m: CGFloat = 14
    /// 18 pt — standard content cards.
    static let l: CGFloat = 18
    /// 22 pt — hero cards (Receive QR, splash family).
    static let xl: CGFloat = 22
    /// 28 pt — full-screen feature surfaces.
    static let xxl: CGFloat = 28

    // MARK: - Semantic roles (the preferred public surface)

    /// Default content card — wallet rows, holdings, activity, banners.
    /// Resolves to `l` (18). The single most-used surface kind in the app.
    static let card: CGFloat = l

    /// Hero card — Receive QR card, splash-family surfaces. Slightly more
    /// curvature than a standard card to read as a moment, not as routine
    /// chrome. Resolves to `xl` (22).
    static let hero: CGFloat = xl

    /// Inset-grouped row surface or dense list cell. Resolves to `m` (14).
    static let row: CGFloat = m

    /// Non-glass control surfaces (buttons that don't use `.buttonStyle(.glass)`,
    /// text fields, chips). The native glass button styles own their own
    /// capsule shape and don't consume this. Resolves to `s` (10).
    static let control: CGFloat = s

    /// Smallest pill / tag. Resolves to `xs` (6).
    static let chip: CGFloat = xs

    // MARK: - Concentric helpers

    /// Legacy concentric-corner math. Preserved for surfaces that have not
    /// migrated to iOS 26's `ConcentricRectangle()`. **Prefer
    /// `ConcentricRectangle()` inside a `.containerShape(.rect(cornerRadius:))`
    /// parent for new code** — it does this math automatically and reads
    /// as intent at the call site.
    @available(*, deprecated, message: "Use ConcentricRectangle() inside a .containerShape(.rect(cornerRadius:)) parent instead.")
    static func nested(parent: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, parent - padding)
    }
}
