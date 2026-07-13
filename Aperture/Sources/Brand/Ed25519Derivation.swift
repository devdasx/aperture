import Foundation
import CryptoKit

/// Real per-chain address derivation for ed25519 chains where the
/// address-encoding primitive is in CryptoKit. Each function takes a
/// 64-byte BIP-39 seed and returns the chain's canonical first
/// address.
///
/// **Coverage matrix (today, v1).**
///
/// | Chain   | Path                  | Encoding                       | Status |
/// |---------|-----------------------|--------------------------------|--------|
/// | Solana  | m/44'/501'/0'/0'      | base58(pubkey)                 | REAL   |
/// | NEAR    | m/44'/397'/0'         | hex(pubkey).lowercased         | REAL   |
/// | Aptos   | m/44'/637'/0'/0'/0'   | 0x ‖ SHA3-256(pubkey ‖ 0x00)   | PENDING (SHA-3 not in CryptoKit) |
/// | Sui     | m/44'/784'/0'/0'/0'   | 0x ‖ BLAKE2b-256(0x00 ‖ pubkey)| PENDING (BLAKE2b not in CryptoKit) |
/// | Stellar | m/44'/148'/0'         | StrKey('G', pubkey, CRC16-XModem)| PENDING (CRC16-XModem not in CryptoKit) |
/// | TON     | m/44'/607'/0'         | TON wallet v3r2 contract addr  | PENDING (contract math not implemented) |
///
/// **Honesty (Rule #2 §A.7).** Production Solana/NEAR paths use real
/// CryptoKit derivation. Chains without in-tree encoders are not
/// fabricated with `[STUB]` addresses — callers must use WalletCore
/// or refuse.
enum Ed25519Derivation {

    enum DerivationError: Error, Sendable, Equatable {
        /// CryptoKit rejected the 32-byte seed (should be unreachable for
        /// valid SLIP-0010 nodes). Never invent a zero public key.
        case publicKeyDerivationFailed
    }

    /// Solana address: base58 of the 32-byte ed25519 public key,
    /// derived at the Phantom-compatible path `m/44'/501'/0'/0'`.
    /// First-account address (no sub-account index).
    static func solanaAddress(seed: Data) throws -> String {
        try solanaPhantomAddress(seed: seed, account: 0)
    }

    /// Phantom-style Solana address at `m/44'/501'/account'/0'`.
    static func solanaPhantomAddress(seed: Data, account: UInt32) throws -> String {
        let node = SLIP0010.derive(seed: seed, hardenedPath: [44, 501, account, 0])
        let publicKey = try ed25519PublicKey(from: node.privateKey)
        return Base58.encode(publicKey)
    }

    /// Trust Wallet-style Solana account address at `m/44'/501'/account'`.
    static func solanaTrustWalletAddress(seed: Data, account: UInt32) throws -> String {
        let node = SLIP0010.derive(seed: seed, hardenedPath: [44, 501, account])
        let publicKey = try ed25519PublicKey(from: node.privateKey)
        return Base58.encode(publicKey)
    }

    /// NEAR implicit-account address: lowercased hex of the 32-byte
    /// ed25519 public key, derived at `m/44'/397'/0'`. Implicit
    /// accounts are the user's first NEAR address on a fresh wallet.
    /// "Named" accounts (e.g., `alice.near`) require an explicit
    /// registration transaction and are not derivable from the seed.
    static func nearImplicitAccount(seed: Data) throws -> String {
        let node = SLIP0010.derive(seed: seed, hardenedPath: [44, 397, 0])
        let publicKey = try ed25519PublicKey(from: node.privateKey)
        return publicKey.map { String(format: "%02x", $0) }.joined()
    }

    /// Derive the ed25519 public key from a 32-byte private key seed
    /// via CryptoKit's Curve25519 primitive.
    ///
    /// P3-007: throws instead of `preconditionFailure`. Returning an
    /// all-zero public key would be fund-loss (receive-only address).
    private static func ed25519PublicKey(from privateKey: Data) throws -> Data {
        guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw DerivationError.publicKeyDerivationFailed
        }
        return signingKey.publicKey.rawRepresentation
    }
}

/// Solana HD path styles Aperture supports for receive/send selection.
///
/// - **Phantom** — `m/44'/501'/account'/0'` (Aperture default)
/// - **Trust Wallet** — `m/44'/501'/account'`
///
/// Both account-0 addresses are persisted on mnemonic create/import so the
/// home screen can balance-scan them. Send and Receive still use only the
/// `is_receive_preferred` path.
enum SolanaPathStyle: String, CaseIterable, Identifiable, Sendable, Hashable {
    case phantom
    case trustWallet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phantom: return "Phantom"
        case .trustWallet: return "Trust Wallet"
        }
    }

    func derivationPath(account: Int) -> String {
        switch self {
        case .phantom:
            return "m/44'/501'/\(account)'/0'"
        case .trustWallet:
            return "m/44'/501'/\(account)'"
        }
    }

    static func parse(_ path: String) -> (style: SolanaPathStyle, account: Int)? {
        let prefix = "m/44'/501'/"
        guard path.hasPrefix(prefix) else { return nil }
        let suffix = String(path.dropFirst(prefix.count))
        if suffix.hasSuffix("'/0'") {
            let accountRaw = suffix.dropLast(4)
            guard let account = Int(accountRaw) else { return nil }
            return (.phantom, account)
        }
        if suffix.hasSuffix("'"), suffix.contains("/") == false {
            let accountRaw = suffix.dropLast()
            guard let account = Int(accountRaw) else { return nil }
            return (.trustWallet, account)
        }
        return nil
    }
}

/// One derived Solana address row ready for `wallet_addresses` insert.
struct SolanaPathAddress: Sendable, Equatable {
    let style: SolanaPathStyle
    let account: Int
    let derivationPath: String
    let address: String
}

/// Derive and persist both account-0 Solana paths for a mnemonic wallet.
enum SolanaPathProvisioning {

    /// Phantom + Trust Wallet account 0, in that order (Phantom is preferred).
    static func deriveAccountZeroPaths(
        words: [String],
        passphrase: String = ""
    ) throws -> [SolanaPathAddress] {
        let normalized = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else {
            throw SolanaPathProvisioningError.missingMnemonic
        }
        let seed = BIP39.deriveSeed(words: normalized, passphrase: passphrase)
        var rows: [SolanaPathAddress] = []
        rows.reserveCapacity(2)

        let phantomAddress = try Ed25519Derivation.solanaPhantomAddress(seed: seed, account: 0)
        rows.append(
            SolanaPathAddress(
                style: .phantom,
                account: 0,
                derivationPath: SolanaPathStyle.phantom.derivationPath(account: 0),
                address: phantomAddress
            )
        )

        let trustAddress = try Ed25519Derivation.solanaTrustWalletAddress(seed: seed, account: 0)
        if trustAddress != phantomAddress {
            rows.append(
                SolanaPathAddress(
                    style: .trustWallet,
                    account: 0,
                    derivationPath: SolanaPathStyle.trustWallet.derivationPath(account: 0),
                    address: trustAddress
                )
            )
        }
        return rows
    }

    /// Address-list entries for create/import: all non-Solana chains once, plus
    /// both Solana paths when derivation succeeds.
    static func expandAddressEntries(
        derivedByChain: [SupportedChain: String],
        words: [String],
        passphrase: String
    ) -> [(chainRaw: String, address: String, derivationPath: String)] {
        var entries: [(chainRaw: String, address: String, derivationPath: String)] = []
        entries.reserveCapacity(derivedByChain.count + 1)

        for (chain, address) in derivedByChain where chain != .solana {
            entries.append((chainRaw: chain.rawValue, address: address, derivationPath: ""))
        }

        if let dual = try? deriveAccountZeroPaths(words: words, passphrase: passphrase), !dual.isEmpty {
            for row in dual {
                entries.append(
                    (
                        chainRaw: SupportedChain.solana.rawValue,
                        address: row.address,
                        derivationPath: row.derivationPath
                    )
                )
            }
        } else if let solana = derivedByChain[.solana], !solana.isEmpty {
            // Fallback: single Phantom-labeled row when dual derive fails.
            entries.append(
                (
                    chainRaw: SupportedChain.solana.rawValue,
                    address: solana,
                    derivationPath: SolanaPathStyle.phantom.derivationPath(account: 0)
                )
            )
        }
        return entries
    }

    /// Ensure both account-0 paths exist for an existing mnemonic wallet.
    /// Does not change `is_receive_preferred` except when no preferred Solana
    /// row exists (then Phantom becomes preferred).
    static func ensureBothAccountZeroPaths(
        walletId: UUID,
        words: [String],
        passphrase: String = "",
        database: AppDatabase = .shared
    ) throws {
        let dual = try deriveAccountZeroPaths(words: words, passphrase: passphrase)
        guard !dual.isEmpty else { return }

        try database.write { db in
            let preferredCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ? AND is_receive_preferred = 1
                """,
                arguments: [walletId.uuidString, SupportedChain.solana.rawValue]
            ) ?? 0
            var makePhantomPreferred = preferredCount == 0

            for row in dual {
                let existingId = try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM wallet_addresses
                    WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                    LIMIT 1
                    """,
                    arguments: [
                        walletId.uuidString,
                        SupportedChain.solana.rawValue,
                        row.address
                    ]
                )
                let prefer = makePhantomPreferred && row.style == .phantom
                if prefer { makePhantomPreferred = false }

                if let existingId {
                    try db.execute(
                        sql: """
                        UPDATE wallet_addresses
                        SET derivation_path = CASE
                                WHEN derivation_path = '' OR derivation_path IS NULL
                                THEN ? ELSE derivation_path END,
                            is_receive_preferred = CASE WHEN ? = 1 THEN 1 ELSE is_receive_preferred END
                        WHERE id = ?
                        """,
                        arguments: [row.derivationPath, prefer ? 1 : 0, existingId]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO wallet_addresses
                        (id, wallet_id, chain_raw, address, derivation_path,
                         is_used, is_receive_preferred, last_scanned_at_ms)
                        VALUES (?, ?, ?, ?, ?, 0, ?, NULL)
                        """,
                        arguments: [
                            UUID().uuidString,
                            walletId.uuidString,
                            SupportedChain.solana.rawValue,
                            row.address,
                            row.derivationPath,
                            prefer ? 1 : 0
                        ]
                    )
                }
            }
        }
    }

    /// Provision dual Solana paths when the correct passphrase is known.
    ///
    /// - No-passphrase wallets: derives with `""` (same as create/import).
    /// - Passphrase wallets: uses `passphrase` if provided, else the session
    ///   cache from a prior send/receive entry. **Never** falls back to empty
    ///   string for `hasPassphrase` wallets (would create wrong addresses).
    /// - Returns `true` when paths were written / already present after ensure.
    @discardableResult
    static func ensureBothAccountZeroPathsIfPossible(
        walletId: UUID,
        passphrase: String? = nil,
        database: AppDatabase = .shared
    ) async -> Bool {
        let hasPassphrase = (try? database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT has_passphrase FROM wallets WHERE id = ?",
                arguments: [walletId.uuidString]
            )
        }) ?? true

        let words: [String]
        do {
            guard let loaded = try WalletSecretPersistence.loadMnemonic(for: walletId, database: database),
                  !loaded.isEmpty else {
                return false
            }
            words = loaded
        } catch {
            return false
        }

        let resolved: String
        if hasPassphrase {
            if let passphrase {
                resolved = passphrase
            } else if let session = await BIP39PassphraseSession.shared.passphrase(for: walletId) {
                resolved = session
            } else {
                // Cannot safely derive without the real passphrase.
                return false
            }
        } else {
            resolved = ""
        }

        do {
            try ensureBothAccountZeroPaths(
                walletId: walletId,
                words: words,
                passphrase: resolved,
                database: database
            )
            return true
        } catch {
            return false
        }
    }
}

enum SolanaPathProvisioningError: Error {
    case missingMnemonic
}
