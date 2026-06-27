import SwiftUI
import SwiftData

/// Receive flow for callers that already know the asset has one network.
///
/// This is intentionally not the network picker with one row. It opens the
/// QR/address screen as the sheet root, so single-network coins and tokens
/// do not ask the user to choose a network they cannot actually vary.
struct ReceiveSingleNetworkView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    @Binding var navigationPath: NavigationPath

    let assetPrefill: ReceiveView.AssetPrefill
    let chain: SupportedChain

    var body: some View {
        NavigationStack(path: $navigationPath) {
            if let address = address(for: chain) {
                ReceiveQRDetailView(
                    chain: chain,
                    tokenSymbol: tokenSymbol,
                    address: address
                )
            } else {
                unavailableView
            }
        }
        .onChange(of: activeWalletIdRaw) { _, _ in
            navigationPath = NavigationPath()
        }
        .task(id: activeWalletHealKey) {
            healActiveWalletIdIfNeeded()
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView(
            "No address available",
            systemImage: "network.slash",
            description: Text("This wallet does not have a receive address for \(assetPrefill.symbol) on \(chain.displayName).")
        )
        .background(UniColors.Background.primary)
        .navigationTitle(Text(assetPrefill.symbol))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tokenSymbol: String? {
        assetPrefill.nativeChain == nil ? assetPrefill.symbol : nil
    }

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    private var activeWalletHealKey: String {
        "\(activeWalletIdRaw)|\(allWallets.count)"
    }

    private func address(for chain: SupportedChain) -> String? {
        guard let wallet = activeWallet else { return nil }
        return wallet.addresses.first(where: {
            $0.chainRaw == chain.rawValue && !$0.address.isEmpty
        })?.address
    }

    private func healActiveWalletIdIfNeeded() {
        guard let first = allWallets.first else { return }
        let resolves = UUID(uuidString: activeWalletIdRaw)
            .map { id in allWallets.contains(where: { $0.id == id }) } ?? false
        if !resolves {
            activeWalletIdRaw = first.id.uuidString
        }
    }
}
