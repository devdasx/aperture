import SwiftUI
import Lottie

/// Aperture's launch splash — the brand's first breath.
///
/// **2026-06-07 — Lottie splash, take 2 (kit v2).** Replaces the brand-
/// kit-v1 `splash-tile.json` (white iris on Aperture Blue gradient
/// squircle) with the **flat mark** variants per the v2 user direction:
/// `splash-black.json` in light mode, `splash-white.json` in dark mode.
/// The flat mark on a `UniColors.Background.primary` surface (Cloud
/// light / Ink dark) is the brand owner's chosen reading of the splash —
/// the iris is the brand identity, the surface around it is the user's
/// device chrome. The tile variant remains bundled for any future
/// surface that wants the icon-tile feel (it's still in `Resources/Lottie/`)
/// but the splash is now the flat mark on flat background.
///
/// **Rule #3 §B exception.** Lottie iOS is the second logged exception
/// (joining Trust Wallet Core) per the v1 SHIPPED entry.
///
/// **Failure mode.** If the Lottie JSON fails to load (bundle path
/// missing, corrupt JSON), `LottieView` renders empty. We still fire
/// `onComplete` after `splashDuration` so the app doesn't sit on a blank
/// screen — the user reaches onboarding either way.
struct SplashView: View {
    /// Called once the splash animation has played through. Driven by a
    /// timer at `splashDuration` so the contract holds even if Lottie
    /// fails silently.
    let onComplete: () -> Void

    /// Total wall time the splash holds before calling onComplete.
    /// Matches the brand-kit-documented splash duration (1.4s bloom +
    /// modest hold so the user reads the brand mark) — `splash` is a
    /// one-shot per the kit's README.
    private static let splashDuration: TimeInterval = 1.8

    /// Selects the dark variant in dark mode, the light variant in light
    /// mode (and System-Auto resolves via the parent environment per
    /// Rule #12's `.uniAppEnvironment()` propagation).
    @Environment(\.colorScheme) private var colorScheme

    /// Lottie animation name per the brand kit v2 split:
    /// - Light mode → `splash-black` (black iris on transparent / Cloud surface)
    /// - Dark mode  → `splash-white` (white iris on transparent / Ink surface)
    private var animationName: String {
        colorScheme == .dark ? "splash-white" : "splash-black"
    }

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()

            LottieView(animation: .named(animationName))
                .playing(loopMode: .playOnce)
                .frame(width: 200, height: 200)
        }
        .accessibilityLabel(Text("Aperture"))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.splashDuration) {
                onComplete()
            }
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    SplashView(onComplete: {})
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SplashView(onComplete: {})
        .preferredColorScheme(.dark)
}
