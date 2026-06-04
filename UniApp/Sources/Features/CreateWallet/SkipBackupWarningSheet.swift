import SwiftUI

/// Presented over `RecoveryPhraseView` when the user taps "Skip for now".
/// The user can skip — that is their right — but we tell them honestly
/// what they are about to walk out with.
///
/// **Intent (one sentence):** persuade without trapping. The user keeps
/// the choice; we make sure the consequence is named before they make it.
///
/// **Sheet shape (Rule #15).** A `NavigationStack` wraps the content; the
/// title lives in `.navigationTitle("Skip backup?")` with
/// `.navigationBarTitleDisplayMode(.inline)` for the `.medium` detent.
/// The body keeps the longer sentence ("Save your recovery phrase before
/// you skip.") as a `UniHeadline` inside the content — the nav-bar title
/// is the framing question, the headline is the answer. No `ScrollView`:
/// one paragraph, one footnote, two CTAs — fits the medium detent.
///
/// **Layout.** `exclamationmark.shield.fill` hero in
/// `UniColors.Status.warningForeground` at a modest 48-pt size. Not
/// alarming, not flashing red — just the honest weight of "you are about
/// to step out without a safety net."
struct SkipBackupWarningSheet: View {
    /// Fires when the user changes their mind and taps "Back up now".
    /// The caller dismisses this sheet; the user stays on the recovery
    /// phrase view.
    let onBackUpNow: () -> Void
    /// Fires when the user confirms the skip. The caller dismisses this
    /// sheet *and* the parent recovery-phrase cover, returning the user
    /// to onboarding (with the unbacked-up wallet flagged in storage).
    let onSkipAnyway: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                copyBlock
                footnoteLine
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .safeAreaInset(edge: .bottom) {
                actionRegion
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.bottom, UniSpacing.l)
            }
            .navigationTitle("Skip backup?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Hero

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

    // MARK: - Copy

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniHeadline(
                text: "Save your recovery phrase before you skip.",
                alignment: .leading
            )
            UniBody(
                text: "Your wallet is on this iPhone only. If your iPhone is lost, broken, or wiped, your wallet — and everything in it — is gone. The recovery phrase is the only way back.",
                color: UniColors.Text.secondary
            )
        }
    }

    private var footnoteLine: some View {
        UniFootnote(
            text: "You can back it up later in Settings.",
            alignment: .leading
        )
    }

    // MARK: - Actions

    /// Two CTAs in one `GlassEffectContainer` — high-stakes commit moment,
    /// the bigger buttons earn their place (Rule #15 allows the bottom
    /// `GlassEffectContainer` exception for high-stakes commits over the
    /// toolbar pattern).
    private var actionRegion: some View {
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

// MARK: - Previews

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            SkipBackupWarningSheet(onBackUpNow: {}, onSkipAnyway: {})
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            SkipBackupWarningSheet(onBackUpNow: {}, onSkipAnyway: {})
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}
