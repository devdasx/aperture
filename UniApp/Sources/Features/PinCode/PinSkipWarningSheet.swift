import SwiftUI

/// Presented over `PinSetupFlow` when the user taps Skip / Close. The PIN
/// is optional per `CLAUDE.md` Rule #17 — but the consequence is named
/// honestly before the user walks out without one.
///
/// **Sheet shape.** Uses the unified `UniSheet` shell.
struct PinSkipWarningSheet: View {
    let onSetPin: () -> Void
    let onSkipAnyway: () -> Void

    var body: some View {
        UniSheet(title: "Skip passcode setup?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                copyBlock
                footnoteLine
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Set a passcode", variant: .primary) {
                        onSetPin()
                    }
                    UniButton(title: "Skip anyway", variant: .secondary) {
                        onSkipAnyway()
                    }
                }
            }
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Status.warningForeground)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniHeadline(
                text: "Without a passcode, your wallet is only protected by your iPhone's lock screen.",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "If your iPhone is unlocked, anyone with it can use your wallet. A PIN adds a second check before sending crypto or seeing your recovery phrase.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnoteLine: some View {
        UniFootnote(
            text: "You can enable a passcode anytime in Settings.",
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PinSkipWarningSheet(onSetPin: {}, onSkipAnyway: {})
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PinSkipWarningSheet(onSetPin: {}, onSkipAnyway: {})
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.dark)
}
