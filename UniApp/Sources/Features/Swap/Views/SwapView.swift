import SwiftUI
import SwiftData

/// **Swap / Bridge — the compose + quote sheet.** The entry point the
/// wallet-home Swap action presents. Owns the `SwapComposeModel`, reads the
/// active wallet's holdings + from/to balances from the local store
/// (Rule #27, off the render path per Rule #28), drives the token/chain
/// picker sheets, and pushes the honest Review summary.
///
/// **Staged like Send.** Same-chain SWAP and cross-chain BRIDGE are both
/// real here: the engine returns live Li.Fi / Jupiter quotes. Execution
/// (sign + broadcast) is the NEXT increment — Review is an honest summary,
/// never a fabricated swap (mirrors how Send was staged before signing).
///
/// **Defaults to what the user can actually swap.** The FROM side seeds to
/// the wallet's highest-value swappable holding; the TO side opens empty,
/// inviting the pick. If the wallet has no swappable holdings, FROM falls
/// back to the native coin of the first swappable chain it has an address on.
struct SwapView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    /// The sheet's own NavigationPath (Rule #12 §G — lives on the root so a
    /// direction-flip rebuild doesn't lose the user's position).
    @Binding var navigationPath: NavigationPath

    @Environment(\.dismiss) private var dismiss

    @State private var model: SwapComposeModel?
    /// Which picker is open (nil = none). Drives the single picker sheet.
    @State private var activePicker: SwapTokenPickerSheet.Side?
    /// Real holdings snapshot, rebuilt off the render path (Rule #28).
    @State private var holdings: AssetPickerHoldings = .empty

    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    private var currencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let model {
                    SwapComposeView(
                        model: model,
                        isLiFiConfigured: SwapQuoteService.shared.isLiFiConfigured,
                        swappableChains: swappableChains,
                        holdings: holdings,
                        onRequestPicker: { side in activePicker = side },
                        onReview: { summary in
                            navigationPath.append(SwapDestination.review(summary))
                        }
                    )
                } else {
                    // The wallet has no swappable holdings or address — honest,
                    // not a dead screen.
                    SwapUnavailableView()
                }
            }
            .navigationDestination(for: SwapDestination.self) { destination in
                switch destination {
                case let .review(summary):
                    SwapReviewView(
                        summary: summary,
                        currencyCode: currencyCode,
                        onClose: { dismiss() }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: holdingsKey) {
            holdings = AssetPickerHoldings(wallet: activeWallet)
            buildModelIfNeeded()
            resolveBalancesAndPrice()
        }
        .onChange(of: activeWalletIdRaw) { _, _ in
            navigationPath = NavigationPath()
            model = nil
        }
        // Stop the background quote auto-refresh when the user leaves the
        // compose screen (Rule #28 — no leaked network/battery work). Pause
        // while on Review (path non-empty); re-arm on return; cancel on
        // sheet teardown.
        .onChange(of: navigationPath.isEmpty) { _, isEmpty in
            if isEmpty { model?.requestQuote() } else { model?.cancel() }
        }
        .onDisappear { model?.cancel() }
        .sheet(item: $activePicker) { side in
            SwapTokenPickerSheet(
                side: side,
                swappableChains: swappableChains,
                holdings: holdings,
                onPick: { token in applyPick(side: side, token: token) }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Model lifecycle

    /// Build the model once, seeded with the default FROM token. Re-runs
    /// after a wallet switch resets `model` to nil.
    private func buildModelIfNeeded() {
        guard model == nil, let from = defaultFromToken else { return }
        model = SwapComposeModel(fromToken: from, currencyCode: currencyCode)
        // Seed the from-address + balances immediately so the first quote
        // can fire as soon as the user picks a to-token + amount.
    }

    /// Apply a picked token to its side, then resolve that side's address +
    /// balance + price off the render path. The model's `didSet` re-requests
    /// the quote.
    private func applyPick(side: SwapTokenPickerSheet.Side, token: SwapToken) {
        guard let model else { return }
        switch side {
        case .from:
            model.fromToken = token
        case .to:
            model.toToken = token
        }
        resolveBalancesAndPrice()
    }

    // MARK: - Local-first reads (off the render path, Rule #27/#28)

    /// Resolve the from-address (signing side), the from/to balances, the
    /// bridge receiver address, and the from-unit price.
    private func resolveBalancesAndPrice() {
        guard let model else { return }
        // From side.
        let from = model.fromToken
        model.fromAddress = address(for: from.chain) ?? ""
        model.fromBalance = balance(of: from)
        // To side.
        if let to = model.toToken {
            model.toBalance = balance(of: to)
            // Cross-chain bridge → the receiver is the wallet's own address
            // on the destination chain (when it has one).
            model.toAddress = from.chain == to.chain ? nil : address(for: to.chain)
        } else {
            model.toBalance = nil
            model.toAddress = nil
        }
        // Re-quote now that the from/to ADDRESSES are resolved — a picked
        // to-token fired the quote on its `didSet` BEFORE `toAddress` was
        // set, so the just-set receiver (esp. for a cross-family bridge)
        // must drive a fresh quote. The model debounces, so this coalesces
        // with the didSet's request rather than double-firing.
        model.requestQuote()
        // From-unit price (display-only fiat conversion).
        Task { [weak modelRef = model] in
            let symbol = from.symbol.uppercased()
            let prices = await TokenPricingEngine.shared.unitPrices(
                symbols: [symbol], currencyCode: currencyCode.uppercased()
            )
            await MainActor.run { modelRef?.fromUnitPrice = prices[symbol]?.amount }
        }
    }

    /// Balance of a `SwapToken` in chain units, from the active wallet's
    /// store rows. Native = the chain's native row; token = the matching
    /// contract/symbol row on that chain.
    private func balance(of token: SwapToken) -> Decimal {
        guard let wallet = activeWallet else { return 0 }
        var total: Decimal = 0
        let symbolUpper = token.symbol.uppercased()
        for address in wallet.addresses where address.chainRaw == token.chain.rawValue {
            for bal in address.balances {
                let amount = WalletFormatting.decimalAmount(rawBalance: bal.rawBalance, decimals: bal.decimals)
                if token.isNative {
                    if bal.tokenContract == nil && bal.tokenSymbol.uppercased() == token.chain.ticker.uppercased() {
                        total += amount
                    }
                } else if bal.tokenContract != nil && bal.tokenSymbol.uppercased() == symbolUpper {
                    total += amount
                }
            }
        }
        return total
    }

    // MARK: - Default FROM token (highest-value swappable holding)

    /// The wallet's highest-value swappable holding, as a `SwapToken`. Falls
    /// back to the native coin of the first swappable chain the wallet has an
    /// address on. `nil` when the wallet can't swap anything.
    private var defaultFromToken: SwapToken? {
        // Prefer a held swappable asset by fiat value, native first as the
        // common case. We only have symbol/chain in holdings, so we map the
        // top native holding on a swappable chain to its `SwapToken`.
        let swappable = swappableChains
        // 1. Native coin of the swappable chain the wallet holds the most on.
        let sortedNatives = AssetPickerSort.natives(
            swappable.filter { hasAddress(for: $0) }, holdings: holdings
        )
        if let topChain = sortedNatives.first, let native = SwapChainMap.nativeToken(for: topChain) {
            return native
        }
        // 2. Any swappable chain with an address.
        if let anyChain = swappable.first(where: { hasAddress(for: $0) }),
           let native = SwapChainMap.nativeToken(for: anyChain) {
            return native
        }
        // 3. Nothing usable.
        return nil
    }

    private var swappableChains: [SupportedChain] {
        SwapQuoteService.shared.swappableChains
    }

    // MARK: - Wallet plumbing (mirrors SendView)

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) { return match }
        return allWallets.first
    }

    private var holdingsKey: String {
        guard let wallet = activeWallet else { return "none" }
        var rows = 0
        var newest = Date.distantPast
        for address in wallet.addresses {
            rows += address.balances.count
            for bal in address.balances where bal.updatedAt > newest { newest = bal.updatedAt }
        }
        return "\(wallet.id.uuidString)|\(rows)|\(newest.timeIntervalSince1970)"
    }

    private func address(for chain: SupportedChain) -> String? {
        guard let wallet = activeWallet else { return nil }
        return wallet.addresses.first(where: {
            $0.chainRaw == chain.rawValue && !$0.address.isEmpty
        })?.address
    }

    private func hasAddress(for chain: SupportedChain) -> Bool {
        address(for: chain) != nil
    }
}

// MARK: - Destinations

/// Step transitions inside the Swap sheet. `Hashable` + `Codable` so the
/// `NavigationPath` survives Rule #12 §G direction-flip rebuilds.
enum SwapDestination: Hashable, Codable {
    case review(SwapReviewSummary)
}

// MARK: - Picker side as a sheet item

extension SwapTokenPickerSheet.Side: Identifiable {
    public var id: String {
        switch self {
        case .from: return "from"
        case .to: return "to"
        }
    }
}

// MARK: - Unavailable state

/// Honest state when the wallet has nothing swappable (no address on any
/// swappable chain). Not a dead screen — names why and what to do.
private struct SwapUnavailableView: View {
    var body: some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 64, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Icon.secondary)
                .accessibilityHidden(true)
            VStack(spacing: UniSpacing.s) {
                UniTitle2(text: "Nothing to swap yet", alignment: .center)
                UniBody(
                    text: "This wallet has no balance on a network Aperture can swap on yet. Receive some crypto on Ethereum, Base, Solana, or another supported network to get started.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
            }
            .padding(.horizontal, UniSpacing.l)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UniColors.Background.primary)
        .navigationTitle("Swap")
        .navigationBarTitleDisplayMode(.inline)
    }
}
