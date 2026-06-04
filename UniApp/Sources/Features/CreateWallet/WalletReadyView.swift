import SwiftUI

/// Terminal placeholder for the create-wallet flow, pushed onto the
/// cover's `NavigationStack` after `BackupVerifyView` succeeds.
///
/// **Intent (one sentence):** quietly acknowledge that the wallet exists
/// and hand the user back to the app, without theatre.
///
/// **Why a placeholder.** The real wallet home (`T-018`) is deferred. The
/// alternative — silently dismissing the cover after verification —
/// would leave the user without any signal that the flow had completed.
/// One calm screen with a checkmark, two sentences, and a Done button
/// is the smallest honest reading of "done".
///
/// **No back navigation.** The verify step is final — once the user has
/// proven the phrase, they should land on the next surface, not be
/// able to wander back into a generation step. The system back button
/// is suppressed via `.navigationBarBackButtonHidden(true)`.
struct WalletReadyView: View {
    /// Fires when the user taps Done. The caller dismisses the
    /// `fullScreenCover` and clears the unbacked-up flag.
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 96, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Status.successForeground)
                .accessibilityHidden(true)

            VStack(spacing: UniSpacing.s) {
                UniLargeTitle(
                    text: "Your wallet is ready.",
                    alignment: .center
                )
                UniBody(
                    text: "Your recovery phrase is saved. You can find your wallet on the main screen.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
            }
            .padding(.horizontal, UniSpacing.l)

            Spacer()
        }
        .safeAreaInset(edge: .bottom) {
            actionRegion
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(title: "Done", variant: .primary) {
                onDone()
            }
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        WalletReadyView(onDone: {})
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        WalletReadyView(onDone: {})
    }
    .preferredColorScheme(.dark)
}
