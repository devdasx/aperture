import SwiftUI

/// Inline warning row at the top of the wallet-home scroll when the
/// active wallet's `requiresBackup` flag is `true` (set when the user
/// chose the skip-backup branch during create).
///
/// **Visual register (Rule #16 §B):** warning, not error. Hero glyph
/// in `Status.warningForeground`; copy is restrained ("Save your
/// recovery phrase to protect your funds."); single CTA. NOT alarming
/// red — that's reserved for failures, not pending actions.
///
/// **Honesty (Rule #2 §A.7):** the consequence is stated once,
/// plainly. The user already saw the long-form warning at skip time;
/// here we name the situation and offer the path back, no theatre.
struct BackupRequiredBanner: View {
    let onBackUpNow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Status.warningForeground)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text("Save your recovery phrase.")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If you lose your iPhone before backing up, your wallet is gone — there is no recovery without the phrase.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
                .accessibilityHidden(true)
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Status.warningBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .stroke(UniColors.Status.warningStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onBackUpNow() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Back up your recovery phrase"))
        .accessibilityHint(Text("Opens the backup flow to save your phrase."))
    }
}
