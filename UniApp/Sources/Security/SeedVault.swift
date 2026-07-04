import Foundation

/// GRDB-backed encrypted storage for BIP-39 64-byte seeds.
///
/// The seed is stored as a `wallet_secrets` row with `kind_raw = seed`, using
/// the same AES-GCM envelope and GRDB-backed master key as mnemonic and
/// private-key material.
enum SeedVault {
    enum VaultError: Error, Sendable, Equatable {
        case databaseWriteFailed(String)
        case databaseReadFailed(String)
        case databaseDeleteFailed(String)
        case noSuchWallet
        case decryptionFailed
        case invalidSeedLength
    }

    static func storeSeed(
        _ seed: Data,
        for walletId: UUID,
        database: AppDatabase = .shared
    ) throws(VaultError) {
        guard seed.count == 64 else { throw .invalidSeedLength }
        do {
            try WalletSecretPersistence.upsertSeed(seed, for: walletId, database: database)
        } catch {
            throw .databaseWriteFailed(String(describing: error))
        }
    }

    static func loadSeed(
        for walletId: UUID,
        database: AppDatabase = .shared
    ) throws(VaultError) -> Data {
        do {
            guard let seed = try WalletSecretPersistence.loadSeed(for: walletId, database: database) else {
                throw VaultError.noSuchWallet
            }
            guard seed.count == 64 else { throw VaultError.invalidSeedLength }
            return seed
        } catch let error as VaultError {
            throw error
        } catch WalletSecretCrypto.CryptoError.openFailed {
            throw .decryptionFailed
        } catch {
            throw .databaseReadFailed(String(describing: error))
        }
    }

    static func hasSeed(for walletId: UUID, database: AppDatabase = .shared) -> Bool {
        WalletSecretPersistence.hasSecret(kind: .seed, for: walletId, database: database)
    }

    static func deleteSeed(
        for walletId: UUID,
        database: AppDatabase = .shared
    ) throws(VaultError) {
        do {
            try WalletSecretPersistence.deleteSecret(kind: .seed, for: walletId, database: database)
        } catch {
            throw .databaseDeleteFailed(String(describing: error))
        }
    }
}
