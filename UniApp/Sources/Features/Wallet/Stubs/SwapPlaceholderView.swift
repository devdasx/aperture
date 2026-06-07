import SwiftUI

/// Placeholder destination for the Swap action. The full Swap flow
/// (token-in → token-out → quote → confirm → sign + broadcast) lands
/// in a later turn. Aperture's swap will use on-chain DEX aggregators
/// (or chain-native DEXes) rather than a centralized swap server —
/// matching the "no servers" posture in Rule #16.
struct SwapPlaceholderView: View {
    var body: some View {
        ComingNextSurface(
            systemImage: "arrow.left.arrow.right.circle",
            title: "Swap",
            message: "Swap is coming next. Aperture will route swaps through on-chain DEX aggregators — no centralized swap server in the middle."
        )
        .navigationTitle("Swap")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared placeholder surface

/// Calm, restrained "Coming next" surface used by Send / Receive /
/// Swap placeholders. Hero SF Symbol + title + body paragraph +
/// nothing else. Defined here (rather than in a third stub file) so
/// the three stubs can share without scattering.
struct ComingNextSurface: View {
    let systemImage: String
    let title: LocalizedStringKey
    /// Body copy — named `message` rather than `body` to avoid a
    /// name clash with SwiftUI's `View.body` requirement.
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()

            Image(systemName: systemImage)
                .font(.system(size: 72, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Icon.secondary)
                .accessibilityHidden(true)

            VStack(spacing: UniSpacing.s) {
                UniLargeTitle(text: title, alignment: .center)
                UniBody(
                    text: message,
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
            }
            .padding(.horizontal, UniSpacing.l)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UniColors.Background.primary.ignoresSafeArea())
    }
}
