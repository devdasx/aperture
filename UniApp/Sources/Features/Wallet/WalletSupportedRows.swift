import Foundation
import SwiftData

/// Display shape for one Coins row across both consumers
/// (`WalletHomeView`'s home `coinsSection` AND
/// `AllSupportedAssetsView`'s "all supported" listing). Carries the
/// chain plus the current native amount + fiat value — `.zero`
/// amount + `nil` fiat is the honest representation for a coin the
/// user doesn't yet hold (per Rule #16: zero is "0", never `—`).
struct WalletCoinSupportedRow {
    let chain: SupportedChain
    let amount: Decimal
    let fiatValue: Decimal?
    let fiatCurrencyCode: String

    /// `true` if the user currently holds a non-zero balance of this
    /// coin. Used by the home screen to sort held coins ahead of
    /// not-held coins; the "all supported" screen ignores it (every
    /// row renders regardless).
    var isHeld: Bool { amount > 0 }
}

/// Display shape for one Tokens row across both consumers. Same
/// rationale as `WalletCoinSupportedRow`: the home screen and the
/// "all supported" screen share the row shape so the components and
/// builders are reusable.
struct WalletTokenSupportedDisplayRow: Identifiable {
    let id: String
    let chain: SupportedChain
    let symbol: String
    let name: String
    /// On-chain identifier (EVM contract / SPL mint / XRPL
    /// `currency.issuer` / TON master contract / etc.). Used by
    /// `CoinMark` to resolve a Trust Wallet logo via
    /// `CoinMarkCache.trustWalletURL(chain:contract:)`. Encoded as
    /// `String` because the source format differs per chain.
    let contract: String
    let amount: Decimal
    let fiatValue: Decimal?
    let fiatCurrencyCode: String

    /// `true` if the user currently holds a non-zero balance of this
    /// token. Sort key for home-screen held-first ordering.
    var isHeld: Bool { amount > 0 }
}

/// Pure-function builders that enumerate every supported coin /
/// token in Aperture's registries and pair each with the active
/// wallet's current balance (zero placeholder when not held). Used
/// by both `WalletHomeView` (capped at 10, held-first) and
/// `AllSupportedAssetsView` (uncapped, in canonical order).
///
/// **Honesty.** A registry entry that the user doesn't hold renders
/// as `amount: 0, fiatValue: nil`. The UI shows it as `0 / Price
/// unavailable` — never hidden, never "Coming soon" (we already
/// support it). The user opens the home screen and sees what
/// Aperture supports, with their actual balances mixed in.
enum WalletSupportedRowBuilders {

    /// All Coins rows — one per `SupportedChain.allCases`. The
    /// `heldRows` argument is the active wallet's held balances (the
    /// same source the existing `balances` computed in
    /// `WalletHomeView` consumes); we look up each chain's native
    /// balance from it.
    static func coinRows(
        heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)],
        currencyCode: String
    ) -> [WalletCoinSupportedRow] {
        // **2026-06-09 perf.** Index native balances by chain ONCE.
        // Previously each chain ran `heldRows.first { ... }` — 26
        // chains × 50 heldRows = 1300 comparisons per body render.
        // Now: one O(N) pass to build, then 26 O(1) lookups.
        var nativeIndex: [SupportedChain: TokenBalanceRecord] = [:]
        nativeIndex.reserveCapacity(SupportedChain.allCases.count)
        for entry in heldRows where entry.balance.tokenContract == nil
            && entry.balance.tokenSymbol == entry.chain.ticker {
            nativeIndex[entry.chain] = entry.balance
        }
        return SupportedChain.allCases.map { chain in
            if let record = nativeIndex[chain] {
                let amount = WalletFormatting.decimalAmount(
                    rawBalance: record.rawBalance,
                    decimals: record.decimals
                )
                return WalletCoinSupportedRow(
                    chain: chain,
                    amount: amount,
                    fiatValue: record.fiatValueCached > 0 ? record.fiatValueCached : nil,
                    fiatCurrencyCode: record.fiatCurrencyCode
                )
            }
            return WalletCoinSupportedRow(
                chain: chain,
                amount: .zero,
                fiatValue: nil,
                fiatCurrencyCode: currencyCode
            )
        }
    }

    /// All Tokens rows — every entry across the curated registries
    /// (`EVMTokenRegistry`, `SolanaTokenRegistry`, `TronTokenRegistry`,
    /// `NearTokenRegistry`, `AptosTokenRegistry`,
    /// `PolkadotTokenRegistry`, `XRPLTokenRegistry`,
    /// `TonTokenRegistry`, `KavaTokenRegistry`). Each entry pairs
    /// with the active wallet's current balance (or zero placeholder).
    static func tokenRows(
        heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)],
        currencyCode: String
    ) -> [WalletTokenSupportedDisplayRow] {
        // **2026-06-09 perf.** Build the (chain, contract) → balance
        // index ONCE up front, then every per-registry lookup below
        // is O(1) instead of O(N). For a wallet with ~50 held rows
        // and 9 registries totaling ~400 tokens, this trims ~20k
        // linear-scan comparisons per body render down to ~400 dict
        // lookups.
        let index = HeldRowIndex(heldRows)
        var rows: [WalletTokenSupportedDisplayRow] = []
        rows.reserveCapacity(400)

        // EVM tokens.
        for chain in SupportedChain.allCases where chain.family == .evm {
            for entry in EVMTokenRegistry.tokens(for: chain) {
                let balance = index.lookup(chain: chain, contract: entry.contract)
                let amount = balance.map {
                    WalletFormatting.decimalAmount(
                        rawBalance: $0.rawBalance,
                        decimals: $0.decimals
                    )
                } ?? .zero
                rows.append(WalletTokenSupportedDisplayRow(
                    id: "evm.\(chain.rawValue).\(entry.contract)",
                    chain: chain,
                    symbol: entry.symbol,
                    name: entry.name,
                    contract: entry.contract,
                    amount: amount,
                    fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                    fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
                ))
            }
        }

        // Solana SPL mints.
        for (mint, entry) in SolanaTokenRegistry.mints {
            let balance = index.lookup(chain: .solana, contract: mint)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "sol.\(mint)", chain: .solana,
                symbol: entry.symbol, name: entry.name, contract: mint, amount: decimalAmount(balance: balance),
                fiatValue: positiveFiat(balance),
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // TRON (TRC-20).
        for entry in TronTokenRegistry.tokens {
            let balance = index.lookup(chain: .tron, contract: entry.contract)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "trc.\(entry.contract)", chain: .tron,
                symbol: entry.symbol, name: entry.name, contract: entry.contract, amount: decimalAmount(balance: balance),
                fiatValue: positiveFiat(balance),
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // NEAR (NEP-141).
        for entry in NearTokenRegistry.tokens {
            let balance = index.lookup(chain: .near, contract: entry.tokenAccount)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "nep.\(entry.tokenAccount)", chain: .near,
                symbol: entry.symbol, name: entry.name, contract: entry.tokenAccount, amount: decimalAmount(balance: balance),
                fiatValue: positiveFiat(balance),
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // Aptos (fungible asset).
        for entry in AptosTokenRegistry.tokens {
            let balance = index.lookup(chain: .aptos, contract: entry.contract)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "apt.\(entry.contract)", chain: .aptos,
                symbol: entry.symbol, name: entry.name, contract: entry.contract, amount: decimalAmount(balance: balance),
                fiatValue: positiveFiat(balance),
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // Polkadot Asset Hub.
        for entry in PolkadotAssetRegistry.tokens {
            let assetIdString = String(entry.assetId)
            let balance = index.lookup(chain: .polkadot, contract: assetIdString)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "dot.\(assetIdString)", chain: .polkadot,
                symbol: entry.symbol, name: entry.name, contract: assetIdString, amount: decimalAmount(balance: balance),
                fiatValue: positiveFiat(balance),
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // XRPL IOUs — joined (currency, issuer) is the contract id.
        for entry in XRPLTokenRegistry.tokens {
            let contract = "\(entry.currency).\(entry.issuer)"
            let balance = index.lookup(chain: .ripple, contract: contract)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "xrpl.\(contract)", chain: .ripple,
                symbol: entry.symbol, name: entry.name, contract: contract, amount: decimalAmount(balance: balance),
                fiatValue: positiveFiat(balance),
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // TON Jettons.
        for entry in TONJettonRegistry.tokens {
            let balance = index.lookup(chain: .ton, contract: entry.masterContract)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "ton.\(entry.masterContract)", chain: .ton,
                symbol: entry.symbol, name: entry.name, contract: entry.masterContract, amount: decimalAmount(balance: balance),
                fiatValue: positiveFiat(balance),
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // Kava (Cosmos IBC).
        for entry in KavaCosmosTokenRegistry.tokens {
            let balance = index.lookup(chain: .kava, contract: entry.denom)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "kava.\(entry.denom)", chain: .kava,
                symbol: entry.symbol, name: entry.name, contract: entry.denom, amount: decimalAmount(balance: balance),
                fiatValue: positiveFiat(balance),
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        return rows
    }

    private static func decimalAmount(balance: TokenBalanceRecord?) -> Decimal {
        balance.map {
            WalletFormatting.decimalAmount(rawBalance: $0.rawBalance, decimals: $0.decimals)
        } ?? .zero
    }

    private static func positiveFiat(_ balance: TokenBalanceRecord?) -> Decimal? {
        (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil }
    }

    /// **2026-06-09 perf fix.** O(1) index keyed by `(chain, contract)`
    /// for token-balance lookup. Previously `tokenRows(...)` ran a
    /// linear `heldRows.first { ... }` scan for EVERY one of ~400
    /// registry tokens × ~50 held rows = ~20k operations per body
    /// re-render. The main screen body re-renders on every
    /// `@AppStorage` write (the filter sheet writes ~12 keys) and on
    /// every `@Query` snapshot; the linear scan was the dominant
    /// per-frame cost. Index build is O(N) once; lookup is O(1).
    fileprivate struct HeldRowIndex {
        // Key: "{chain.rawValue}|{contract.lowercased()}" (lowercased
        // matches EIP-55 mixed-case for EVM; harmless for
        // case-sensitive families since their contracts arrive
        // verbatim from on-chain so case is already canonical).
        // Value: the held balance record.
        private let storage: [String: TokenBalanceRecord]

        init(_ heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)]) {
            var dict: [String: TokenBalanceRecord] = [:]
            dict.reserveCapacity(heldRows.count)
            for entry in heldRows {
                guard let contract = entry.balance.tokenContract else { continue }
                let key = "\(entry.chain.rawValue)|\(contract.lowercased())"
                dict[key] = entry.balance
            }
            self.storage = dict
        }

        func lookup(chain: SupportedChain, contract: String) -> TokenBalanceRecord? {
            storage["\(chain.rawValue)|\(contract.lowercased())"]
        }
    }
}
