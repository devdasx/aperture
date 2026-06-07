import SwiftUI

/// Read-only reveal of a stored recovery phrase for unbacked wallets.
/// Reads from `MnemonicVault.loadMnemonic(for:)`; the caller is
/// responsible for gating presentation behind biometric/PIN auth
/// (see `WalletDetailView.viewPhraseRow`).
///
/// **What it does** — shows the phrase in a 2-column numbered grid
/// (mirrors `RecoveryPhraseView`'s layout), with a "Back up now"
/// `UniButton(.primary)` that pushes the verify flow against this
/// specific wallet (T-046). When the user completes verification the
/// `MnemonicVault` entry is deleted and this surface becomes
/// unavailable for the wallet — exactly the contract documented in
/// `WalletDetailView.phraseFooter`.
///
/// **Honesty (Rule #16):** the screen says plainly that this is
/// Aperture's last opportunity to show the phrase — once backup
/// completes the phrase is the user's only copy.
struct RecoveryPhraseRevealSheet: View {
    let walletId: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var words: [String] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    hero
                    if let loadError {
                        UniBody(
                            text: LocalizedStringKey(loadError),
                            alignment: .center,
                            color: UniColors.Status.errorForeground
                        )
                    } else if words.isEmpty {
                        ProgressView()
                            .padding(.vertical, UniSpacing.xxl)
                    } else {
                        phraseGrid
                        warningCard
                    }
                }
                .padding(UniSpacing.l)
                .frame(maxWidth: .infinity)
            }
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text("Recovery phrase"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
        .onAppear { load() }
    }

    private var hero: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .accessibilityHidden(true)
            UniHeadline(
                text: "Write these words down in order.",
                alignment: .center
            )
            UniBody(
                text: "Anyone with this phrase can take your funds. Aperture cannot recover it for you.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
    }

    private var phraseGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: UniSpacing.s, alignment: .leading),
            GridItem(.flexible(), spacing: UniSpacing.s, alignment: .leading)
        ]
        return LazyVGrid(columns: columns, spacing: UniSpacing.xs) {
            ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                wordCell(index: idx + 1, word: word)
            }
        }
    }

    private func wordCell(index: Int, word: String) -> some View {
        HStack(spacing: UniSpacing.xs) {
            Text(String(format: "%02d", index))
                .font(.system(size: 13, weight: .regular, design: .rounded).monospacedDigit())
                .foregroundStyle(UniColors.Text.tertiary)
                .frame(width: 26, alignment: .leading)
            Text(word)
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(UniColors.Text.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.s)
        .padding(.vertical, UniSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                .fill(UniColors.Material.card)
        )
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Label {
                Text("Stored locally until you back up")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(UniColors.Status.warningForeground)
            }
            Text("This phrase is encrypted on this iPhone right now. Once you confirm you've written it down, the local copy will be deleted and you become the only copy. Back up the moment you can.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                .fill(UniColors.Status.warningBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                .stroke(UniColors.Status.warningStroke, lineWidth: 1)
        )
    }

    private func load() {
        do {
            words = try MnemonicVault.loadMnemonic(for: walletId) ?? []
            if words.isEmpty {
                loadError = String.apertureLocalized("No phrase is stored for this wallet.")
            }
        } catch {
            loadError = String.apertureLocalized("Could not decrypt the phrase. Try restarting Aperture.")
        }
    }
}
