import SwiftUI

/// Placeholder destination for the Send action. The full Send flow
/// (recipient + amount + fee + confirm + sign + broadcast) lands in a
/// later turn — gated behind real per-chain key derivation
/// (T-024..T-031) and per-chain broadcast endpoints. For v1 the
/// surface is a calm "Coming next" copy so the affordance is
/// reachable but honest about what it does today.
struct SendPlaceholderView: View {
    var body: some View {
        ComingNextSurface(
            systemImage: "arrow.up.right.circle",
            title: "Send",
            message: "Send is coming next. Aperture will broadcast transactions directly to the chain — no servers in the middle."
        )
        .navigationTitle("Send")
        .navigationBarTitleDisplayMode(.inline)
    }
}
