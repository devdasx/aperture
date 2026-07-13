import Foundation

/// Ephemeral BIP-39 passphrase cache for the current app session.
///
/// The passphrase is **never** written to GRDB / Keychain / backups (schema
/// contract). Create/import already derive with the real passphrase in memory.
/// After unlock, send, or receive path switch, we keep it only in RAM so
/// background refresh can provision dual Solana paths (Phantom + Trust)
/// without deriving empty-passphrase addresses for passphrase wallets.
///
/// Cleared on auto-lock and factory reset paths.
actor BIP39PassphraseSession {
    static let shared = BIP39PassphraseSession()

    private var byWalletId: [UUID: String] = [:]

    /// Remember a passphrase after the user entered it for this wallet.
    func remember(walletId: UUID, passphrase: String) {
        byWalletId[walletId] = passphrase
    }

    /// Session passphrase when the user has already entered it this session.
    func passphrase(for walletId: UUID) -> String? {
        byWalletId[walletId]
    }

    func forget(walletId: UUID) {
        byWalletId.removeValue(forKey: walletId)
    }

    func forgetAll() {
        byWalletId.removeAll()
    }
}
