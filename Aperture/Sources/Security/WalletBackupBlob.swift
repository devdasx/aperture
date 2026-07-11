import Foundation

/// The encrypted backup envelope that is stored in iCloud and read back on
/// restore (2026-06-19 backup handoff). Designed so the restore screen can
/// **list** a user's backups and let them pick one *before* they enter the
/// password — so a small amount of non-secret metadata (name, creation
/// date, word count, passphrase flag) is stored in clear. The recovery
/// phrase itself is the only true secret and is always `ciphertext`
/// (AES-GCM under a password-derived key — see `WalletBackupCrypto`).
///
/// Forward-compatible: `version` + `kdf` + `kdfIterations` + `salt` travel
/// with the ciphertext so a future KDF/iteration bump stays decryptable.
///
/// **P0-003 — BIP-39 passphrase.** The backup password is NOT the BIP-39
/// passphrase. When `hasPassphrase` is true, restore must collect the
/// wallet's BIP-39 passphrase and refuse silent empty-passphrase derivation
/// (empty salt would produce a *different* seed and empty wrong addresses).
struct WalletBackupBlob: Codable, Sendable, Equatable, Identifiable {
    /// Bumped when the envelope gains new required semantics. v1 blobs
    /// without `hasPassphrase` decode as `hasPassphrase == false`.
    static let currentVersion = 2

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
    /// The wallet's avatar (user-chosen color / logo) — clear, non-secret —
    /// so the restore picker shows the SAME identity disc the user picked
    /// instead of a generic cloud, and a restored wallet keeps its look
    /// (2026-06-20 user direction). Optional: backups made before this field
    /// decode as nil, and the restore UI falls back to the deterministic
    /// `auto(name)` disc so it's still a colored logo, never a cloud+lock.
    let avatar: WalletAvatarSpec?
    /// **P0-003.** Clear flag: the original wallet was created/imported with
    /// a non-empty BIP-39 passphrase. The passphrase itself is NEVER stored
    /// (not in ciphertext, not in clear). Restore must prompt for it.
    let hasPassphrase: Bool

    // Key-derivation parameters (clear — they are not secret by design).
    let kdf: String
    let kdfIterations: Int
    let salt: Data
    /// AES-GCM combined box (nonce ‖ ciphertext ‖ tag) of the space-joined
    /// BIP-39 phrase. Useless without the password-derived key.
    let ciphertext: Data

    var id: UUID { walletId }

    /// Restore must collect a BIP-39 passphrase (non-empty) before deriving.
    var requiresBIP39Passphrase: Bool { hasPassphrase }

    init(
        version: Int = WalletBackupBlob.currentVersion,
        walletId: UUID,
        walletName: String,
        createdAt: Date,
        wordCount: Int,
        avatar: WalletAvatarSpec? = nil,
        hasPassphrase: Bool = false,
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
        self.avatar = avatar
        self.hasPassphrase = hasPassphrase
        self.kdf = kdf
        self.kdfIterations = kdfIterations
        self.salt = salt
        self.ciphertext = ciphertext
    }

    // MARK: - Codable (backward compatible)

    private enum CodingKeys: String, CodingKey {
        case version, walletId, walletName, createdAt, wordCount, avatar
        case hasPassphrase
        case kdf, kdfIterations, salt, ciphertext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        walletId = try c.decode(UUID.self, forKey: .walletId)
        walletName = try c.decode(String.self, forKey: .walletName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        wordCount = try c.decode(Int.self, forKey: .wordCount)
        avatar = try c.decodeIfPresent(WalletAvatarSpec.self, forKey: .avatar)
        // v1 backups omit the key → treat as no passphrase (legacy).
        hasPassphrase = try c.decodeIfPresent(Bool.self, forKey: .hasPassphrase) ?? false
        kdf = try c.decode(String.self, forKey: .kdf)
        kdfIterations = try c.decode(Int.self, forKey: .kdfIterations)
        salt = try c.decode(Data.self, forKey: .salt)
        ciphertext = try c.decode(Data.self, forKey: .ciphertext)
    }

    // MARK: - Build / open

    /// Encrypt a wallet's mnemonic into a fresh backup blob.
    /// - Parameter hasPassphrase: Whether the wallet uses a BIP-39 passphrase
    ///   (clear flag only — the passphrase is never written to the blob).
    static func make(
        walletId: UUID,
        walletName: String,
        words: [String],
        password: String,
        createdAt: Date,
        avatar: WalletAvatarSpec? = nil,
        hasPassphrase: Bool = false
    ) throws -> WalletBackupBlob {
        let mnemonic = words.joined(separator: " ")
        let sealed = try WalletBackupCrypto.encrypt(mnemonic: mnemonic, password: password)
        return WalletBackupBlob(
            version: currentVersion,
            walletId: walletId,
            walletName: walletName,
            createdAt: createdAt,
            wordCount: words.count,
            avatar: avatar,
            hasPassphrase: hasPassphrase,
            kdf: WalletBackupCrypto.kdfName,
            kdfIterations: sealed.iterations,
            salt: sealed.salt,
            ciphertext: sealed.ciphertext
        )
    }

    /// Decrypt this blob's recovery phrase with `password`. Throws
    /// `WalletBackupCrypto.CryptoError.openFailed` on a wrong password.
    /// Does **not** apply a BIP-39 passphrase — that is a separate restore step.
    func recoverWords(password: String) throws -> [String] {
        let mnemonic = try WalletBackupCrypto.decrypt(
            ciphertext: ciphertext,
            password: password,
            salt: salt,
            iterations: kdfIterations
        )
        return mnemonic.split(separator: " ").map(String.init)
    }

    /// **P0-003.** Resolve the BIP-39 passphrase for derivation after the
    /// backup password has decrypted the words.
    ///
    /// - When `hasPassphrase` is true, `passphrase` must be non-empty after
    ///   trim; otherwise throws `.passphraseRequired`.
    /// - When `hasPassphrase` is false, empty is allowed (standard wallets);
    ///   a non-empty optional value is still used if the user supplies one
    ///   (legacy backups that predate the flag).
    static func resolvedPassphrase(
        hasPassphrase: Bool,
        passphrase: String
    ) throws -> String {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasPassphrase {
            guard !trimmed.isEmpty else {
                throw RestorePassphraseError.passphraseRequired
            }
            return trimmed
        }
        return trimmed
    }

    /// Encode for storage (CloudKit blob field / iCloud document body).
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> WalletBackupBlob {
        try JSONDecoder().decode(WalletBackupBlob.self, from: data)
    }
}

/// Errors for the post-decrypt BIP-39 passphrase gate (P0-003).
enum RestorePassphraseError: Error, Equatable, Sendable {
    /// Backup was flagged `hasPassphrase` but restore tried empty passphrase.
    case passphraseRequired

    var userMessage: String {
        switch self {
        case .passphraseRequired:
            return "This wallet was backed up with a BIP-39 passphrase. Enter that passphrase to restore the correct addresses — leaving it blank creates a different empty wallet."
        }
    }
}
