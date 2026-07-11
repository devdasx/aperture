import Foundation
import GRDB
import WalletCore

/// Shared receive/change address book for Bitcoin-family chains
/// (BTC, BCH, LTC, DOGE).
///
/// **BUG-016 / multi-address UTXO:**
/// - Gap limit **20** on receive (`…/0/i`) and change (`…/1/i`)
/// - Every generated address is **persisted** in `wallet_addresses` with
///   its BIP derivation path (keys are derived from the seed + path at
///   sign time — path is the durable alignment with each address)
/// - If the **current gap window** has any balance/history hit, another
///   gap of 20 is generated and scanned until a quiet window
/// - Send drafts allocate a **fresh change** address (`…/1/n`), not
///   `fromAddress` reuse
enum BitcoinFamilyAddressBook {
    static let gapLimit = 20

    struct DerivedAddress: Sendable, Hashable {
        let address: String
        let path: String
        /// 0 = receive, 1 = change
        let branch: Int
        let index: Int
        let purpose: Int
    }

    // MARK: - Chain path constants

    static func isBitcoinFamily(_ chain: SupportedChain) -> Bool {
        chain.family == .bitcoin
    }

    /// Preferred BIP purpose for new receive/change windows.
    static func primaryPurpose(for chain: SupportedChain) -> Int {
        switch chain {
        case .bitcoin: return 84      // native segwit bc1q
        case .litecoin: return 84
        case .bitcoinCash, .dogecoin: return 44
        default: return 84
        }
    }

    /// All purposes to discover when scanning an HD mnemonic wallet.
    static func discoveryPurposes(for chain: SupportedChain) -> [Int] {
        switch chain {
        case .bitcoin: return [86, 84, 49, 44]
        case .litecoin: return [84, 49, 44]
        case .bitcoinCash, .dogecoin: return [44]
        default: return [84]
        }
    }

    static func slip44(for chain: SupportedChain) -> Int {
        switch chain {
        case .bitcoin: return 0
        case .litecoin: return 2
        case .dogecoin: return 3
        case .bitcoinCash: return 145
        default: return 0
        }
    }

    static func path(purpose: Int, chain: SupportedChain, branch: Int, index: Int) -> String {
        "m/\(purpose)'/\(slip44(for: chain))'/0'/\(branch)/\(index)"
    }

    // MARK: - Derivation

    static func deriveAddress(
        words: [String],
        passphrase: String = "",
        chain: SupportedChain,
        purpose: Int,
        branch: Int,
        index: Int
    ) throws -> DerivedAddress {
        guard let coin = ChainCoinType.coinType(for: chain) else {
            throw BitcoinFamilyAddressError.unsupportedChain(chain)
        }
        guard let hdWallet = HDWallet(
            mnemonic: words.joined(separator: " "),
            passphrase: passphrase
        ) else {
            throw BitcoinFamilyAddressError.invalidMnemonic
        }
        let derivation = path(purpose: purpose, chain: chain, branch: branch, index: index)
        let privateKey = hdWallet.getKey(coin: coin, derivationPath: derivation)
        let address = addressString(privateKey: privateKey, coin: coin, chain: chain, purpose: purpose)
        guard !address.isEmpty else {
            throw BitcoinFamilyAddressError.derivationFailed(derivation)
        }
        return DerivedAddress(
            address: address,
            path: derivation,
            branch: branch,
            index: index,
            purpose: purpose
        )
    }

    /// Seed a full gap window (receive + change) for every discovery purpose.
    static func deriveGapWindow(
        words: [String],
        passphrase: String = "",
        chain: SupportedChain,
        startIndex: Int,
        count: Int = gapLimit,
        purposes: [Int]? = nil
    ) throws -> [DerivedAddress] {
        let purposeList = purposes ?? discoveryPurposes(for: chain)
        var out: [DerivedAddress] = []
        out.reserveCapacity(purposeList.count * 2 * count)
        for purpose in purposeList {
            for branch in 0...1 {
                for offset in 0..<count {
                    let index = startIndex + offset
                    out.append(
                        try deriveAddress(
                            words: words,
                            passphrase: passphrase,
                            chain: chain,
                            purpose: purpose,
                            branch: branch,
                            index: index
                        )
                    )
                }
            }
        }
        return out
    }

    // MARK: - Persistence

    /// Insert or update addresses; never drops existing paths.
    @discardableResult
    static func persist(
        walletId: UUID,
        chain: SupportedChain,
        addresses: [DerivedAddress],
        markUsed: Set<String> = [],
        database: AppDatabase
    ) throws -> Int {
        guard !addresses.isEmpty else { return 0 }
        let chainRaw = chain.rawValue
        let scannedAt = Date.databaseMilliseconds
        return try database.write { db in
            var saved = 0
            var seen = Set<String>()
            for item in addresses where seen.insert(item.address).inserted {
                let used = markUsed.contains(item.address) ? 1 : 0
                let existingId = try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM wallet_addresses
                    WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                    LIMIT 1
                    """,
                    arguments: [walletId.uuidString, chainRaw, item.address]
                )
                if let existingId {
                    try db.execute(
                        sql: """
                        UPDATE wallet_addresses
                        SET derivation_path = CASE WHEN ? <> '' THEN ? ELSE derivation_path END,
                            is_used = CASE WHEN is_used = 1 OR ? = 1 THEN 1 ELSE 0 END,
                            last_scanned_at_ms = ?
                        WHERE id = ?
                        """,
                        arguments: [item.path, item.path, used, scannedAt, existingId]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO wallet_addresses
                        (id, wallet_id, chain_raw, address, derivation_path,
                         is_used, is_receive_preferred, last_scanned_at_ms)
                        VALUES (?, ?, ?, ?, ?, ?, 0, ?)
                        """,
                        arguments: [
                            UUID().uuidString,
                            walletId.uuidString,
                            chainRaw,
                            item.address,
                            item.path,
                            used,
                            scannedAt
                        ]
                    )
                }
                saved += 1
            }
            return saved
        }
    }

    /// Highest persisted index for a purpose/branch (nil if none).
    static func highestPersistedIndex(
        walletId: UUID,
        chain: SupportedChain,
        purpose: Int,
        branch: Int,
        database: AppDatabase
    ) throws -> Int? {
        let prefix = "m/\(purpose)'/\(slip44(for: chain))'/0'/\(branch)/"
        let paths = try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT derivation_path FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ? AND derivation_path LIKE ?
                """,
                arguments: [walletId.uuidString, chain.rawValue, prefix + "%"]
            )
        }
        let indices = paths.compactMap { path -> Int? in
            guard path.hasPrefix(prefix) else { return nil }
            return Int(path.dropFirst(prefix.count))
        }
        return indices.max()
    }

    /// Highest used (is_used=1) index for purpose/branch.
    static func highestUsedIndex(
        walletId: UUID,
        chain: SupportedChain,
        purpose: Int,
        branch: Int,
        database: AppDatabase
    ) throws -> Int? {
        let prefix = "m/\(purpose)'/\(slip44(for: chain))'/0'/\(branch)/"
        let paths = try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT derivation_path FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ?
                  AND is_used = 1 AND derivation_path LIKE ?
                """,
                arguments: [walletId.uuidString, chain.rawValue, prefix + "%"]
            )
        }
        let indices = paths.compactMap { path -> Int? in
            guard path.hasPrefix(prefix) else { return nil }
            return Int(path.dropFirst(prefix.count))
        }
        return indices.max()
    }

    /// Ensure at least `gapLimit` unused headroom past the highest used
    /// index on each branch of each discovery purpose. Returns newly
    /// generated addresses that must be scanned.
    static func ensureGapCoverage(
        walletId: UUID,
        chain: SupportedChain,
        words: [String],
        passphrase: String = "",
        database: AppDatabase
    ) throws -> [DerivedAddress] {
        var newlyGenerated: [DerivedAddress] = []
        for purpose in discoveryPurposes(for: chain) {
            for branch in 0...1 {
                let highestUsed = try highestUsedIndex(
                    walletId: walletId, chain: chain, purpose: purpose, branch: branch, database: database
                ) ?? -1
                let highestPersisted = try highestPersistedIndex(
                    walletId: walletId, chain: chain, purpose: purpose, branch: branch, database: database
                ) ?? -1
                // Need indices 0…gapLimit-1 at minimum, and always
                // gapLimit free indices after the highest used.
                let requiredHigh = max(gapLimit - 1, highestUsed + gapLimit)
                if highestPersisted >= requiredHigh { continue }

                let start = highestPersisted + 1
                let count = requiredHigh - highestPersisted
                for index in start...(start + count - 1) {
                    let derived = try deriveAddress(
                        words: words,
                        passphrase: passphrase,
                        chain: chain,
                        purpose: purpose,
                        branch: branch,
                        index: index
                    )
                    newlyGenerated.append(derived)
                }
            }
        }
        if !newlyGenerated.isEmpty {
            try persist(walletId: walletId, chain: chain, addresses: newlyGenerated, database: database)
        }
        // Also seed primary purpose 0..<gapLimit when DB is empty for this chain.
        if try highestPersistedIndex(
            walletId: walletId, chain: chain,
            purpose: primaryPurpose(for: chain), branch: 0, database: database
        ) == nil {
            let seed = try deriveGapWindow(
                words: words,
                passphrase: passphrase,
                chain: chain,
                startIndex: 0,
                count: gapLimit,
                purposes: [primaryPurpose(for: chain)]
            )
            try persist(walletId: walletId, chain: chain, addresses: seed, database: database)
            newlyGenerated.append(contentsOf: seed)
        }
        return newlyGenerated
    }

    /// After a scan: mark activity addresses used; if any branch's highest
    /// used index sits inside the last gap window of persisted indices,
    /// extend that branch and return the new addresses to scan.
    static func markUsedAndExtendIfNeeded(
        walletId: UUID,
        chain: SupportedChain,
        activeAddresses: Set<String>,
        words: [String]?,
        passphrase: String = "",
        database: AppDatabase
    ) throws -> [DerivedAddress] {
        if !activeAddresses.isEmpty {
            try database.write { db in
                for address in activeAddresses {
                    try db.execute(
                        sql: """
                        UPDATE wallet_addresses
                        SET is_used = 1, last_scanned_at_ms = ?
                        WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                        """,
                        arguments: [
                            Date.databaseMilliseconds,
                            walletId.uuidString,
                            chain.rawValue,
                            address
                        ]
                    )
                }
            }
        }
        guard let words, !words.isEmpty else { return [] }
        return try ensureGapCoverage(
            walletId: walletId,
            chain: chain,
            words: words,
            passphrase: passphrase,
            database: database
        )
    }

    /// Next change address for a send (`…/1/i`), creating/persisting if needed.
    /// Prefers the chain's primary purpose (BIP84 for BTC/LTC, BIP44 for BCH/DOGE).
    static func allocateChangeAddress(
        walletId: UUID,
        chain: SupportedChain,
        words: [String]?,
        passphrase: String = "",
        database: AppDatabase
    ) throws -> String? {
        guard isBitcoinFamily(chain) else { return nil }
        let purpose = primaryPurpose(for: chain)
        let highestUsed = try highestUsedIndex(
            walletId: walletId, chain: chain, purpose: purpose, branch: 1, database: database
        ) ?? -1
        let nextIndex = highestUsed + 1

        // Prefer an already-persisted unused change address at nextIndex.
        let expectedPath = path(purpose: purpose, chain: chain, branch: 1, index: nextIndex)
        if let existing = try database.read({ db in
            try String.fetchOne(
                db,
                sql: """
                SELECT address FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ? AND derivation_path = ?
                LIMIT 1
                """,
                arguments: [walletId.uuidString, chain.rawValue, expectedPath]
            )
        }) {
            return existing
        }

        // Derive + persist when we have a mnemonic.
        guard let words, !words.isEmpty else {
            // Fall back to any unused change address already in DB.
            return try database.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                    SELECT address FROM wallet_addresses
                    WHERE wallet_id = ? AND chain_raw = ?
                      AND derivation_path LIKE ?
                      AND is_used = 0
                    ORDER BY derivation_path ASC
                    LIMIT 1
                    """,
                    arguments: [
                        walletId.uuidString,
                        chain.rawValue,
                        "m/\(purpose)'/\(slip44(for: chain))'/0'/1/%"
                    ]
                )
            }
        }

        let derived = try deriveAddress(
            words: words,
            passphrase: passphrase,
            chain: chain,
            purpose: purpose,
            branch: 1,
            index: nextIndex
        )
        try persist(walletId: walletId, chain: chain, addresses: [derived], database: database)
        // Keep gap headroom after allocating change.
        _ = try ensureGapCoverage(
            walletId: walletId,
            chain: chain,
            words: words,
            passphrase: passphrase,
            database: database
        )
        return derived.address
    }

    /// All persisted addresses for a chain (for multi-address UTXO scans).
    static func persistedAddresses(
        walletId: UUID,
        chain: SupportedChain,
        database: AppDatabase
    ) throws -> [(address: String, path: String)] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT address, derivation_path FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ?
                ORDER BY is_receive_preferred DESC, derivation_path ASC
                """,
                arguments: [walletId.uuidString, chain.rawValue]
            ).map { row in
                (row["address"] as String, row["derivation_path"] as String)
            }
        }
    }

    // MARK: - Address encoding

    private static func addressString(
        privateKey: PrivateKey,
        coin: CoinType,
        chain: SupportedChain,
        purpose: Int
    ) -> String {
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true)
        switch chain {
        case .bitcoin, .litecoin:
            switch purpose {
            case 44:
                return BitcoinAddress(publicKey: publicKey, prefix: coin.p2pkhPrefix)?.description
                    ?? coin.deriveAddress(privateKey: privateKey)
            case 49:
                return BitcoinAddress.compatibleAddress(publicKey: publicKey, prefix: coin.p2shPrefix).description
            case 86:
                return coin.deriveAddressFromPublicKeyAndDerivation(
                    publicKey: publicKey,
                    derivation: .bitcoinTaproot
                )
            default:
                return coin.deriveAddressFromPublicKeyAndDerivation(
                    publicKey: publicKey,
                    derivation: .bitcoinSegwit
                )
            }
        default:
            return coin.deriveAddress(privateKey: privateKey)
        }
    }
}

enum BitcoinFamilyAddressError: Error, CustomStringConvertible {
    case unsupportedChain(SupportedChain)
    case invalidMnemonic
    case derivationFailed(String)

    var description: String {
        switch self {
        case .unsupportedChain(let chain):
            return "Bitcoin-family address book does not support \(chain.rawValue)"
        case .invalidMnemonic:
            return "Invalid mnemonic for Bitcoin-family derivation"
        case .derivationFailed(let path):
            return "Derivation failed for \(path)"
        }
    }
}
