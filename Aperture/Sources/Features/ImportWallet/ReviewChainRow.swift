import SwiftUI
import UIKit

/// Single row in the private-key and watch-only review screens. Renders the chain
/// logo (Trust Wallet bundled per M-001), the chain name + truncated
/// address, and the per-chain balance result in the user's currency.
///
/// **P3-014 / BUG-024.** Production never emits the historical `[STUB]`
/// prefix (`WalletCoreKeyImportService`). This row still filters that
/// prefix as defense-in-depth against old test data / corrupted DB rows
/// so a placeholder can never look like a real on-chain account.
///
/// `balance` is optional: nil while the scan is in flight (renders a
/// `ProgressView` in the trailing slot), present once the scanner
/// returns. When the address is "used" (has on-chain transaction
/// history) a quiet 6pt green dot appears inline before the trailing
/// numeric column. Absence of the dot IS the "fresh" signal —
/// subtractive design (Rule #2 §A.2).
struct ReviewChainRow: View {
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    let chain: SupportedChain
    let address: String
    let balance: ChainBalance?

    private var isStubAddress: Bool {
        address.hasPrefix(KeyImportFormatDetector.stubAddressPrefix)
    }

    private var displayAddress: String {
        guard isStubAddress else { return address }
        return String(address.dropFirst(KeyImportFormatDetector.stubAddressPrefix.count))
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
        CoinMark(chain: chain, tokenSymbol: chain.ticker)
            .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
            .opacity(isStubAddress ? 0.55 : 1)
            .accessibilityHidden(true)
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
                    Text(verbatim: hideBalances ? "\(WalletFormatting.hiddenAmount) \(chain.ticker)" : BalanceFormatter.native(balance.nativeBalance, chain: chain))
                        .font(UniTypography.callout.monospacedDigit())
                        .foregroundStyle(UniColors.Text.primary)
                    // Render the fiat value, defaulting an unknown price to
                    // zero → "US$0.00", never "Price unavailable" (user
                    // direction 2026-06-18). A $0.00 row is honest data; the
                    // value refines as the price batch resolves.
                    Text(verbatim: WalletFormatting.fiat(balance.fiatBalance ?? 0, currencyCode: balance.fiatCurrencyCode, hidden: hideBalances))
                        .font(UniTypography.caption1.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
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
            .fill(UniColors.Feedback.Success.foreground)
            .frame(width: 6, height: 6)
            .accessibilityLabel(Text("Active address — has on-chain history"))
    }

    // MARK: - Helper

    private func shortened(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))…\(address.suffix(6))"
    }
}
