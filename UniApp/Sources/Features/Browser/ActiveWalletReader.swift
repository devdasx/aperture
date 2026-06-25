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

    /// The EVM address for a specific EVM chain of the active wallet,
    /// EIP-55 checksummed. `nil` when no wallet is active, the chain is
    /// not EVM, or the wallet has no address derived for that chain.
    func currentEVMAddress(chain: SupportedChain) -> String? {
        guard chain.family == .evm,
              let wallet = activeWallet() else { return nil }
        let chainRaw = chain.rawValue
        return wallet.addresses.first(where: { $0.chainRaw == chainRaw })?.address
    }

    /// Legacy default for callers that have not selected an EVM chain yet.
    /// Prefer `currentEVMAddress(chain:)` anywhere a chain is known.
    func currentEVMAddress() -> String? {
        currentEVMAddress(chain: .ethereum)
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
        // Targeted fetch (2026-06-17): a predicate + `fetchLimit 1` for
        // the active id, falling back to a `fetchLimit 1` fetch. The old
        // unbounded `fetch(FetchDescriptor())` materialized EVERY wallet
        // on the main thread on every dApp address lookup — wasteful and
        // a UI-hitch source. Matches `EVMDAppSigner.activeWallet()`.
        if let activeUUID = UUID(uuidString: activeId) {
            var descriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == activeUUID }
            )
            descriptor.fetchLimit = 1
            if let match = (try? modelContext.fetch(descriptor))?.first {
                return match
            }
        }
        var fallback = FetchDescriptor<WalletRecord>()
        fallback.fetchLimit = 1
        return (try? modelContext.fetch(fallback))?.first
    }
}
