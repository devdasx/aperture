import SwiftUI

/// Aperture's launch splash — the brand's first breath.
///
/// Renders the iris diaphragm at the center of a full-bleed background and
/// runs the canonical splash motion (closed → bloom open with overshoot →
/// hold → fade) for ``ApertureMotion/splashDuration`` seconds, then calls
/// ``onComplete`` so the app root can swap to onboarding.
///
/// The motion is driven by ``TimelineView`` with `.animation` schedule — the
/// system supplies a frame tick at the display's refresh rate, we compute
/// the iris frame from elapsed time, and the `Canvas` inside
/// ``ApertureIrisView`` redraws each frame. No explicit `withAnimation`, no
/// `@State` shadowing per-frame values — the timeline IS the animation.
///
/// Per Rule #2 / Rule #3: zero third-party packages, no Lottie, no SVG
/// runtime. The iris is rendered live from native SwiftUI geometry.
struct SplashView: View {
    /// Called once the full splash animation has completed (i.e., at
    /// `ApertureMotion.splashDuration`). The parent uses this to dismiss
    /// the splash and present the first onboarding beat.
    let onComplete: () -> Void

    /// Captured at view creation. Every `TimelineView` tick computes
    /// `elapsed = context.date - start`, so the animation phase doesn't
    /// drift across re-renders.
    @State private var start: Date = .init()

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()

            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                let frame = ApertureMotion.splash(at: elapsed)

                ApertureIrisView(rc: frame.rc, rot: frame.rot)
                    .frame(width: 160, height: 160)
                    .opacity(frame.opacity)
                    .scaleEffect(frame.scale)
            }
        }
        .accessibilityLabel(Text("Aperture"))
        .onAppear {
            start = Date() // re-anchor in case the view was rebuilt
            DispatchQueue.main.asyncAfter(deadline: .now() + ApertureMotion.splashDuration) {
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
