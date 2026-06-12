import Foundation
import SwiftData

/// Reads the active wallet's EVM and Solana addresses from SwiftData.
/// Owned as a singleton so the dApp router can resolve addresses
/// without threading the model context through every call.
///
/// The active wallet is identified by `@AppStorage("activeWalletId")`
/// — the same key the wallet home, switcher, and refresh coordinator
/// use. The reader looks up the matching `WalletRecord` lazily on
/// every call so a wallet switch propagates immediately.
@MainActor
final class ActiveWalletReader {
    static let shared = ActiveWalletReader()

    private init() {}

    /// The EVM address (Ethereum / Arbitrum / Base / etc.) of the
    /// active wallet, EIP-55 checksummed. `nil` when no wallet is
    /// active or the wallet has no EVM address derived.
    func currentEVMAddress() -> String? {
        guard let wallet = activeWallet() else { return nil }
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            if chain.family == .evm {
                return address.address
            }
        }
        return nil
    }

    /// The Solana address (base58) of the active wallet. `nil` when
    /// the wallet has no Solana account derived.
    func currentSolanaAddress() -> String? {
        guard let wallet = activeWallet() else { return nil }
        for address in wallet.addresses where address.chainRaw == SupportedChain.solana.rawValue {
            return address.address
        }
        return nil
    }

    /// The chain the dApp browser is currently scoped to. Defaults to
    /// Ethereum mainnet when nothing else is selected — matches what
    /// most dApps expect when they call `eth_chainId` for the first
    /// time. The user can switch via Settings (planned) or by
    /// triggering `wallet_switchEthereumChain` from the dApp.
    func currentEVMChain() -> SupportedChain? {
        // For now: always Ethereum. The browser-scoped chain selector
        // lands as part of the WalletConnect session-chain UI.
        .ethereum
    }

    // MARK: - Internals

    private func activeWallet() -> WalletRecord? {
        let activeId = UserDefaults.standard.string(forKey: "activeWalletId") ?? ""
        let modelContext = ModelContext(ApertureDatabase.shared.container)
        let descriptor = FetchDescriptor<WalletRecord>()
        guard let wallets = try? modelContext.fetch(descriptor) else { return nil }
        if !activeId.isEmpty,
           let match = wallets.first(where: { $0.id.uuidString == activeId }) {
            return match
        }
        return wallets.first
    }
}
