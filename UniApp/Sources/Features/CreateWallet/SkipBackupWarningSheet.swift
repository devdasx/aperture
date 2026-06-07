import SwiftUI

/// Presented over `RecoveryPhraseView` when the user taps "Skip for now".
/// The user can skip — that is their right — but we tell them honestly
/// what they are about to walk out with.
///
/// **Intent (one sentence):** persuade without trapping. The user keeps
/// the choice; we make sure the consequence is named before they make it.
///
/// **Sheet shape.** Uses the unified `UniSheet` shell — same pattern as
/// every other sheet in the app. Bare VStack-rooted so the
/// `.intrinsicHeightSheet()` modifier can measure correctly and the
/// sheet sizes to its content exactly.
struct SkipBackupWarningSheet: View {
    let onBackUpNow: () -> Void
    let onSkipAnyway: () -> Void

    var body: some View {
        UniSheet(title: "Skip backup?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                copyBlock
                footnoteLine
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Back up now", variant: .primary) {
                        onBackUpNow()
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
                text: "Save your recovery phrase before you skip.",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "Your wallet is on this iPhone only. If your iPhone is lost, broken, or wiped, your wallet — and everything in it — is gone. The recovery phrase is the only way back.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnoteLine: some View {
        UniFootnote(
            text: "You can back it up later in Settings.",
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            SkipBackupWarningSheet(onBackUpNow: {}, onSkipAnyway: {})
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            SkipBackupWarningSheet(onBackUpNow: {}, onSkipAnyway: {})
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.dark)
}
