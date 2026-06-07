import SwiftUI
import UIKit

/// Single row in the three review screens (`MnemonicReviewView`,
/// `PrivateKeyReviewView`, `WatchOnlyReviewView`). Renders the chain
/// logo (Trust Wallet bundled per M-001), the chain name + truncated
/// address, and the per-chain balance result in the user's currency.
///
/// **Honesty (Rule #2 §A.7 + Rule #16).** When the address starts with
/// `StubKeyImportService.stubAddressPrefix` the row knows the
/// derivation hasn't shipped for that chain yet (Bitcoin / EVM /
/// Cosmos / TRON / Sui / Stellar / Aptos / TON / Polkadot — every
/// chain that needs secp256k1 / SHA-3 / BLAKE2b / StrKey / SCALE).
/// Instead of pretending to show an address + balance, the row
/// renders a quiet "Derivation pending" surface so the user can never
/// confuse a placeholder for a real on-chain account.
///
/// Real-derivation chains today (Solana, NEAR) render the truncated
/// address and the real RPC-fetched balance.
///
/// `balance` is optional: nil while the scan is in flight (renders a
/// `ProgressView` in the trailing slot), present once the scanner
/// returns. When the address is "used" (has on-chain transaction
/// history) a quiet 6pt green dot appears inline before the trailing
/// numeric column. Absence of the dot IS the "fresh" signal —
/// subtractive design (Rule #2 §A.2).
struct ReviewChainRow: View {
    let chain: SupportedChain
    let address: String
    let balance: ChainBalance?

    private var isStubAddress: Bool {
        address.hasPrefix(StubKeyImportService.stubAddressPrefix)
    }

    private var displayAddress: String {
        guard isStubAddress else { return address }
        return String(address.dropFirst(StubKeyImportService.stubAddressPrefix.count))
    }

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            chainLogo
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: chain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                if isStubAddress {
                    Text("Derivation pending")
                        .font(UniTypography.caption2)
                        .foregroundStyle(UniColors.Text.tertiary)
                } else {
                    Text(verbatim: shortened(displayAddress))
                        .font(UniTypography.caption2.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
            Spacer(minLength: UniSpacing.s)
            trailingColumn
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    // MARK: - Leading column

    @ViewBuilder
    private var chainLogo: some View {
        if let assetName = chain.logoAssetName,
           UIImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .opacity(isStubAddress ? 0.55 : 1)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle.dashed")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(UniColors.Icon.tertiary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Trailing column (balance + used dot)

    @ViewBuilder
    private var trailingColumn: some View {
        if isStubAddress {
            // Stub address. The honest surface here is a quiet em-dash;
            // no fake balance, no fake fiat. The row footer ("Derivation
            // pending" in the leading column) names the cause.
            Text(verbatim: "—")
                .font(UniTypography.callout)
                .foregroundStyle(UniColors.Text.tertiary)
        } else if let balance {
            HStack(alignment: .center, spacing: UniSpacing.xs) {
                if balance.isUsed {
                    usedDot
                }
                VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                    Text(verbatim: BalanceFormatter.native(balance.nativeBalance, chain: chain))
                        .font(UniTypography.callout.monospacedDigit())
                        .foregroundStyle(UniColors.Text.primary)
                    if let fiat = balance.fiatBalance {
                        // Price IS available — render the converted
                        // amount even when it rounds to the currency
                        // zero (a $0.00 row is still honest data, not
                        // a missing-price condition).
                        Text(verbatim: BalanceFormatter.fiat(fiat, currencyCode: balance.fiatCurrencyCode))
                            .font(UniTypography.caption1.monospacedDigit())
                            .foregroundStyle(UniColors.Text.tertiary)
                    } else {
                        // Price genuinely missing (Coinbase nil +
                        // stablecoin proxy nil + FX nil). Rule #16 §A.6
                        // honesty surface.
                        Text("Price unavailable")
                            .font(UniTypography.caption1)
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(UniColors.Icon.tertiary)
        }
    }

    private var usedDot: some View {
        Circle()
            .fill(UniColors.Status.successForeground)
            .frame(width: 6, height: 6)
            .accessibilityLabel(Text("Active address — has on-chain history"))
    }

    // MARK: - Helper

    private func shortened(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))…\(address.suffix(6))"
    }
}
