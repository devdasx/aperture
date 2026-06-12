import SwiftUI

/// Read-only reveal of a stored recovery phrase (created and
/// phrase-import wallets — the vault stores the phrase at persist time
/// for both). Reads from `MnemonicVault.loadMnemonic(for:)`; the
/// caller is responsible for gating presentation behind biometric/PIN
/// auth (see `WalletDetailView.viewPhraseRow`).
///
/// **What it does** — shows the phrase in a 2-column numbered grid
/// (mirrors `RecoveryPhraseView`'s layout) with an honest storage note
/// underneath. The vault entry persists for the wallet's lifetime —
/// it's removed only by wallet deletion / Reset Aperture, matching
/// `WalletDetailView.secretFooter`'s promise that the phrase is
/// viewable anytime.
///
/// **Honesty (Rule #16):** the screen states the real custody facts —
/// anyone with the phrase can take the funds, the encrypted copy never
/// leaves this iPhone, and a written copy is still the user's only
/// recourse if this iPhone is lost.
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
        // Drop the plaintext words from view state the moment the
        // sheet goes away — no reason to keep the phrase resident in
        // memory longer than the reveal itself.
        .onDisappear { words = [] }
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
        // Rule #11 Part C — display-only English content. BIP-39
        // words have a strict ordinal reading order the user
        // transcribes; in an RTL locale the grid would silently flip
        // (word 1 top-right, word 2 top-left) and the phrase would be
        // written down in the wrong order. Force LTR on the grid
        // subtree only — the chrome around it stays ambient.
        .environment(\.layoutDirection, .leftToRight)
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
                Text("Stored on this iPhone — keep a written copy")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(UniColors.Status.warningForeground)
            }
            Text("This phrase is encrypted in your iPhone's Keychain and never leaves this device. If you lose this iPhone and have no written copy, the funds are gone — write it down and keep it somewhere safe.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Private-key reveal

/// Read-only reveal of the original private-key string an imported-key
/// wallet was created from (hex or WIF, exactly as the user typed it).
/// The key-import counterpart of `RecoveryPhraseRevealSheet` — same
/// chrome, same honesty register, same caller-side biometric gate
/// (`WalletDetailView.viewKeyRow`). Reads from
/// `MnemonicVault.loadPrivateKey(for:)`; the entry persists for the
/// wallet's lifetime and is removed only by wallet deletion / Reset
/// Aperture.
struct PrivateKeyRevealSheet: View {
    let walletId: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var keyString: String = ""
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
                    } else if keyString.isEmpty {
                        ProgressView()
                            .padding(.vertical, UniSpacing.xxl)
                    } else {
                        keyCard
                        storageCard
                    }
                }
                .padding(UniSpacing.l)
                .frame(maxWidth: .infinity)
            }
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text("Private key"))
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
        // Drop the plaintext key from view state the moment the sheet
        // goes away — no reason to keep it resident in memory longer
        // than the reveal itself (mirrors the phrase sheet).
        .onDisappear { keyString = "" }
    }

    private var hero: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .accessibilityHidden(true)
            UniHeadline(
                text: "Never share this key.",
                alignment: .center
            )
            UniBody(
                text: "Anyone with this key can take the funds on its address. Aperture cannot undo a leak.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
    }

    private var keyCard: some View {
        // Display-only, like the phrase grid — no text selection, so
        // the key can't silently land on the pasteboard (where other
        // apps and Universal Clipboard could read it).
        Text(keyString)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundStyle(UniColors.Text.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UniSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Material.card)
            )
            // Rule #11 Part C — display-only English content. A hex /
            // WIF key has a strict character order the user transcribes;
            // force LTR on the readout subtree only — the chrome around
            // it stays ambient.
            .environment(\.layoutDirection, .leftToRight)
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Label {
                Text("Stored on this iPhone — keep your own copy")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(UniColors.Status.warningForeground)
            }
            Text("This key is encrypted in your iPhone's Keychain and never leaves this device. If you lose this iPhone and have no other copy, the funds are gone — keep your own record somewhere safe.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    }

    private func load() {
        do {
            keyString = try MnemonicVault.loadPrivateKey(for: walletId) ?? ""
            if keyString.isEmpty {
                loadError = String.apertureLocalized("No key is stored for this wallet.")
            }
        } catch {
            loadError = String.apertureLocalized("Could not decrypt the key. Try restarting Aperture.")
        }
    }
}
