import SwiftUI

/// **Receive screen v2 — asset-first bottom sheet.**
///
/// Replaces the v1 push-to-chain-chip-picker screen with an asset-list
/// sheet that mirrors the pattern Trust Wallet / Phantom / Rainbow
/// ship: "what are you receiving?" first, "on which network?" second
/// (for tokens), QR + address + warning third.
///
/// **Design intent (Rule #2 §D.1):** ask the user the question they
/// actually have ("what do I want to receive?") before the question
/// they don't ("which of 24 networks am I on?"). For native coins the
/// network IS the asset, so one tap lands them on the QR. For tokens,
/// a second tap names the network — and the chain-mismatch footer at
/// the QR step names BOTH the token and the network, so the sender
/// has the full instruction.
///
/// **Layers (Rule #2 §B.3):** content layer — opaque list rows on the
/// step-1 root, opaque list rows on the network-picker step, opaque
/// QR card + opaque address row on the QR step. Functional layer —
/// the sheet's drag indicator + the system nav bar + the QR step's
/// `.glassProminent` share button. Two glass layers max.
///
/// **Navigation contract (per the prompt):**
/// - Step 1 → close sheet (swipe-down + system close).
/// - Step 2 → back chevron pops to Step 1 (same `NavigationStack`).
/// - Step 3 (from Step 2) → back chevron pops to Step 2.
/// - Step 3 (direct from Step 1, native) → back chevron pops to
///   Step 1.
///
/// The destination enum is `Hashable, Codable` so the parent's
/// `NavigationPath` can be persisted across Rule #12 §G direction
/// rebuilds.
struct ReceiveView: View {
    @StateObject private var walletRecordsObservation = WalletRecordsObservation()
    @StateObject private var assetCatalogObservation = AssetCatalogObservation()
    @StateObject private var activeBalancesObservation = ActiveWalletBalancesObservation()
    @StateObject private var activeTransactionsObservation = ActiveWalletTransactionsObservation()
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    /// The sheet's own NavigationPath. Lives on the sheet root so the
    /// sheet can rebuild via `.id(sheetDirectionKey)` without losing
    /// the user's position when the path is value-encoded.
    @Binding var navigationPath: NavigationPath

    /// Asset seed handed in by a caller that already knows what the
    /// user intends to receive. Native coins go straight to QR; tokens
    /// with one network go straight to QR; multi-network tokens open
    /// the native Receive network picker with the token already chosen.
    var assetPrefill: AssetPrefill? = nil

    @State private var didSeedAssetPrefill: Bool = false

    /// Whether the "Add custom token" sheet is presented. The Receive
    /// options menu opens this — the active wallet's currently available
    /// chains preselect the most likely target (the first EVM chain we
    /// find, else Solana).
    @State private var isShowingAddCustomToken: Bool = false

    /// The chain the user tapped that has no derived address on the
    /// active wallet. Non-nil drives the honest "no address" alert —
    /// a silent return would read as a dead tap.
    @State private var missingAddressChain: SupportedChain?
    @State private var isShowingMissingAddressAlert: Bool = false

    /// Real holdings snapshot (balances + per-(chain,symbol) tx counts),
    /// rebuilt off the render path when balances change (Rule #28). Drives
    /// the balance display + the high→low sort in both pickers — shared
    /// with the Send flow so the two are identical.
    @State private var holdings: AssetPickerHoldings = .empty

    private var currencyCode: String {
        AppPreferenceStore.shared.string(CurrencyPreference.storageKey, default: CurrencyPreference.defaultCode)
    }

    private var allWallets: [WalletRecord] {
        walletRecordsObservation.wallets
    }

    private var customTokenRecords: [CustomTokenRecord] {
        assetCatalogObservation.customTokenRecords.sorted {
            $0.symbol.localizedStandardCompare($1.symbol) == .orderedAscending
        }
    }

    private var assetRecords: [AssetRecord] {
        assetCatalogObservation.assetRecords
    }

    private var holdingsKey: String {
        guard let wallet = activeWallet else { return "none" }
        return [
            wallet.id.uuidString,
            activeBalancesObservation.revision,
            activeTransactionsObservation.revision
        ].joined(separator: "|")
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ReceiveAssetListView(
                availableChains: availableChains,
                holdings: holdings,
                currencyCode: currencyCode,
                customTokenRecords: customTokenRecords,
                assetRecords: assetRecords,
                onSelectNative: { chain in
                    openNative(chain)
                },
                onSelectToken: { asset in
                    openToken(asset)
                },
                onAddCustomToken: {
                    isShowingAddCustomToken = true
                }
            )
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            navigationPath.append(ReceiveDestination.customTokens)
                        } label: {
                            Label("Custom tokens", systemImage: "tag")
                        }

                        Button {
                            isShowingAddCustomToken = true
                        } label: {
                            Label("Add custom token", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .regular))
                            .accessibilityLabel(Text("More"))
                    }
                }
            }
            .sheet(isPresented: $isShowingAddCustomToken) {
                AddCustomTokenSheet(
                    initialChain: firstSupportedCustomTokenChain,
                    availableChains: availableChains,
                    onSaved: {}
                )
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationBackground(UniColors.Background.primary)
            }
            .navigationDestination(for: ReceiveDestination.self) { destination in
                switch destination {
                case let .networkPicker(asset):
                    ReceiveNetworkPickerView(
                        token: asset,
                        holdings: holdings,
                        currencyCode: currencyCode,
                        onSelectNetwork: { chain in
                            let symbol: String? = {
                                if case let .token(symbol, _, _) = asset { return symbol }
                                return nil
                            }()
                            openNetwork(chain, tokenSymbol: symbol)
                        }
                    )
                case let .qr(chain, tokenSymbol, address):
                    ReceiveQRDetailView(
                        chain: chain,
                        tokenSymbol: tokenSymbol,
                        address: address
                    )
                case .customTokens:
                    CustomTokensListView(initialChainForAdd: firstSupportedCustomTokenChain)
                }
            }
        }
        .onChange(of: activeWalletIdRaw) { _, _ in
            // The user switched wallets via the switcher sheet under
            // us. Reset to step 1 so we don't show an address that
            // came from the prior wallet.
            navigationPath = NavigationPath()
        }
        .task(id: activeWalletHealKey) {
            healActiveWalletIdIfNeeded()
        }
        .task(id: activeWalletScopeKey) {
            syncObservationScopes()
        }
        .task(id: holdingsKey) {
            holdings = AssetPickerHoldings(
                wallet: activeWallet,
                balances: activeBalancesObservation.balances,
                transactions: activeTransactionsObservation.transactions
            )
        }
        .task(id: prefillSeedKey) {
            seedAssetPrefillIfNeeded()
        }
        .alert(
            Text("No address for this network"),
            isPresented: $isShowingMissingAddressAlert,
            presenting: missingAddressChain
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { chain in
            Text("This wallet has no \(chain.displayName) address yet, so there's nothing to receive to on this network. Aperture may still be deriving your accounts — try again in a moment.")
        }
    }

    // MARK: - Derived

    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(rawID: activeWalletIdRaw, wallets: allWallets)
    }

    /// Re-runs the self-heal whenever the stored id or the wallet
    /// set changes (e.g. the active wallet was deleted mid-session).
    private var activeWalletHealKey: String {
        "\(activeWalletIdRaw)|\(allWallets.count)"
    }

    private var activeWalletScopeKey: String {
        "\(activeWalletIdRaw)|\(walletRecordsObservation.revision)"
    }

    private func syncObservationScopes() {
        let scopedWalletId = activeWallet?.id ?? UUID(uuidString: activeWalletIdRaw)
        activeBalancesObservation.setWalletId(scopedWalletId)
        activeTransactionsObservation.setWalletId(scopedWalletId)
    }

    private var prefillSeedKey: String {
        [
            activeWalletIdRaw,
            availableChains.map(\.rawValue).joined(separator: ","),
            "\(assetRecords.count)",
            "\(customTokenRecords.count)",
            assetPrefill.map { "asset:\($0.symbol):\($0.nativeChain?.rawValue ?? "token")" } ?? "asset:nil",
            "\(didSeedAssetPrefill)"
        ].joined(separator: "|")
    }

    /// **Empty-id self-heal.** When the stored active-wallet id is
    /// empty or malformed and wallets exist, write the first wallet's
    /// id back to the preference. A valid UUID that has not merged into
    /// this view yet is left untouched so another wallet's data is never
    /// shown as a fallback. Runs from `.task(id:)`, never during body.
    private func healActiveWalletIdIfNeeded() {
        guard let first = allWallets.first else { return }
        if ActiveWalletResolver.shouldHeal(rawID: activeWalletIdRaw, wallets: allWallets) {
            ActiveWalletPointer.set(first.id)
        }
    }

    /// All chains the active wallet has a derived (non-empty) address
    /// for, sorted by the canonical `SupportedChain` ordering.
    private var availableChains: [SupportedChain] {
        guard let wallet = activeWallet else { return [] }
        let chains: [SupportedChain] = wallet.addresses.compactMap { record in
            guard !record.address.isEmpty else { return nil }
            return SupportedChain(rawValue: record.chainRaw)
        }
        let set = Set(chains)
        return SupportedChain.allCases.filter { set.contains($0) }
    }

    private func address(for chain: SupportedChain) -> String? {
        guard let wallet = activeWallet else { return nil }
        let rows = wallet.addresses.filter {
            $0.chainRaw == chain.rawValue && !$0.address.isEmpty
        }
        return rows.first(where: \.isReceivePreferred)?.address ?? rows.first?.address
    }

    private func seedAssetPrefillIfNeeded() {
        guard navigationPath.isEmpty,
              !didSeedAssetPrefill,
              let assetPrefill else { return }

        if let chain = assetPrefill.nativeChain {
            didSeedAssetPrefill = true
            openNative(chain)
            return
        }

        guard let token = matchingToken(for: assetPrefill) else { return }
        didSeedAssetPrefill = true
        openToken(token)
    }

    private func matchingToken(for prefill: AssetPrefill) -> ReceiveAsset? {
        let symbol = prefill.symbol.uppercased()
        return ReceiveAsset.tokens(
            availableChains: Set(availableChains),
            customTokens: customTokenRecords.map { CustomTokenSnapshot(from: $0) },
            catalogAssets: catalogAssets
        )
        .first { asset in
            guard case let .token(tokenSymbol, _, _) = asset else { return false }
            return tokenSymbol.uppercased() == symbol
        }
    }

    private var catalogAssets: [CatalogAsset] {
        let seededAssets = AssetCatalog.assets(from: assetRecords)
        return seededAssets.isEmpty ? AssetCatalog.allAssets : seededAssets
    }

    private func openNative(_ chain: SupportedChain) {
        openNetwork(chain, tokenSymbol: nil)
    }

    private func openToken(_ asset: ReceiveAsset) {
        guard case let .token(symbol, _, chains) = asset else { return }
        if chains.count == 1, let chain = chains.first {
            openNetwork(chain, tokenSymbol: symbol)
        } else {
            navigationPath.append(ReceiveDestination.networkPicker(asset))
        }
    }

    private func openNetwork(_ chain: SupportedChain, tokenSymbol: String?) {
        guard let address = address(for: chain) else {
            missingAddressChain = chain
            isShowingMissingAddressAlert = true
            return
        }
        navigationPath.append(
            ReceiveDestination.qr(chain: chain, tokenSymbol: tokenSymbol, address: address)
        )
    }

    /// First supported chain for the Add Custom Token sheet's
    /// initial selection. Picks the first EVM chain the user has an
    /// address on (Ethereum is most likely), else Solana, else TRON, else
    /// `.ethereum` as a backstop — the sheet's picker lets the user
    /// override regardless.
    private var firstSupportedCustomTokenChain: SupportedChain {
        CustomTokenSupport.preferredInitialChain(availableChains: availableChains)
    }

    struct AssetPrefill: Equatable {
        let symbol: String
        let name: String
        let nativeChain: SupportedChain?

        init(symbol: String, name: String, nativeChain: SupportedChain? = nil) {
            self.symbol = symbol.uppercased()
            self.name = name
            self.nativeChain = nativeChain
        }
    }
}

// MARK: - Destinations

/// Step transitions inside the Receive sheet. Hashable + Codable so
/// the NavigationPath can persist across direction-flip rebuilds.
enum ReceiveDestination: Hashable, Codable {
    case networkPicker(ReceiveAsset)
    case qr(chain: SupportedChain, tokenSymbol: String?, address: String)
    case customTokens
}

// MARK: - Codable for ReceiveAsset

extension ReceiveAsset: Codable {
    private enum Kind: String, Codable {
        case native, token
    }

    private enum CodingKeys: String, CodingKey {
        case kind, chain, symbol, name, chains
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .native:
            let chain = try container.decode(SupportedChain.self, forKey: .chain)
            self = .native(chain)
        case .token:
            let symbol = try container.decode(String.self, forKey: .symbol)
            let name = try container.decode(String.self, forKey: .name)
            let chains = try container.decode([SupportedChain].self, forKey: .chains)
            self = .token(symbol: symbol, name: name, chains: chains)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .native(chain):
            try container.encode(Kind.native, forKey: .kind)
            try container.encode(chain, forKey: .chain)
        case let .token(symbol, name, chains):
            try container.encode(Kind.token, forKey: .kind)
            try container.encode(symbol, forKey: .symbol)
            try container.encode(name, forKey: .name)
            try container.encode(chains, forKey: .chains)
        }
    }
}
