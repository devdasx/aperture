import SwiftUI

/// Beat 1 — Identity. Welcome to Aperture.
///
/// Renders the static `ApertureIrisView` — fully open, no rotation, no
/// motion. The iris IS the brand mark; on this slide it sits still, as
/// the identity beat. The animated bloom belongs to the cold-launch
/// `SplashView` (the "first breath" — only fires once per launch); slide 1
/// is a calm restatement of the identity, not a second performance of
/// the same motion. Ive restraint: one animation, one moment, earned.
///
/// `isActive` is accepted for API uniformity with the other illustration
/// views but is unused here — the iris does not change with active state.
struct WordmarkIllustration: View {
    let isActive: Bool

    var body: some View {
        ApertureIrisView(
            rc: ApertureIrisView.openValue,
            rot: 0
        )
        .frame(width: 112, height: 112)
    }
}
