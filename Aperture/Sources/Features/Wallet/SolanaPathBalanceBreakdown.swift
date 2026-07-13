import Foundation

/// One path's native SOL balance for dual-path (Phantom + Trust) wallets.
/// Portfolio totals sum these; send/receive use only `isPreferred`.
struct SolanaPathBalanceLine: Identifiable, Sendable, Hashable {
    let style: SolanaPathStyle
    let address: String
    let amount: Decimal
    let fiatValue: Decimal?
    let fiatCurrencyCode: String
    let isPreferred: Bool

    var id: String { style.rawValue }
}

/// Pure helpers so home, asset detail, and send share one dual-path model.
enum SolanaPathBalanceBreakdown {

    /// Per-path native SOL lines for the wallet's Solana address rows.
    /// Returns one line per path style when addresses exist; missing balance → 0.
    static func nativeLines(
        addresses: [WalletAddressRecord],
        balances: [TokenBalanceRecord],
        fallbackCurrencyCode: String
    ) -> [SolanaPathBalanceLine] {
        let solanaAddresses = addresses.filter {
            $0.chainRaw == SupportedChain.solana.rawValue
        }
        guard !solanaAddresses.isEmpty else { return [] }

        var amountByAddressId: [UUID: (amount: Decimal, fiat: Decimal, code: String)] = [:]
        for bal in balances {
            guard bal.tokenContract == nil,
                  bal.tokenSymbol.uppercased() == SupportedChain.solana.ticker.uppercased(),
                  let addressId = bal.addressId ?? bal.address?.id else { continue }
            let amount = WalletFormatting.decimalAmount(
                rawBalance: bal.rawBalance,
                decimals: bal.decimals
            )
            var entry = amountByAddressId[addressId]
                ?? (amount: 0, fiat: 0, code: bal.fiatCurrencyCode)
            entry.amount += amount
            if bal.fiatValueCached > 0 {
                entry.fiat += bal.fiatValueCached
            }
            if entry.code.isEmpty {
                entry.code = bal.fiatCurrencyCode
            }
            amountByAddressId[addressId] = entry
        }

        // One line per path style (prefer the receive-preferred row when
        // multiple accounts share a style).
        var byStyle: [SolanaPathStyle: SolanaPathBalanceLine] = [:]
        for address in solanaAddresses {
            guard let style = SolanaPathStyle.parse(address.derivationPath)?.style else {
                continue
            }
            if let existing = byStyle[style], existing.isPreferred || !address.isReceivePreferred {
                continue
            }
            let bal = amountByAddressId[address.id]
            byStyle[style] = SolanaPathBalanceLine(
                style: style,
                address: address.address,
                amount: bal?.amount ?? 0,
                fiatValue: (bal?.fiat ?? 0) > 0 ? bal?.fiat : nil,
                fiatCurrencyCode: bal?.code.isEmpty == false
                    ? (bal?.code ?? fallbackCurrencyCode)
                    : fallbackCurrencyCode,
                isPreferred: address.isReceivePreferred
            )
        }

        return SolanaPathStyle.allCases.compactMap { byStyle[$0] }
    }

    /// True when the wallet has more than one Solana path style with a row.
    static func isDualPath(_ lines: [SolanaPathBalanceLine]) -> Bool {
        lines.count > 1
    }

    /// Compact home/holdings caption, e.g. `Phantom 1.2 · Trust 0.5`.
    /// `nil` when not dual-path (no need to label a single path).
    static func homeCaption(
        lines: [SolanaPathBalanceLine],
        hidden: Bool
    ) -> String? {
        guard isDualPath(lines) else { return nil }
        let parts = lines.map { line in
            let amount = WalletFormatting.native(line.amount, decimals: 4, hidden: hidden)
            return "\(line.style.title) \(amount)"
        }
        return parts.joined(separator: " · ")
    }

    /// Path style for a send/receive `fromAddress`, if known.
    static func style(
        forAddress address: String,
        walletAddresses: [WalletAddressRecord]
    ) -> SolanaPathStyle? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return walletAddresses
            .first { $0.chainRaw == SupportedChain.solana.rawValue && $0.address == trimmed }
            .flatMap { SolanaPathStyle.parse($0.derivationPath)?.style }
    }

    /// Address ids that should appear on home / portfolio / activity:
    /// every non-Solana address, plus only the **preferred** Solana path
    /// (Phantom by default; Trust when the user selects it in Receive).
    static func displayAddressIds(walletAddresses: [WalletAddressRecord]) -> Set<UUID> {
        var ids = Set<UUID>()
        let solanaRows = walletAddresses.filter { $0.chainRaw == SupportedChain.solana.rawValue }
        let preferredSolana = solanaRows.first(where: \.isReceivePreferred) ?? solanaRows.first
        for address in walletAddresses {
            if address.chainRaw == SupportedChain.solana.rawValue {
                if let preferredSolana, address.id == preferredSolana.id {
                    ids.insert(address.id)
                }
            } else {
                ids.insert(address.id)
            }
        }
        return ids
    }
}
