import SwiftUI

/// Beat 10 — Start when you're ready.
///
/// Renders Apple's `arrow.right.circle.fill` SF Symbol — the quietest beat
/// of the ten. The arrow points forward; the circle says "here, tap here".
/// The two CTAs below carry the weight; the visual only points the way.
///
/// One native `.symbolEffect(.bounce)` when this beat becomes active.
struct ThresholdIllustration: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: "arrow.right.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .frame(width: 112, height: 112)
            .foregroundStyle(UniColors.Brand.mark)
            .symbolEffect(.bounce, options: .nonRepeating, value: isActive)
    }
}
