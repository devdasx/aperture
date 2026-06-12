import SwiftUI
import SwiftData

/// "All supported assets" destination — the screen behind the
/// "Show all" rows in the wallet home's Coins and Tokens sections.
///
/// **Design intent (Rule #2 §D.1):** show the user every asset
/// Aperture supports — every native coin (26), every fungible token
/// from the curated registries — with their current balance against
/// the active wallet rendered honestly (zero is "0", never `—` and
/// never hidden). The user opens this surface to answer two
/// questions at once: "what does this app support?" and "what do I
/// hold of each?". One screen, both answers.
///
/// **Layout (Rule #15 §A).** Sheet-shaped destination pushed onto
/// the wallet-home `NavigationStack`. Inherits the parent nav bar
/// (no nested NavigationStack — M-004). Title rendered via
/// `.navigationTitle` so the system handles scroll-compression
/// behaviour. Two sections at root: **Coins** then **Tokens**,
/// matching the home screen's vocabulary.
///
/// **Search (Rule #14).** `.searchable(text:)` with no `placement:`
/// argument so iOS 26 owns the placement (bottom-floating Liquid
/// Glass on iPhone, top-trailing on iPad/Mac). Filter uses
/// `String.localizedStandardContains(_:)` against every
/// human-readable field: ticker, display name, and the chain name
/// for tokens.
///
/// **Honesty (Rule #16).** Zero-balance rows are rendered with `0`
/// and `Price unavailable` — never "Coming soon" (we already
/// support them) and never hidden (the user wants to see what's
/// possible). When the user holds a coin or token, the cached fiat
/// value joins the row.
///
/// **Rule #4.** Every color through `UniColors`. Every metric
/// through `UniSpacing` / `UniRadius` / `UniTypography`.
///
/// **Rule #7.** Coin marks come from bundled `Crypto/<ticker>`
/// assets (Trust Wallet provenance, already recorded in
/// `Assets.xcassets/README.md`). Token marks resolve through the
/// shared `CoinMark` view — bundled stablecoins (USDC, USDT) render
/// real; everything else falls back to an honest 3-letter initials
/// chip on `Material.card`. Never a fabricated brand mark.
struct AllSupportedAssetsView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    @State private var searchText: String = ""

    var body: some View {
        List {
            coinsSection
            tokensSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("All supported assets")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("Search"))
    }

    // MARK: - Sections

    /// Coins section — one row per `SupportedChain`. Sorted by the
    /// canonical chain order so the screen reads stable across
    /// renders.
    @ViewBuilder
    private var coinsSection: some View {
        let rows = filteredCoinRows
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.chain) { row in
                    NavigationLink(value: WalletHomeDestination.assetDetail(.nativeCoin(row.chain))) {
                        AssetRow(
                            chain: row.chain,
                            tokenSymbol: row.chain.ticker,
                            nativeAmount: row.amount,
                            nativeDecimals: min(row.chain.nativeDecimals, 8),
                            fiatValue: row.fiatValue,
                            fiatCurrencyCode: row.fiatCurrencyCode
                        )
                    }
                    .accessibilityLabel(Text("\(row.chain.displayName) details"))
                }
            } header: {
                Text("Coins")
            }
        }
    }

    /// Tokens section — one row per `(symbol, chain)` from the
    /// curated registries (`EVMTokenRegistry` ∪ `SolanaTokenRegistry`
    /// ∪ TRON ∪ NEAR ∪ Aptos ∪ Polkadot ∪ XRPL ∪ TON ∪ Kava). Each
    /// entry surfaces with its current balance for the active
    /// wallet (zero if not held).
    @ViewBuilder
    private var tokensSection: some View {
        let rows = filteredTokenRows
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.id) { row in
                    NavigationLink(value: WalletHomeDestination.assetDetail(.token(symbol: row.symbol))) {
                        TokenSupportedRow(row: row)
                    }
                    .accessibilityLabel(Text("\(row.symbol) details"))
                }
            } header: {
                Text("Tokens")
            }
        }
    }

    // MARK: - Row models
    //
    // These types were lifted from `private` to file-internal so the
    // main `WalletHomeView` can compose against the same shapes when
    // it enumerates ALL supported coins / tokens on the home screen
    // (with held-first, zero-balance-shown ordering). One canonical
    // row shape, two consumers.

    typealias CoinSupportedRow = WalletCoinSupportedRow
    typealias TokenSupportedDisplayRow = WalletTokenSupportedDisplayRow

    // MARK: - Active wallet + balance lookup

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    /// All `(chain, TokenBalanceRecord)` rows the active wallet has
    /// non-empty balances for. Same source the wallet home uses.
    private var heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        guard let wallet = activeWallet else { return [] }
        var result: [(SupportedChain, TokenBalanceRecord)] = []
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for balance in address.balances where !balance.rawBalance.isEmpty {
                result.append((chain, balance))
            }
        }
        return result
    }

    /// Look up the current native balance for a chain. Returns
    /// `nil` when the wallet has no record (so the row renders zero
    /// with `Price unavailable`).
    private func nativeBalance(for chain: SupportedChain) -> TokenBalanceRecord? {
        heldRows.first(where: { entry in
            entry.chain == chain
                && entry.balance.tokenContract == nil
                && entry.balance.tokenSymbol == chain.ticker
        })?.balance
    }

    /// Look up the current token balance for a `(chain, contract)`.
    /// Contracts are compared case-insensitively for EVM (per
    /// EIP-55 mixed case can vary by source) and verbatim for
    /// non-EVM (case-sensitive per `SUPPORTED_ASSETS.md` rule).
    private func tokenBalance(chain: SupportedChain, contract: String) -> TokenBalanceRecord? {
        heldRows.first(where: { entry in
            guard entry.chain == chain,
                  let storedContract = entry.balance.tokenContract else { return false }
            if chain.family == .evm {
                return storedContract.lowercased() == contract.lowercased()
            }
            return storedContract == contract
        })?.balance
    }

    // MARK: - Coins rows

    /// All Coins rows — one per `SupportedChain.allCases`. Renders
    /// the active wallet's native balance when present; honest zero
    /// otherwise.
    private var allCoinRows: [CoinSupportedRow] {
        SupportedChain.allCases.map { chain in
            if let record = nativeBalance(for: chain) {
                let amount = WalletFormatting.decimalAmount(
                    rawBalance: record.rawBalance,
                    decimals: record.decimals
                )
                return CoinSupportedRow(
                    chain: chain,
                    amount: amount,
                    fiatValue: record.fiatValueCached > 0 ? record.fiatValueCached : nil,
                    fiatCurrencyCode: record.fiatCurrencyCode
                )
            }
            return CoinSupportedRow(
                chain: chain,
                amount: .zero,
                fiatValue: nil,
                fiatCurrencyCode: currencyCode
            )
        }
    }

    /// Coins rows after applying the search filter. Matches the
    /// chain's display name, ticker, and asset family verbatim.
    private var filteredCoinRows: [CoinSupportedRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allCoinRows }
        return allCoinRows.filter { row in
            row.chain.displayName.localizedStandardContains(query)
                || row.chain.ticker.localizedStandardContains(query)
        }
    }

    // MARK: - Tokens rows

    /// All Tokens rows — one per `(symbol, chain, contract)` from
    /// the curated registries. Built by walking each chain family's
    /// registry once and emitting one display row per registry
    /// entry. The same `symbol` on multiple chains appears multiple
    /// times (USDC on Ethereum, USDC on Polygon, USDC on Solana, …)
    /// — that's the honest representation, because the same ticker
    /// on a different network is a different asset (different
    /// contract, different bridge, different cost).
    ///
    /// Sorted: held first (largest fiat desc), then unheld
    /// alphabetically by `(symbol, chain.displayName)`. So the user
    /// sees their actual holdings at the top, then can scroll
    /// through the full supported list.
    private var allTokenRows: [TokenSupportedDisplayRow] {
        var rows: [TokenSupportedDisplayRow] = []

        // EVM tokens — one entry per (chain, contract).
        for chain in SupportedChain.allCases where chain.family == .evm {
            for entry in EVMTokenRegistry.tokens(for: chain) {
                let balance = tokenBalance(chain: chain, contract: entry.contract)
                let amount = balance.map {
                    WalletFormatting.decimalAmount(
                        rawBalance: $0.rawBalance,
                        decimals: $0.decimals
                    )
                } ?? .zero
                rows.append(TokenSupportedDisplayRow(
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

        // Solana mints.
        for (mint, entry) in SolanaTokenRegistry.mints {
            let balance = tokenBalance(chain: .solana, contract: mint)
            let amount = balance.map {
                WalletFormatting.decimalAmount(
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals
                )
            } ?? .zero
            rows.append(TokenSupportedDisplayRow(
                id: "spl.\(mint)",
                chain: .solana,
                symbol: entry.symbol,
                name: entry.name,
                contract: mint,
                amount: amount,
                fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // TRON (TRC-20).
        for entry in TronTokenRegistry.tokens {
            let balance = tokenBalance(chain: .tron, contract: entry.contract)
            let amount = balance.map {
                WalletFormatting.decimalAmount(
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals
                )
            } ?? .zero
            rows.append(TokenSupportedDisplayRow(
                id: "trc.\(entry.contract)",
                chain: .tron,
                symbol: entry.symbol,
                name: entry.name,
                contract: entry.contract,
                amount: amount,
                fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // NEAR (NEP-141).
        for entry in NearTokenRegistry.tokens {
            let balance = tokenBalance(chain: .near, contract: entry.tokenAccount)
            let amount = balance.map {
                WalletFormatting.decimalAmount(
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals
                )
            } ?? .zero
            rows.append(TokenSupportedDisplayRow(
                id: "nep.\(entry.tokenAccount)",
                chain: .near,
                symbol: entry.symbol,
                name: entry.name,
                contract: entry.tokenAccount,
                amount: amount,
                fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // Aptos (fungible asset).
        for entry in AptosTokenRegistry.tokens {
            let balance = tokenBalance(chain: .aptos, contract: entry.contract)
            let amount = balance.map {
                WalletFormatting.decimalAmount(
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals
                )
            } ?? .zero
            rows.append(TokenSupportedDisplayRow(
                id: "apt.\(entry.contract)",
                chain: .aptos,
                symbol: entry.symbol,
                name: entry.name,
                contract: entry.contract,
                amount: amount,
                fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // Polkadot (Asset Hub).
        for entry in PolkadotAssetRegistry.tokens {
            let assetIdString = String(entry.assetId)
            let balance = tokenBalance(chain: .polkadot, contract: assetIdString)
            let amount = balance.map {
                WalletFormatting.decimalAmount(
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals
                )
            } ?? .zero
            rows.append(TokenSupportedDisplayRow(
                id: "dot.\(assetIdString)",
                chain: .polkadot,
                symbol: entry.symbol,
                name: entry.name,
                contract: assetIdString,
                amount: amount,
                fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // XRP Ledger (IOU).
        for entry in XRPLTokenRegistry.tokens {
            let contract = "\(entry.currency).\(entry.issuer)"
            let balance = tokenBalance(chain: .ripple, contract: contract)
            let amount = balance.map {
                WalletFormatting.decimalAmount(
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals
                )
            } ?? .zero
            rows.append(TokenSupportedDisplayRow(
                id: "xrpl.\(contract)",
                chain: .ripple,
                symbol: entry.symbol,
                name: entry.name,
                contract: contract,
                amount: amount,
                fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // TON Jettons.
        for entry in TONJettonRegistry.tokens {
            let balance = tokenBalance(chain: .ton, contract: entry.masterContract)
            let amount = balance.map {
                WalletFormatting.decimalAmount(
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals
                )
            } ?? .zero
            rows.append(TokenSupportedDisplayRow(
                id: "ton.\(entry.masterContract)",
                chain: .ton,
                symbol: entry.symbol,
                name: entry.name,
                contract: entry.masterContract,
                amount: amount,
                fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // Kava (Cosmos IBC).
        for entry in KavaCosmosTokenRegistry.tokens {
            let balance = tokenBalance(chain: .kava, contract: entry.denom)
            let amount = balance.map {
                WalletFormatting.decimalAmount(
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals
                )
            } ?? .zero
            rows.append(TokenSupportedDisplayRow(
                id: "kava.\(entry.denom)",
                chain: .kava,
                symbol: entry.symbol,
                name: entry.name,
                contract: entry.denom,
                amount: amount,
                fiatValue: (balance?.fiatValueCached).flatMap { $0 > 0 ? $0 : nil },
                fiatCurrencyCode: balance?.fiatCurrencyCode ?? currencyCode
            ))
        }

        // Sort: held (fiat > 0) first by fiat desc, then unheld
        // alphabetically by (symbol, chain). Stable, honest.
        return rows.sorted { a, b in
            let aHeld = (a.fiatValue ?? 0) > 0 || a.amount > 0
            let bHeld = (b.fiatValue ?? 0) > 0 || b.amount > 0
            if aHeld != bHeld { return aHeld && !bHeld }
            if aHeld && bHeld {
                return (a.fiatValue ?? 0) > (b.fiatValue ?? 0)
            }
            if a.symbol != b.symbol { return a.symbol < b.symbol }
            return a.chain.displayName < b.chain.displayName
        }
    }

    /// Token rows after applying the search filter. Matches symbol,
    /// full registry name, and the chain's display name (so
    /// searching "Polygon" surfaces every token on Polygon).
    private var filteredTokenRows: [TokenSupportedDisplayRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allTokenRows }
        return allTokenRows.filter { row in
            row.symbol.localizedStandardContains(query)
                || row.name.localizedStandardContains(query)
                || row.chain.displayName.localizedStandardContains(query)
        }
    }
}

// MARK: - TokenSupportedRow

/// One row in `AllSupportedAssetsView`'s Tokens section. Mirrors
/// `TokenHoldingRow`'s anatomy (44pt mark + ticker + chain + amount
/// + fiat) so the visual register stays consistent between the
/// home screen's "Tokens" section and the "Show all" destination.
///
/// **Why an internal type and not `TokenHoldingRow`.** The display
/// row's `name` field can be longer than the bare `tokenSymbol`
/// (e.g. "Wrapped Bitcoin" vs "WBTC"). Surfacing the name as the
/// title — with the symbol-on-chain as the subtitle — gives the
/// user the right "what is this thing?" answer on a discovery
/// screen. On the home screen they already know they hold it, so
/// the symbol leads. Same anatomy, different emphasis.
private struct TokenSupportedRow: View {
    let row: AllSupportedAssetsView.TokenSupportedDisplayRow

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(chain: row.chain, tokenSymbol: row.symbol, contract: row.contract)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: row.symbol)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text("\(row.name) · \(row.chain.displayName)")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(WalletFormatting.native(row.amount, decimals: 6))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                fiatLabel
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(row.symbol), \(row.name), on \(row.chain.displayName)"))
    }

    @ViewBuilder
    private var fiatLabel: some View {
        if let fiat = row.fiatValue, fiat > 0 {
            Text(WalletFormatting.fiat(fiat, currencyCode: row.fiatCurrencyCode))
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .monospacedDigit()
        } else {
            Text("Price unavailable")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }
}
