import SwiftUI

/// The Aperture iris mark — Aperture's canonical brand glyph, rendered from
/// the static "Iris Solid" SVG shipped in the 2026-06-07 brand kit
/// (`Assets.xcassets/Brand/Mark.imageset`).
///
/// **What changed 2026-06-07.** The view used to render a live 7-blade
/// aperture diaphragm from a `Canvas` — the geometry was a port of
/// `animated-logo.html`'s `geom(rc, rot)` JS function with `rc` driving the
/// opening radius for the splash animation. The new brand identity ships a
/// solid 6-blade "Iris Solid" mark as a flat vector asset; there is no
/// opening to animate. The view's API is preserved (callers still pass
/// `rc` / `rot`) so `SplashView` + `ApertureMotion.splash(at:)` continue
/// to work unchanged, but `rc` is now ignored — the mark is static. The
/// splash bloom is carried by `rot`, `opacity`, and `scaleEffect` at the
/// call site, which is what `ApertureMotion.Frame` was already supplying.
///
/// **Asset routing.** The image set has a black mark for light mode and a
/// white mark for dark mode (set via `.luminosity` appearance in the
/// catalog), so the glyph reads against either background without any
/// runtime color resolution. The `ringColor` parameter is kept for API
/// compatibility but is now applied as a `.foregroundStyle` tint on the
/// template-rendered image — pass `UniColors.Brand.mark` (the default)
/// to use the brand Ink/Cloud tone; pass `UniColors.Tint.accent` to use
/// Aperture Blue.
///
/// **Rule #3 / Rule #7.** The mark is the real designed asset from the
/// brand kit (Rule #7 — real visuals only), rendered through SwiftUI's
/// native `Image` + asset catalog (Rule #3 — system APIs only). Zero
/// third-party dependencies. The previous Canvas implementation was a
/// faithful programmatic port but the brand has moved on; this view now
/// follows.
struct ApertureIrisView: View {
    /// Legacy opening-radius parameter. Now ignored — the static mark
    /// doesn't have an opening to animate. Kept so `ApertureMotion.Frame`
    /// callers don't need to change.
    let rc: CGFloat

    /// Rotation of the mark, in radians. Driven by `ApertureMotion.splash`
    /// during the bloom phase (starts at -0.55, eases to 0). Applied as a
    /// `.rotationEffect` on the asset.
    let rot: CGFloat

    /// Tint color applied to the template-rendered mark. Defaults to
    /// `UniColors.Brand.mark` (Ink in light mode, Cloud in dark mode).
    /// Pass `UniColors.Tint.accent` for the Aperture Blue accent.
    let ringColor: Color

    /// Legacy parameter from the Canvas implementation (was the
    /// negative-space color used to carve the seams). The static mark has
    /// no carving so this is now ignored. Kept for API compatibility.
    let negativeColor: Color

    init(
        rc: CGFloat = ApertureIrisView.openValue,
        rot: CGFloat = 0,
        ringColor: Color = UniColors.Brand.mark,
        negativeColor: Color = UniColors.Background.primary
    ) {
        self.rc = rc
        self.rot = rot
        self.ringColor = ringColor
        self.negativeColor = negativeColor
    }

    // MARK: - Legacy constants

    /// Preserved for `ApertureMotion.splash(at:)`. With the new static mark
    /// these values no longer drive an opening; they're left in place so
    /// the motion struct's defaults still compile and read sensibly.
    static let openValue: CGFloat = 17
    static let shutValue: CGFloat = 2.4

    // MARK: - Body

    var body: some View {
        // Image name is bare "Mark" because the parent `Brand/`
        // folder in `Assets.xcassets` does NOT carry
        // `provides-namespace: true` in its `Contents.json` — image
        // assets inside Brand/ are addressed by their leaf name
        // (this matches how `Color("BrandMark")` resolves from
        // `Brand/BrandMark.colorset`). The 2026-06-07 brand-refresh
        // first cut used `Image("Brand/Mark")`, which silently
        // returned an empty image — the welcome slide rendered with
        // a blank top half (user-reported 2026-06-07 13:59 screenshot).
        Image("Mark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(ringColor)
            .rotationEffect(.radians(Double(rot)))
            .accessibilityHidden(true) // Decorative — the surrounding view labels.
    }
}

// MARK: - Previews

#Preview("Light — brand mark tint") {
    ApertureIrisView()
        .frame(width: 200, height: 200)
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Dark — brand mark tint") {
    ApertureIrisView()
        .frame(width: 200, height: 200)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Aperture Blue accent") {
    ApertureIrisView(ringColor: UniColors.Tint.accent)
        .frame(width: 200, height: 200)
        .padding()
}

#Preview("Rotated mid-bloom") {
    ApertureIrisView(rot: -0.55)
        .frame(width: 200, height: 200)
        .padding()
}
