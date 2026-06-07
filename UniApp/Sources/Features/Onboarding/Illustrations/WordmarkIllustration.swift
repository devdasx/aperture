import SwiftUI

/// Beat 1 — Identity. The welcome slide's hero: the new circle logo
/// (`Brand/LogoCircle.imageset`) at 64pt, carrying the
/// `matchedGeometryEffect` identity that `SplashView` set as its
/// source. When the splash → onboarding transition fires, the logo
/// flies from its splash position (80pt at center Y ≈ 45%) into this
/// frame over 0.82s.
///
/// **2026-06-07 rewrite.** This used to render the bare 7-blade iris
/// from the deleted `ApertureIrisView` Canvas implementation, with a
/// tap-cycle Easter egg that closed/opened the shutter and presented
/// `HelloSheet`. The new design handoff
/// (`design_handoff_splash_to_onboarding/`) replaces that with the
/// dark-gradient circle logo, and the Easter egg is dropped — the
/// new logo is brand identity, not a tappable affordance. The
/// `HelloSheet` view is left in the repo for any future surface that
/// wants it, but no longer reachable from here.
///
/// **No bespoke motion in this view.** The logo blooms in via the
/// splash's Lottie (`splash-logo.json`) on cold launch, then flies
/// here via matchedGeometryEffect on the splash → onboarding
/// transition. After landing, it's static — Ive restraint: one
/// animation, one moment, earned. The `isActive` flag is accepted
/// for API parity with the other illustration views but is unused.
struct WordmarkIllustration: View {
    let isActive: Bool

    /// The namespace `AppRoot` owns. Wired through `OnboardingView`
    /// → `OnboardingSlideView`. Used by `matchedGeometryEffect` to
    /// claim the logo from the splash.
    let logoNamespace: Namespace.ID

    /// The 3-phase machine from `AppRoot`. While `.splash`, the
    /// splash's logo is the matchedGeometryEffect source; once
    /// `.transitioning` fires, this view becomes the source (so the
    /// system resolves the destination frame from here).
    let phase: AppPhase

    var body: some View {
        Image("LogoCircle")
            .resizable()
            .scaledToFit()
            .frame(width: 64, height: 64)
            .matchedGeometryEffect(
                id: "logo",
                in: logoNamespace,
                properties: .frame,
                isSource: phase != .splash
            )
            .accessibilityHidden(true)
    }
}
