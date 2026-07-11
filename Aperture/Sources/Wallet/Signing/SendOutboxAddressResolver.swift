import Foundation
import GRDB

/// BUG-018: Resolve the wallet + exact `fromAddress` row for a send.
///
/// History/activity is keyed by `wallet_addresses.id`. If we fall back to
/// the chain's preferred address when the draft's `fromAddress` is missing,
/// the pending outbox row attaches under the wrong address while signing
/// still uses `draft.fromAddress`. Require an exact match; refuse the send
/// when the address is not stored for this wallet on this chain.
enum SendOutboxAddressResolver {

    enum Resolution: Sendable, Equatable {
        case walletNotFound
        case addressNotFound
        case resolved(WalletDescriptor, addressId: UUID)
    }

    /// Exact `(walletId, chain, fromAddress)` lookup. EVM addresses compare
    /// case-insensitively (EIP-55 checksum variance). Never falls back to
    /// `is_receive_preferred`.
    static func resolve(
        walletId: UUID,
        chain: SupportedChain,
        fromAddress: String,
        database: AppDatabase
    ) -> Resolution {
        let trimmed = fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .addressNotFound }

        do {
            return try database.read { db in
                guard let walletRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, kind_raw, has_passphrase
                    FROM wallets
                    WHERE id = ?
                    LIMIT 1
                    """,
                    arguments: [walletId.uuidString]
                ), let id = UUID(uuidString: walletRow["id"]) else {
                    return .walletNotFound
                }

                let addressId = try fetchExactAddressId(
                    db: db,
                    walletId: walletId,
                    chain: chain,
                    fromAddress: trimmed
                )
                guard let addressId else {
                    return .addressNotFound
                }

                // P2-023: corrupt kind_raw → refuse spend (walletNotFound),
                // not watchOnly which confuses export until fixed.
                guard let kind = WalletKind(rawValue: walletRow["kind_raw"]) else {
                    return .walletNotFound
                }
                return .resolved(
                    WalletDescriptor(
                        id: id,
                        kind: kind,
                        hasPassphrase: (walletRow["has_passphrase"] as Int) != 0
                    ),
                    addressId: addressId
                )
            }
        } catch {
            return .walletNotFound
        }
    }

    /// Match logic used by resolve — exposed for pure unit tests without DB.
    static func matchesAddress(
        stored: String,
        fromAddress: String,
        chain: SupportedChain
    ) -> Bool {
        if chain.family == .evm {
            return stored.caseInsensitiveCompare(fromAddress) == .orderedSame
        }
        return stored == fromAddress
    }

    // MARK: - Private

    private static func fetchExactAddressId(
        db: Database,
        walletId: UUID,
        chain: SupportedChain,
        fromAddress: String
    ) throws -> UUID? {
        // Exact string match first (canonical stored form).
        if let raw = try String.fetchOne(
            db,
            sql: """
            SELECT id FROM wallet_addresses
            WHERE wallet_id = ? AND chain_raw = ? AND address = ?
            LIMIT 1
            """,
            arguments: [walletId.uuidString, chain.rawValue, fromAddress]
        ), let uuid = UUID(uuidString: raw) {
            return uuid
        }

        // EVM: allow EIP-55 checksum / mixed-case variance only.
        guard chain.family == .evm else { return nil }

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, address FROM wallet_addresses
            WHERE wallet_id = ? AND chain_raw = ?
            """,
            arguments: [walletId.uuidString, chain.rawValue]
        )
        for row in rows {
            let stored: String = row["address"]
            if matchesAddress(stored: stored, fromAddress: fromAddress, chain: chain),
               let uuid = UUID(uuidString: row["id"]) {
                return uuid
            }
        }
        return nil
    }
}
