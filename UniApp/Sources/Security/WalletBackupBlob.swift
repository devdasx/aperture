import Foundation

/// The encrypted backup envelope that is stored in iCloud and read back on
/// restore (2026-06-19 backup handoff). Designed so the restore screen can
/// **list** a user's backups and let them pick one *before* they enter the
/// password — so a small amount of non-secret metadata (name, creation
/// date, word count) is stored in clear. The recovery phrase itself is the
/// only true secret and is always `ciphertext` (AES-GCM under a
/// password-derived key — see `WalletBackupCrypto`).
///
/// Forward-compatible: `version` + `kdf` + `kdfIterations` + `salt` travel
/// with the ciphertext so a future KDF/iteration bump stays decryptable.
struct WalletBackupBlob: Codable, Sendable, Equatable, Identifiable {
    static let currentVersion = 1

    let version: Int
    /// The original wallet's id — stable across devices so a restore can be
    /// recognized as "already have this" and a re-backup overwrites cleanly.
    let walletId: UUID
    /// Clear (non-secret) — shown in the restore picker so the user knows
    /// which backup they're about to decrypt.
    let walletName: String
    let createdAt: Date
    /// 12 or 24 — clear; lets the UI describe the backup without the key.
    let wordCount: Int

    // Key-derivation parameters (clear — they are not secret by design).
    let kdf: String
    let kdfIterations: Int
    let salt: Data
    /// AES-GCM combined box (nonce ‖ ciphertext ‖ tag) of the space-joined
    /// BIP-39 phrase. Useless without the password-derived key.
    let ciphertext: Data

    var id: UUID { walletId }

    init(
        version: Int = WalletBackupBlob.currentVersion,
        walletId: UUID,
        walletName: String,
        createdAt: Date,
        wordCount: Int,
        kdf: String,
        kdfIterations: Int,
        salt: Data,
        ciphertext: Data
    ) {
        self.version = version
        self.walletId = walletId
        self.walletName = walletName
        self.createdAt = createdAt
        self.wordCount = wordCount
        self.kdf = kdf
        self.kdfIterations = kdfIterations
        self.salt = salt
        self.ciphertext = ciphertext
    }

    // MARK: - Build / open

    /// Encrypt a wallet's mnemonic into a fresh backup blob.
    static func make(
        walletId: UUID,
        walletName: String,
        words: [String],
        password: String,
        createdAt: Date
    ) throws -> WalletBackupBlob {
        let mnemonic = words.joined(separator: " ")
        let sealed = try WalletBackupCrypto.encrypt(mnemonic: mnemonic, password: password)
        return WalletBackupBlob(
            walletId: walletId,
            walletName: walletName,
            createdAt: createdAt,
            wordCount: words.count,
            kdf: WalletBackupCrypto.kdfName,
            kdfIterations: sealed.iterations,
            salt: sealed.salt,
            ciphertext: sealed.ciphertext
        )
    }

    /// Decrypt this blob's recovery phrase with `password`. Throws
    /// `WalletBackupCrypto.CryptoError.openFailed` on a wrong password.
    func recoverWords(password: String) throws -> [String] {
        let mnemonic = try WalletBackupCrypto.decrypt(
            ciphertext: ciphertext,
            password: password,
            salt: salt,
            iterations: kdfIterations
        )
        return mnemonic.split(separator: " ").map(String.init)
    }

    /// Encode for storage (CloudKit blob field / iCloud document body).
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> WalletBackupBlob {
        try JSONDecoder().decode(WalletBackupBlob.self, from: data)
    }
}
