import SwiftUI

// MARK: - UniEmptyState

/// Aperture's canonical empty-state surface.
///
/// **Design intent (Rule #2 §D.1).** When the user is looking at a card
/// that has nothing in it yet, the surface must read as calmly present —
/// not as a void, not as an alert, not as a "buy crypto now" promotion.
/// The user is in *Aperture's* empty home, not in *an* empty card. The
/// iris watermark anchors that — the brand is quietly there even when the
/// data isn't.
///
/// **Composition.**
/// - A soft elliptical lift inside the card (re-using `UniColors.Splash`
///   roles, so the empty surface threads visually to the launch screen
///   the user just saw — same monochrome material lineage).
/// - A 72pt mark at low opacity, gently breathing on a 6-second loop
///   (Reduce Motion → static at the resting opacity).
/// - A two-line copy block — a primary line that names what the empty
///   surface IS (`UniBody`, `Text.secondary`), and a secondary line that
///   names how the user moves from absence to presence (`UniFootnote`,
///   `Text.tertiary`).
///
/// **Mark style.** `.iris` for brand-touching surfaces (the wallet's own
/// emptiness — wallet-home holdings & activity); `.icon(systemName:)` for
/// neutral domain surfaces (no contacts, no scanned tokens, no transactions
/// inside a filter). Per Rule #7, the iris is a real brand asset; the
/// SF Symbol variant is also a real Apple-designed glyph. No hand-built
/// shapes.
///
/// **Layering (Rule #2 §B.3).** The empty state is content layer
/// (opaque) sitting beneath the wallet's functional glass chrome. The
/// inner elliptical lift is NOT glass — it's a soft elliptical gradient
/// painted on the card's own opaque surface, no translucency, no
/// specular. This avoids stacking glass on glass on glass on glass on a
/// surface that doesn't move (Rule #2 §B.3 "no glass on long-form content").
///
/// **Reduce Motion (Rule #2 §B.6).** The breath cycle skips when the user
/// has Reduce Motion enabled — the mark renders static at its mean opacity
/// (0.08), still anchoring the surface as Aperture's, just without the
/// breath.
///
/// **Concentric corners.** Background lift and any future inset surface
/// use `ConcentricRectangle()` inside the card's `.containerShape`, so
/// the math is system-driven. (Rule #2 §B.4 via iOS 26 native API.)
struct UniEmptyState: View {

    enum Mark {
        /// Aperture iris mark from `Brand/Mark.imageset`. Use for surfaces
        /// where the wallet itself is the subject (holdings, activity,
        /// recovery, security).
        case iris
        /// SF Symbol for neutral domain surfaces (no contacts, no
        /// search results). Apple-designed; bare glyph, no `.circle`
        /// suffix (M-003).
        case icon(systemName: String)
    }

    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var mark: Mark = .iris

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing: Bool = false

    /// Mean opacity of the watermark mark. The breath cycle modulates
    /// around this value (`mean ± amplitude`) so the mark is always
    /// present, never absent — the breath is presence affirming itself,
    /// not entrance / exit. Tuned against the design handoff's mono
    /// brand register: low enough to read as watermark, high enough to
    /// be undeniably *the iris*.
    private static let watermarkOpacity: Double = 0.08
    private static let breathAmplitude: Double = 0.04
    private static let breathPeriod: Double = 6.0

    var body: some View {
        ZStack {
            // Card surface — opaque content layer (Rule #2 §B.3).
            // `UniCard`'s own background paints this; we just declare
            // the radius here for the lift and watermark to inherit.
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Material.card)

            // Soft elliptical lift — re-uses the splash family so the
            // empty surface visually threads to the launch screen. The
            // gradient's center sits above the card center to mirror
            // the splash's "lift at 50% × 38%" geometry.
            EllipticalGradient(
                colors: [UniColors.Splash.lift, UniColors.Splash.base],
                center: UnitPoint(x: 0.5, y: 0.32),
                startRadiusFraction: 0.0,
                endRadiusFraction: 0.95
            )
            .opacity(0.35) // Restrained — the lift is a hint, not a hero.
            .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // Content stack — mark + copy.
            VStack(spacing: UniSpacing.m) {
                watermark
                    .accessibilityHidden(true)

                VStack(spacing: UniSpacing.xs) {
                    UniBody(
                        text: title,
                        alignment: .center,
                        color: UniColors.Text.secondary
                    )
                    UniFootnote(
                        text: detail,
                        alignment: .center,
                        color: UniColors.Text.tertiary
                    )
                }
                .padding(.horizontal, UniSpacing.l)
            }
            .padding(.vertical, UniSpacing.xxl)
            .frame(maxWidth: .infinity)
        }
        // iOS 26 concentric corners — any future inset shape inside
        // this empty state inherits this radius via `ConcentricRectangle()`.
        .containerShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
        .onAppear {
            guard !reduceMotion else { return }
            // Begin the breath cycle on first appear; SwiftUI keeps it
            // running until the view leaves the hierarchy.
            withAnimation(
                .easeInOut(duration: Self.breathPeriod / 2)
                    .repeatForever(autoreverses: true)
            ) {
                isBreathing = true
            }
        }
    }

    // MARK: - Watermark mark

    @ViewBuilder
    private var watermark: some View {
        switch mark {
        case .iris:
            // Iris brand mark — sized to feel like a watermark, tinted
            // through `UniColors.Brand.mark` so it lands Ink in light /
            // Cloud in dark. The breath modulates opacity only — no
            // scale, no rotation, no positional motion (that would
            // read as decoration; opacity-only reads as breath).
            ApertureIrisView()
                .frame(width: 72, height: 72)
                .opacity(currentWatermarkOpacity)
        case .icon(let systemName):
            // Bare SF Symbol — same scale and breath as the iris so
            // the two empty-state kinds read as siblings.
            Image(systemName: systemName)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
                .opacity(currentWatermarkOpacity * 3)
                // Symbol-form scales opacity differently — symbols are
                // smaller and already monochrome, so they read at a
                // higher absolute opacity. The ×3 keeps the symbol
                // variant legible while the iris stays watermark-soft.
        }
    }

    /// Resolves the current opacity in the breath cycle. Reduce Motion
    /// short-circuits to the mean opacity (no animation, just present).
    private var currentWatermarkOpacity: Double {
        guard !reduceMotion else { return Self.watermarkOpacity }
        return isBreathing
            ? Self.watermarkOpacity + Self.breathAmplitude
            : Self.watermarkOpacity - Self.breathAmplitude
    }
}

// MARK: - Previews

#Preview("Holdings empty — iris (light)") {
    VStack(spacing: UniSpacing.l) {
        UniEmptyState(
            title: "Your holdings will appear here.",
            detail: "Receive crypto to any of your addresses and it'll show up the moment it lands on-chain."
        )
        UniEmptyState(
            title: "No activity yet.",
            detail: "Transactions appear here as they confirm on-chain."
        )
    }
    .padding(UniSpacing.l)
    .background(UniColors.Background.primary)
    .preferredColorScheme(.light)
}

#Preview("Holdings empty — iris (dark)") {
    VStack(spacing: UniSpacing.l) {
        UniEmptyState(
            title: "Your holdings will appear here.",
            detail: "Receive crypto to any of your addresses and it'll show up the moment it lands on-chain."
        )
        UniEmptyState(
            title: "No activity yet.",
            detail: "Transactions appear here as they confirm on-chain."
        )
    }
    .padding(UniSpacing.l)
    .background(UniColors.Background.primary)
    .preferredColorScheme(.dark)
}

#Preview("Neutral symbol variant") {
    UniEmptyState(
        title: "No matching results.",
        detail: "Try a different search.",
        mark: .icon(systemName: "magnifyingglass")
    )
    .padding(UniSpacing.l)
    .background(UniColors.Background.primary)
}
