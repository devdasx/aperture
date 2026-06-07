import SwiftUI
import Lottie

/// Aperture's launch splash — the brand's first breath.
///
/// **2026-06-07 — Lottie splash.** Replaces the earlier SwiftUI-native
/// `TimelineView` + `ApertureIrisView` bloom with the brand-kit-authored
/// Lottie animation (`splash-tile.json`) — the canonical motion the brand
/// owner designed for this moment. The tile variant carries the white iris
/// on the Aperture Blue gradient squircle, matching what the user just
/// tapped on the Home Screen so the splash feels like a continuation of
/// the launch image rather than a separate event.
///
/// **Rule #3 §B exception.** Lottie iOS (Airbnb, MIT) is added as a
/// project-wide SPM dependency in this same SHIPPED entry, joining
/// Trust Wallet Core. The user explicitly authorized it 2026-06-07
/// ("we've lottie splash screen why you don't add it!") for the new
/// Aperture brand kit which ships a dedicated Lottie subkit. Used only
/// at this call site (and any future surface that adopts the rest of
/// the Lottie kit — refresh / loading / sending / success / empty /
/// onboarding / error) via SwiftUI-native `LottieView`.
///
/// **Failure mode.** If the Lottie JSON fails to load (bundle path
/// missing, corrupt JSON, etc.), `LottieView` renders empty. We still
/// fire `onComplete` after `splashDuration` so the app doesn't sit on a
/// blank screen — the user reaches onboarding either way.
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

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()

            LottieView(animation: .named("splash-tile"))
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
