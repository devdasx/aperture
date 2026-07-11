import SwiftUI

/// Presented when the user taps the leading X close button on
/// `PinSetupFlow`. Distinct from the skip-passcode confirmation: that
/// dialog asks "skip the PIN but keep the wallet"; this one asks "stop the
/// whole wallet creation and go back to onboarding".
///
/// **Sheet shape.** Uses the unified `UniSheet` shell.
struct AbandonWalletWarningSheet: View {
    let onContinueSetup: () -> Void
    let onAbandon: () -> Void

    var body: some View {
        UniSheet(
            title: "Stop creating your wallet?",
            icon: "xmark.octagon",
            iconTint: UniColors.Feedback.Warning.foreground
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                copyBlock
                footnoteLine
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Continue setup", variant: .primary) {
                        onContinueSetup()
                    }
                    UniButton(title: "Stop and go back", variant: .destructive) {
                        onAbandon()
                    }
                }
            }
        }
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniHeadline(
                text: "If you stop now, your new wallet won't be saved.",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "The recovery phrase you just saw will be discarded. You'll need to start the creation process again if you change your mind.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnoteLine: some View {
        UniFootnote(
            text: "You can create a new wallet anytime.",
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AbandonWalletWarningSheet(onContinueSetup: {}, onAbandon: {})
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AbandonWalletWarningSheet(onContinueSetup: {}, onAbandon: {})
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.dark)
}
