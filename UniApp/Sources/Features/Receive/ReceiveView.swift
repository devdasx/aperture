import SwiftUI
import SwiftData

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
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    /// The sheet's own NavigationPath. Lives on the sheet root so the
    /// sheet can rebuild via `.id(sheetDirectionKey)` without losing
    /// the user's position when the path is value-encoded.
    @Binding var navigationPath: NavigationPath

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ReceiveAssetListView(
                availableChains: availableChains,
                onSelectNative: { chain in
                    guard let address = address(for: chain) else { return }
                    navigationPath.append(
                        ReceiveDestination.qr(chain: chain, tokenSymbol: nil, address: address)
                    )
                },
                onSelectToken: { asset in
                    navigationPath.append(ReceiveDestination.networkPicker(asset))
                }
            )
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ReceiveDestination.self) { destination in
                switch destination {
                case let .networkPicker(asset):
                    ReceiveNetworkPickerView(
                        token: asset,
                        onSelectNetwork: { chain in
                            guard let address = address(for: chain) else { return }
                            let symbol: String? = {
                                if case let .token(symbol, _, _) = asset { return symbol }
                                return nil
                            }()
                            navigationPath.append(
                                ReceiveDestination.qr(chain: chain, tokenSymbol: symbol, address: address)
                            )
                        }
                    )
                case let .qr(chain, tokenSymbol, address):
                    ReceiveQRDetailView(
                        chain: chain,
                        tokenSymbol: tokenSymbol,
                        address: address
                    )
                }
            }
        }
        .onChange(of: activeWalletIdRaw) { _, _ in
            // The user switched wallets via the switcher sheet under
            // us. Reset to step 1 so we don't show an address that
            // came from the prior wallet.
            navigationPath = NavigationPath()
        }
    }

    // MARK: - Derived

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
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
        return wallet.addresses.first(where: {
            $0.chainRaw == chain.rawValue && !$0.address.isEmpty
        })?.address
    }
}

// MARK: - Destinations

/// Step transitions inside the Receive sheet. Hashable + Codable so
/// the NavigationPath can persist across direction-flip rebuilds.
enum ReceiveDestination: Hashable, Codable {
    case networkPicker(ReceiveAsset)
    case qr(chain: SupportedChain, tokenSymbol: String?, address: String)
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
