import SwiftUI

/// Read-only reveal of a wallet's **per-chain private keys** — EVM hex keys,
/// Bitcoin-family WIF, the Solana base58 secret, and the raw key for every
/// other network the wallet holds. The multi-chain counterpart of
/// `PrivateKeyRevealSheet`: same chrome, same honesty register, same
/// caller-side biometric gate (`WalletDetailView.viewChainKeysRow`).
///
/// Keys are derived on a background task via `PrivateKeyExport` (which routes
/// through `SigningKeyProvider.withPrivateKey`'s scoped closure — the same
/// derivation the signer uses), so every key matches the wallet's address for
/// that chain. Display-only — no text selection, so a key can't silently land
/// on the pasteboard (matching the phrase / single-key reveals).
struct ChainKeysRevealSheet: View {
    let descriptor: WalletDescriptor
    let chains: [ChainEntry]
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [PrivateKeyExport.Row] = []
    @State private var loaded = false

    /// One chain the wallet holds + its address, passed in from the caller
    /// (which already has the `WalletRecord`) so the sheet needs no DB access.
    struct ChainEntry: Sendable, Hashable {
        let chain: SupportedChain
        let address: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    hero
                    if !loaded {
                        UniLoadingState(caption: "Deriving your keys…")
                            .padding(.vertical, UniSpacing.xxl)
                    } else {
                        ForEach(rows) { row in keyCard(row) }
                        warningCard
                    }
                }
                .padding(UniSpacing.l)
                .frame(maxWidth: .infinity)
            }
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text("Private keys"))
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
        .task { await load() }
        // Drop the plaintext keys from view state the moment the sheet goes
        // away — no reason to keep them resident longer than the reveal.
        .onDisappear { rows = [] }
    }

    private var hero: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .accessibilityHidden(true)
            UniHeadline(
                text: "Your private keys, per network.",
                alignment: .center
            )
            UniBody(
                text: "Anyone with a key can take the funds on its address. Aperture cannot undo a leak.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
    }

    private func keyCard(_ row: PrivateKeyExport.Row) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack(spacing: UniSpacing.xs) {
                Text(row.chain.displayName)
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer(minLength: UniSpacing.xs)
                Text(verbatim: row.format)
                    .font(UniTypography.caption2)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(UniColors.Background.tertiary))
            }
            if let value = row.value {
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Display-only — a key must not silently reach the
                    // pasteboard (matches `PrivateKeyRevealSheet`).
                    .textSelection(.disabled)
                    // Rule #11 Part C — a key has a strict character order;
                    // pin LTR on the readout subtree only.
                    .environment(\.layoutDirection, .leftToRight)
            } else {
                Text("Unavailable on this device.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Material.card)
        )
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Label {
                Text("Stored on this iPhone — keep your own copy")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(UniColors.Status.warningForeground)
            }
            Text("These keys are derived from your wallet's secret, encrypted in this iPhone's Keychain — they never leave this device. Each key controls the funds on its address. Never share one, and never type it into a site or app you don't fully trust.")
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

    /// Off-main key derivation (Rule #28): the per-chain PBKDF2 + key
    /// derivation runs on a background task so presenting the sheet never
    /// blocks; the rows land back on the main actor after the await.
    private func load() async {
        let desc = descriptor
        let entries = chains.map { (chain: $0.chain, address: $0.address) }
        let derived = await Task.detached(priority: .userInitiated) {
            PrivateKeyExport.exportAll(wallet: desc, chains: entries)
        }.value
        rows = derived
        loaded = true
    }
}
