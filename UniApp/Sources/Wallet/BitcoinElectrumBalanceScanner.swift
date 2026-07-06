import CryptoKit
import Foundation
import GRDB
import Network
import OSLog
import WalletCore

actor BitcoinElectrumBalanceScanner {
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "bitcoin-electrum")
    private let client = RPCClient.shared

    func scanAndPersist(
        walletId: UUID,
        currencyCode: String,
        database: AppDatabase,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        let targetRepository = BitcoinWalletScanTargetRepository(database: database)
        let plan = try await targetRepository.scanPlan(walletId: walletId)
        guard let plan, !plan.targets.isEmpty else { return }

        async let prices: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: ["BTC"],
                currencyCode: currencyCode
            )
            : [:]
        async let liveScan = BitcoinElectrumClient.scanFirst(
            servers: BitcoinElectrumServer.defaults,
            targets: plan.targets,
            includeHistory: includeHistory
        )

        let (priceMap, result) = try await (prices, liveScan)
        let scans = result.scans
        let totalSats = scans.reduce(Int64(0)) { partial, scan in
            let addressTotal = scan.totalSats
            let (sum, overflow) = partial.addingReportingOverflow(addressTotal)
            return overflow ? Int64.max : sum
        }
        let isUsed = totalSats > 0 || scans.contains { $0.historyCount > 0 }
        let fiat = fiatValue(
            sats: totalSats,
            prices: priceMap
        )

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: plan.primaryAddressId,
            tokenSymbol: SupportedChain.bitcoin.ticker,
            tokenContract: nil,
            decimals: SupportedChain.bitcoin.nativeDecimals,
            rawBalance: String(totalSats),
            fiatValueCached: fiat,
            fiatCurrencyCode: currencyCode,
            save: false
        )
        if includeHistory {
            let history = await safeRecentEvents(scans: scans)
            for event in history.prefix(50) {
                try txRepo.upsertTransaction(
                    addressId: plan.primaryAddressId,
                    txHash: event.txHash,
                    direction: event.direction,
                    amountRaw: event.amount,
                    tokenSymbol: SupportedChain.bitcoin.ticker,
                    tokenContract: nil,
                    blockNumber: event.blockNumber,
                    occurredAt: event.occurredAt,
                    status: event.status,
                    counterparty: event.counterparty,
                    feeRaw: event.fee,
                    save: false
                )
            }
        }
        if includeHistory || totalSats > 0 {
            try txRepo.markScanComplete(
                addressId: plan.primaryAddressId,
                isUsed: isUsed,
                save: false
            )
        }
        try txRepo.flush()

        let chainRepo = ChainStateRepository(database: database)
        let discoveredAddresses = scans
            .filter(\.hasActivity)
            .map {
                ChainStateRepository.DiscoveredAddress(
                    address: $0.address,
                    derivationPath: $0.path,
                    isUsed: true
                )
            }
        _ = try chainRepo.upsertDiscoveredAddresses(
            walletId: walletId,
            chain: .bitcoin,
            addresses: discoveredAddresses
        )

        let utxos = scans.flatMap { scan in
            scan.utxos.map { utxo in
                ChainStateRepository.AddressedUTXO(
                    address: scan.address,
                    txid: utxo.txHash,
                    vout: utxo.txPosition,
                    valueSats: utxo.valueSats,
                    scriptHex: scan.scriptHex,
                    confirmed: utxo.height > 0
                )
            }
        }
        _ = try chainRepo.replaceAddressedUTXOs(
            walletId: walletId,
            chain: .bitcoin,
            utxos: utxos
        )
        _ = try chainRepo.rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: [.bitcoin],
            failedChains: [],
            interim: false
        )

        log.debug(
            "Bitcoin Electrum scan succeeded via \(result.serverDescription, privacy: .public): \(scans.count, privacy: .public) addresses, \(utxos.count, privacy: .public) utxos"
        )
    }

    private func safeRecentEvents(scans: [BitcoinElectrumAddressScan]) async -> [BitcoinElectrumTransactionEvent] {
        do {
            return try await recentEvents(scans: scans)
        } catch {
            log.debug("Bitcoin history normalization failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func recentEvents(scans: [BitcoinElectrumAddressScan]) async throws -> [BitcoinElectrumTransactionEvent] {
        let ownAddresses = Set(scans.map(\.address))
        guard !ownAddresses.isEmpty else { return [] }

        var heightsByHash: [String: Int] = [:]
        for scan in scans {
            for item in scan.history {
                heightsByHash[item.txHash] = item.height
            }
        }
        guard !heightsByHash.isEmpty else { return [] }

        let txHashes = heightsByHash
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(50)
            .map(\.key)

        var events: [BitcoinElectrumTransactionEvent] = []
        events.reserveCapacity(txHashes.count)
        await withTaskGroup(of: BitcoinElectrumTransactionEvent?.self) { group in
            for txHash in txHashes {
                let fallbackHeight = heightsByHash[txHash]
                group.addTask { [client] in
                    guard let data = try? await client.callREST(chain: .bitcoin, path: "tx/\(txHash)"),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        return nil
                    }
                    return BitcoinElectrumTransactionEvent(
                        object: object,
                        txHash: txHash,
                        ownAddresses: ownAddresses,
                        fallbackHeight: fallbackHeight
                    )
                }
            }
            for await event in group {
                if let event {
                    events.append(event)
                }
            }
        }
        events.sort { $0.occurredAt > $1.occurredAt }
        return events
    }

    private func fiatValue(
        sats: Int64,
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) -> Decimal? {
        guard let price = prices[SupportedChain.bitcoin.ticker] else { return nil }
        guard let amount = EVMHexQuantity.decimalAmount(
            rawBalance: String(sats),
            decimals: SupportedChain.bitcoin.nativeDecimals
        ) else { return nil }
        return amount * price.amount
    }
}

enum BitcoinPathSearchPurpose: String, CaseIterable, Identifiable, Sendable {
    case bip86
    case bip84
    case bip49
    case bip44

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bip86: return "BIP86"
        case .bip84: return "BIP84"
        case .bip49: return "BIP49"
        case .bip44: return "BIP44"
        }
    }

    var subtitle: String {
        switch self {
        case .bip86:
            return "Taproot receive paths, addresses start with bc1p."
        case .bip84:
            return "Native SegWit receive paths, addresses start with bc1q."
        case .bip49:
            return "Wrapped SegWit receive paths, addresses start with 3."
        case .bip44:
            return "Legacy receive paths, addresses start with 1."
        }
    }

    var pathTemplate: String {
        switch self {
        case .bip86: return "m/86'/0'/account'/change/index"
        case .bip84: return "m/84'/0'/account'/change/index"
        case .bip49: return "m/49'/0'/account'/change/index"
        case .bip44: return "m/44'/0'/account'/change/index"
        }
    }

    fileprivate var accountKind: BitcoinAccountKind {
        switch self {
        case .bip86: return .bip86
        case .bip84: return .bip84
        case .bip49: return .bip49
        case .bip44: return .bip44
        }
    }
}

struct BitcoinPathSearchRequest: Sendable {
    static let maxTargets = 250

    let purpose: BitcoinPathSearchPurpose
    let accountStart: Int
    let accountEnd: Int
    let changeStart: Int
    let changeEnd: Int
    let indexStart: Int
    let indexEnd: Int

    var accountRange: ClosedRange<Int> { accountStart...accountEnd }
    var changeRange: ClosedRange<Int> { changeStart...changeEnd }
    var indexRange: ClosedRange<Int> { indexStart...indexEnd }

    var targetCount: Int {
        (accountEnd - accountStart + 1)
            * (changeEnd - changeStart + 1)
            * (indexEnd - indexStart + 1)
    }

    func validate() throws {
        guard accountStart >= 0, changeStart >= 0, indexStart >= 0,
              accountEnd >= accountStart,
              changeEnd >= changeStart,
              indexEnd >= indexStart else {
            throw BitcoinPathSearchError.invalidRange
        }
        guard targetCount > 0 else { throw BitcoinPathSearchError.invalidRange }
        guard targetCount <= Self.maxTargets else {
            throw BitcoinPathSearchError.tooManyAddresses(targetCount)
        }
    }
}

struct BitcoinPathSearchResult: Identifiable, Equatable, Sendable {
    let address: String
    let path: String
    let confirmedSats: Int64
    let unconfirmedSats: Int64
    let historyCount: Int

    var id: String { "\(path)|\(address)" }
    var totalSats: Int64 { confirmedSats + unconfirmedSats }
    var hasActivity: Bool { totalSats > 0 || historyCount > 0 }

    var btcAmount: Decimal {
        Decimal(totalSats) / Decimal(100_000_000)
    }
}

enum BitcoinPathSearchError: LocalizedError {
    case walletNotFound
    case unsupportedWallet
    case passphraseWalletUnsupported
    case missingMnemonic
    case invalidRange
    case tooManyAddresses(Int)
    case noTargets

    var errorDescription: String? {
        switch self {
        case .walletNotFound:
            return "This wallet is no longer in the local database."
        case .unsupportedWallet:
            return "Bitcoin path search works with created or phrase-imported wallets."
        case .passphraseWalletUnsupported:
            return "This wallet uses a BIP-39 passphrase, so Aperture cannot safely search alternate paths from the stored words alone."
        case .missingMnemonic:
            return "This wallet does not have a stored recovery phrase on this iPhone."
        case .invalidRange:
            return "Enter a valid non-negative from/to range."
        case .tooManyAddresses(let count):
            return "This search covers \(count) addresses. Keep each run under \(BitcoinPathSearchRequest.maxTargets) addresses so the phone stays responsive."
        case .noTargets:
            return "No Bitcoin addresses could be derived for this range."
        }
    }
}

enum BitcoinPathSearchEngine {
    static func search(
        walletId: UUID,
        request: BitcoinPathSearchRequest,
        database: AppDatabase
    ) async throws -> [BitcoinPathSearchResult] {
        try request.validate()

        let repository = BitcoinPathSearchSecretRepository(database: database)
        let words = try await repository.mnemonic(walletId: walletId)
        let derived = try BitcoinHDAddressDeriver.deriveFromMnemonic(
            words,
            kind: request.purpose.accountKind,
            accountRange: request.accountRange,
            changeRange: request.changeRange,
            indexRange: request.indexRange
        )

        var seen: Set<String> = []
        let targets = try derived.compactMap { target -> BitcoinElectrumScanTarget? in
            guard seen.insert(target.address).inserted else { return nil }
            return try BitcoinElectrumScanTarget(address: target.address, path: target.path)
        }
        guard !targets.isEmpty else { throw BitcoinPathSearchError.noTargets }

        let liveScan = try await BitcoinElectrumClient.scanFirst(
            servers: BitcoinElectrumServer.defaults,
            targets: targets,
            includeHistory: true
        )

        return liveScan.scans
            .map { scan in
                BitcoinPathSearchResult(
                    address: scan.address,
                    path: scan.path,
                    confirmedSats: scan.confirmedSats,
                    unconfirmedSats: scan.unconfirmedSats,
                    historyCount: scan.historyCount
                )
            }
            .filter(\.hasActivity)
            .sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }
}

private actor BitcoinPathSearchSecretRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func mnemonic(walletId: UUID) throws -> [String] {
        guard let wallet = try database.read({ db in
            try BitcoinWalletRow.fetchOne(db, walletId: walletId)
        }) else {
            throw BitcoinPathSearchError.walletNotFound
        }
        guard wallet.kind == .created || wallet.kind == .importedMnemonic else {
            throw BitcoinPathSearchError.unsupportedWallet
        }
        guard !wallet.hasPassphrase else {
            throw BitcoinPathSearchError.passphraseWalletUnsupported
        }
        if let words = try? WalletSecretPersistence.loadMnemonic(for: wallet.id, database: database),
           !words.isEmpty {
            return words
        }
        throw BitcoinPathSearchError.missingMnemonic
    }
}

actor BitcoinPathSearchAddressStore {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func save(
        walletId: UUID,
        results: [BitcoinPathSearchResult],
        preferredResult: BitcoinPathSearchResult? = nil
    ) throws -> Int {
        var found = results.filter(\.hasActivity)
        if let preferredResult, !found.contains(where: { $0.id == preferredResult.id }) {
            found.append(preferredResult)
        }
        guard !found.isEmpty else { return 0 }

        let chainRaw = SupportedChain.bitcoin.rawValue
        let scannedAt = Date.databaseMilliseconds
        return try database.write { db in
            guard try BitcoinWalletRow.exists(db, walletId: walletId) else {
                throw BitcoinPathSearchError.walletNotFound
            }

            if preferredResult != nil {
                try db.execute(
                    sql: """
                    UPDATE wallet_addresses
                    SET is_receive_preferred = 0
                    WHERE wallet_id = ? AND chain_raw = ?
                    """,
                    arguments: [walletId.uuidString, chainRaw]
                )
            }

            var saved = 0
            var seen: Set<String> = []
            for result in found {
                guard seen.insert(result.id).inserted else { continue }
                let isPreferred = preferredResult?.id == result.id
                let addressId = try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM wallet_addresses
                    WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                    LIMIT 1
                    """,
                    arguments: [walletId.uuidString, chainRaw, result.address]
                )
                if let addressId {
                    try db.execute(
                        sql: """
                        UPDATE wallet_addresses
                        SET derivation_path = ?,
                            is_used = 1,
                            is_receive_preferred = CASE WHEN ? = 1 THEN 1 ELSE is_receive_preferred END,
                            last_scanned_at_ms = ?
                        WHERE id = ?
                        """,
                        arguments: [result.path, isPreferred ? 1 : 0, scannedAt, addressId]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO wallet_addresses
                        (id, wallet_id, chain_raw, address, derivation_path,
                         is_used, is_receive_preferred, last_scanned_at_ms)
                        VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                        """,
                        arguments: [
                            UUID().uuidString,
                            walletId.uuidString,
                            chainRaw,
                            result.address,
                            result.path,
                            isPreferred ? 1 : 0,
                            scannedAt
                        ]
                    )
                }
                saved += 1
            }
            return saved
        }
    }
}

private actor BitcoinWalletScanTargetRepository {
    private let gapLimit = 50
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func scanPlan(walletId: UUID) throws -> BitcoinElectrumScanPlan? {
        let chainRaw = SupportedChain.bitcoin.rawValue
        let snapshot = try database.read { db -> BitcoinWalletScanSnapshot? in
            guard let wallet = try BitcoinWalletRow.fetchOne(db, walletId: walletId) else { return nil }
            let addresses = try BitcoinWalletAddressRow.fetchAll(db, walletId: walletId, chainRaw: chainRaw)
            guard !addresses.isEmpty else { return nil }
            return BitcoinWalletScanSnapshot(wallet: wallet, addresses: addresses)
        }
        guard let snapshot else { return nil }
        let wallet = snapshot.wallet
        let bitcoinAddresses = snapshot.addresses
        guard let primary = bitcoinAddresses.first else { return nil }

        var targets: [BitcoinElectrumScanTarget] = []
        func append(address: String, path: String) {
            guard !targets.contains(where: { $0.address == address }),
                  let target = try? BitcoinElectrumScanTarget(address: address, path: path) else {
                return
            }
            targets.append(target)
        }
        for address in bitcoinAddresses {
            append(address: address.address, path: address.derivationPath)
        }

        switch wallet.kind {
        case .created, .importedMnemonic:
            if !wallet.hasPassphrase,
               let words = loadMnemonic(walletId: wallet.id),
               let derived = try? BitcoinHDAddressDeriver.deriveFromMnemonic(
                    words,
                    gapLimit: gapLimit
               ) {
                for target in derived {
                    append(address: target.address, path: target.path)
                }
            }
        case .importedKey:
            if let keyString = loadPrivateKey(walletId: wallet.id) {
                for target in (try? BitcoinHDAddressDeriver.deriveFromPrivateKeyInput(
                    keyString,
                    gapLimit: gapLimit
                )) ?? [] {
                    append(address: target.address, path: target.path)
                }
            }
        case .watchOnly:
            break
        }

        guard !targets.isEmpty else { return nil }
        return BitcoinElectrumScanPlan(
            primaryAddressId: primary.id,
            targets: targets
        )
    }

    private func loadMnemonic(walletId: UUID) -> [String]? {
        if let words = try? WalletSecretPersistence.loadMnemonic(for: walletId, database: database),
           !words.isEmpty {
            return words
        }
        return nil
    }

    private func loadPrivateKey(walletId: UUID) -> String? {
        if let key = try? WalletSecretPersistence.loadPrivateKey(for: walletId, database: database),
           !key.isEmpty {
            return key
        }
        return nil
    }
}

private struct BitcoinElectrumScanPlan: Sendable {
    let primaryAddressId: UUID
    let targets: [BitcoinElectrumScanTarget]
}

private struct BitcoinWalletScanSnapshot: Sendable {
    let wallet: BitcoinWalletRow
    let addresses: [BitcoinWalletAddressRow]
}

private struct BitcoinWalletRow: Sendable {
    let id: UUID
    let kind: WalletKind
    let hasPassphrase: Bool

    static func fetchOne(_ db: Database, walletId: UUID) throws -> BitcoinWalletRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, kind_raw, has_passphrase
            FROM wallets
            WHERE id = ?
            LIMIT 1
            """,
            arguments: [walletId.uuidString]
        ), let id = UUID(uuidString: row["id"]) else {
            return nil
        }
        return BitcoinWalletRow(
            id: id,
            kind: WalletKind(rawValue: row["kind_raw"]) ?? .watchOnly,
            hasPassphrase: (row["has_passphrase"] as Int) != 0
        )
    }

    static func exists(_ db: Database, walletId: UUID) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM wallets WHERE id = ?",
            arguments: [walletId.uuidString]
        ) ?? 0
        return count > 0
    }
}

private struct BitcoinWalletAddressRow: Sendable {
    let id: UUID
    let address: String
    let derivationPath: String

    static func fetchAll(_ db: Database, walletId: UUID, chainRaw: String) throws -> [BitcoinWalletAddressRow] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, address, derivation_path
            FROM wallet_addresses
            WHERE wallet_id = ? AND chain_raw = ?
            ORDER BY is_receive_preferred DESC, last_scanned_at_ms ASC, address ASC
            """,
            arguments: [walletId.uuidString, chainRaw]
        ).compactMap { row in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return BitcoinWalletAddressRow(
                id: id,
                address: row["address"],
                derivationPath: row["derivation_path"]
            )
        }
    }
}

private struct BitcoinElectrumScanTarget: Sendable {
    let address: String
    let path: String
    let scriptHex: String
    let scriptHash: String

    init(address: String, path: String) throws {
        let script = BitcoinScript.lockScriptForAddress(address: address, coin: .bitcoin).data
        guard !script.isEmpty else { throw BitcoinElectrumError.invalidAddress(address) }
        let digest = SHA256.hash(data: script)
        self.address = address
        self.path = path
        self.scriptHex = script.apertureBitcoinHex
        self.scriptHash = Data(Data(digest).reversed()).apertureBitcoinHex
    }
}

private enum BitcoinAccountKind: CaseIterable, Sendable {
    case bip86
    case bip84
    case bip49
    case bip44

    var purpose: Purpose {
        switch self {
        case .bip86: return .bip86
        case .bip44: return .bip44
        case .bip49: return .bip49
        case .bip84: return .bip84
        }
    }

    var purposeNumber: Int {
        switch self {
        case .bip86: return 86
        case .bip44: return 44
        case .bip49: return 49
        case .bip84: return 84
        }
    }

    var publicVersion: HDVersion {
        switch self {
        case .bip86: return .xpub
        case .bip44: return .xpub
        case .bip49: return .ypub
        case .bip84: return .zpub
        }
    }

    static func fromExtendedPrivateVersion(_ version: UInt32) -> BitcoinAccountKind? {
        switch version {
        case 0x0488_ADE4: return .bip44
        case 0x049D_7878: return .bip49
        case 0x04B2_430C: return .bip84
        default: return nil
        }
    }
}

private enum BitcoinHDAddressDeriver {
    struct DerivedTarget: Sendable {
        let address: String
        let path: String
    }

    static func deriveFromMnemonic(
        _ words: [String],
        gapLimit: Int
    ) throws -> [DerivedTarget] {
        guard let wallet = HDWallet(
            mnemonic: words.joined(separator: " "),
            passphrase: ""
        ) else {
            throw BitcoinElectrumError.invalidMnemonic
        }

        var targets: [DerivedTarget] = []
        targets.reserveCapacity(BitcoinAccountKind.allCases.count * 2 * gapLimit)
        for kind in BitcoinAccountKind.allCases {
            let publicKey = wallet.getExtendedPublicKey(
                purpose: kind.purpose,
                coin: .bitcoin,
                version: kind.publicVersion
            )
            targets.append(contentsOf: try deriveFromExtendedPublicKey(
                publicKey,
                kind: kind,
                gapLimit: gapLimit
            ))
        }
        return targets
    }

    static func deriveFromMnemonic(
        _ words: [String],
        kind: BitcoinAccountKind,
        accountRange: ClosedRange<Int>,
        changeRange: ClosedRange<Int>,
        indexRange: ClosedRange<Int>
    ) throws -> [DerivedTarget] {
        guard let wallet = HDWallet(
            mnemonic: words.joined(separator: " "),
            passphrase: ""
        ) else {
            throw BitcoinElectrumError.invalidMnemonic
        }

        var targets: [DerivedTarget] = []
        targets.reserveCapacity(accountRange.count * changeRange.count * indexRange.count)
        for account in accountRange {
            for change in changeRange {
                for index in indexRange {
                    let path = "m/\(kind.purposeNumber)'/0'/\(account)'/\(change)/\(index)"
                    let privateKey = wallet.getKey(coin: .bitcoin, derivationPath: path)
                    let publicKey = privateKey.getPublicKeySecp256k1(compressed: true)
                    targets.append(DerivedTarget(
                        address: try address(publicKey: publicKey, kind: kind),
                        path: path
                    ))
                }
            }
        }
        return targets
    }

    static func deriveFromPrivateKeyInput(
        _ raw: String,
        gapLimit: Int
    ) throws -> [DerivedTarget] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extended = try? BitcoinExtendedPrivateKeyConverter.publicExtendedKey(from: trimmed) {
            return try deriveFromExtendedPublicKey(
                extended.publicKey,
                kind: extended.kind,
                gapLimit: gapLimit
            )
        }

        let keyData = try BitcoinPrivateKeyDecoder.decode(trimmed)
        guard let privateKey = PrivateKey(data: keyData) else {
            throw BitcoinElectrumError.invalidPrivateKey
        }
        let address = AnyAddress(
            publicKey: privateKey.getPublicKey(coinType: .bitcoin),
            coin: .bitcoin
        ).description
        guard !address.isEmpty else { throw BitcoinElectrumError.addressFailed }
        return [DerivedTarget(address: address, path: "imported-key")]
    }

    private static func deriveFromExtendedPublicKey(
        _ publicKey: String,
        kind: BitcoinAccountKind,
        gapLimit: Int
    ) throws -> [DerivedTarget] {
        var targets: [DerivedTarget] = []
        targets.reserveCapacity(2 * gapLimit)
        for change in UInt32(0)...UInt32(1) {
            for index in 0..<UInt32(gapLimit) {
                let path = DerivationPath(
                    purpose: kind.purpose,
                    coin: CoinType.bitcoin.slip44Id,
                    account: 0,
                    change: change,
                    address: index
                ).description
                guard let childPublicKey = HDWallet.getPublicKeyFromExtended(
                    extended: publicKey,
                    coin: .bitcoin,
                    derivationPath: path
                ) else {
                    throw BitcoinElectrumError.derivationFailed(path)
                }
                targets.append(DerivedTarget(
                    address: try address(publicKey: childPublicKey, kind: kind),
                    path: path
                ))
            }
        }
        return targets
    }

    private static func address(
        publicKey: PublicKey,
        kind: BitcoinAccountKind
    ) throws -> String {
        switch kind {
        case .bip86:
            return CoinType.bitcoin.deriveAddressFromPublicKeyAndDerivation(
                publicKey: publicKey,
                derivation: .bitcoinTaproot
            )
        case .bip44:
            guard let address = BitcoinAddress(
                publicKey: publicKey,
                prefix: CoinType.bitcoin.p2pkhPrefix
            ) else {
                throw BitcoinElectrumError.addressFailed
            }
            return address.description
        case .bip49:
            return BitcoinAddress.compatibleAddress(
                publicKey: publicKey,
                prefix: CoinType.bitcoin.p2shPrefix
            ).description
        case .bip84:
            return CoinType.bitcoin.deriveAddressFromPublicKey(publicKey: publicKey)
        }
    }
}

private enum BitcoinExtendedPrivateKeyConverter {
    private static let versionMap: [UInt32: UInt32] = [
        0x0488_ADE4: 0x0488_B21E,
        0x049D_7878: 0x049D_7CB2,
        0x04B2_430C: 0x04B2_4746
    ]

    static func publicExtendedKey(
        from privateExtendedKey: String
    ) throws -> (publicKey: String, kind: BitcoinAccountKind) {
        guard let payload = WalletCore.Base58.decode(string: privateExtendedKey),
              payload.count == 78 else {
            throw BitcoinElectrumError.invalidExtendedKey
        }
        let privateVersion = payload.apertureBitcoinUInt32BE(at: 0)
        guard let publicVersion = versionMap[privateVersion],
              let kind = BitcoinAccountKind.fromExtendedPrivateVersion(privateVersion) else {
            throw BitcoinElectrumError.unsupportedExtendedPrivateVersion(privateVersion)
        }

        let privateKeyPayload = payload.subdata(in: 45..<78)
        guard privateKeyPayload.count == 33, privateKeyPayload.first == 0 else {
            throw BitcoinElectrumError.invalidExtendedKey
        }
        guard let privateKey = PrivateKey(data: Data(privateKeyPayload.dropFirst())) else {
            throw BitcoinElectrumError.invalidPrivateKey
        }
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true).data
        guard publicKey.count == 33 else { throw BitcoinElectrumError.invalidPublicKey }

        var publicPayload = Data()
        publicPayload.append(publicVersion.apertureBitcoinBigEndianData)
        publicPayload.append(payload.subdata(in: 4..<45))
        publicPayload.append(publicKey)
        return (WalletCore.Base58.encode(data: publicPayload), kind)
    }
}

private enum BitcoinPrivateKeyDecoder {
    static func decode(_ raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X")
            ? String(trimmed.dropFirst(2))
            : trimmed
        if hex.count == 64,
           hex.allSatisfy(\.isHexDigit),
           let data = Data(apertureBitcoinHex: hex) {
            return try validate(data)
        }

        guard let payload = WalletCore.Base58.decode(string: trimmed) else {
            throw BitcoinElectrumError.invalidPrivateKey
        }
        let isUncompressedWIF = payload.count == 33
        let isCompressedWIF = payload.count == 34 && payload.last == 0x01
        guard payload.first == 0x80, isUncompressedWIF || isCompressedWIF else {
            throw BitcoinElectrumError.invalidPrivateKey
        }
        return try validate(Data(payload.dropFirst().prefix(32)))
    }

    private static func validate(_ keyData: Data) throws -> Data {
        guard keyData.count == 32,
              PrivateKey.isValid(data: keyData, curve: CoinType.bitcoin.curve) else {
            throw BitcoinElectrumError.invalidPrivateKey
        }
        return keyData
    }
}

private struct BitcoinElectrumServer: Sendable {
    let host: String
    let port: UInt16
    let tls: Bool

    static let defaults: [BitcoinElectrumServer] = [
        BitcoinElectrumServer(host: "fulcrum.grey.pw", port: 51002, tls: true),
        BitcoinElectrumServer(host: "electrum.blockstream.info", port: 50002, tls: true),
        BitcoinElectrumServer(host: "bitcoin.lu.ke", port: 50002, tls: true),
        BitcoinElectrumServer(host: "electrum.emzy.de", port: 50002, tls: true),
        BitcoinElectrumServer(host: "mainnet.foundationdevices.com", port: 50002, tls: true),
        BitcoinElectrumServer(host: "btc.lastingcoin.net", port: 50002, tls: true),
        BitcoinElectrumServer(host: "vmd71287.contaboserver.net", port: 50002, tls: true),
        BitcoinElectrumServer(host: "de.poiuty.com", port: 50002, tls: true),
        BitcoinElectrumServer(host: "electrum.jochen-hoenicke.de", port: 50006, tls: true),
        BitcoinElectrumServer(host: "btc.cr.ypto.tech", port: 50002, tls: true),
        BitcoinElectrumServer(host: "e.keff.org", port: 50002, tls: true),
        BitcoinElectrumServer(host: "vmd104014.contaboserver.net", port: 50002, tls: true),
        BitcoinElectrumServer(host: "e2.keff.org", port: 50002, tls: true),
        BitcoinElectrumServer(host: "fulcrum.sethforprivacy.com", port: 50002, tls: true),
        BitcoinElectrumServer(host: "electrum.coinext.com.br", port: 50002, tls: true)
    ]
}

private actor BitcoinElectrumClient {
    private let server: BitcoinElectrumServer
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Aperture.BitcoinElectrumClient")
    private var receiveBuffer = Data()
    private var nextID = 1
    private var pending: [Int: @Sendable (Result<BitcoinElectrumJSONValue, Error>) -> Void] = [:]

    var serverDescription: String {
        "\(server.host):\(server.port)"
    }

    private init(server: BitcoinElectrumServer) {
        self.server = server
        let parameters: NWParameters = server.tls ? .tls : .tcp
        self.connection = NWConnection(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: parameters
        )
    }

    static func scanFirst(
        servers: [BitcoinElectrumServer],
        targets: [BitcoinElectrumScanTarget],
        includeHistory: Bool
    ) async throws -> BitcoinElectrumLiveScanResult {
        var lastError: Error?
        for server in servers {
            do {
                let client = try await connect(to: server)
                defer { Task { await client.close() } }
                let scans = try await client.scan(targets: targets, includeHistory: includeHistory)
                return BitcoinElectrumLiveScanResult(
                    serverDescription: "\(server.host):\(server.port)",
                    scans: scans
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? BitcoinElectrumError.connectionFailed
    }

    static func connect(to server: BitcoinElectrumServer) async throws -> BitcoinElectrumClient {
        let client = BitcoinElectrumClient(server: server)
        do {
            try await client.connect()
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    func connect() async throws {
        let trace = await DiagnosticsAPIMonitor.shared.begin(
            family: "electrum",
            operation: "connect",
            metadata: electrumMetadata()
        )
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeBox = BitcoinElectrumContinuationBox()
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard resumeBox.resumeOnce() else { return }
                        continuation.resume()
                        Task { await self?.receiveLoop() }
                    case .failed(let error):
                        guard resumeBox.resumeOnce() else { return }
                        continuation.resume(throwing: error)
                    case .cancelled:
                        guard resumeBox.resumeOnce() else { return }
                        continuation.resume(throwing: BitcoinElectrumError.connectionFailed)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard resumeBox.resumeOnce() else { return }
                    connection.cancel()
                    continuation.resume(throwing: BitcoinElectrumError.requestTimedOut("connect(\(server.host):\(server.port))"))
                }
            }
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "succeeded")
        } catch is CancellationError {
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "cancelled", error: CancellationError())
            throw CancellationError()
        } catch {
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "failed", error: error)
            throw error
        }
        _ = try await request(
            method: "server.version",
            params: [.string("Aperture"), .string("1.4")]
        )
    }

    func close() {
        connection.cancel()
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(BitcoinElectrumError.connectionFailed))
        }
    }

    func scan(targets: [BitcoinElectrumScanTarget], includeHistory: Bool) async throws -> [BitcoinElectrumAddressScan] {
        guard !targets.isEmpty else { return [] }
        let unspentRequests = targets.map { target in
            BitcoinElectrumBatchRequestSpec(
                method: "blockchain.scripthash.listunspent",
                params: [.string(target.scriptHash)]
            )
        }
        let unspentResponses: [BitcoinElectrumBatchResponse]
        let historyResponses: [BitcoinElectrumBatchResponse]
        if includeHistory {
            let historyRequests = targets.map { target in
                BitcoinElectrumBatchRequestSpec(
                    method: "blockchain.scripthash.get_history",
                    params: [.string(target.scriptHash)]
                )
            }
            async let unspentResponsesTask = requestBatch(unspentRequests)
            async let historyResponsesTask = requestBatch(historyRequests)
            (unspentResponses, historyResponses) = try await (unspentResponsesTask, historyResponsesTask)
        } else {
            unspentResponses = try await requestBatch(unspentRequests)
            historyResponses = []
        }

        var scans: [BitcoinElectrumAddressScan] = []
        scans.reserveCapacity(targets.count)
        for index in targets.indices {
            let target = targets[index]
            guard case let .array(utxoItems) = unspentResponses[index].result else {
                throw BitcoinElectrumError.invalidResponse
            }
            let historyItems: [BitcoinElectrumJSONValue]
            if includeHistory {
                guard case let .array(items) = historyResponses[index].result else {
                    throw BitcoinElectrumError.invalidResponse
                }
                historyItems = items
            } else {
                historyItems = []
            }
            let utxoList = try utxoItems.map(BitcoinElectrumUTXO.init(json:))
            let historyList = try historyItems.map(BitcoinElectrumHistoryItem.init(json:))
            scans.append(BitcoinElectrumAddressScan(
                address: target.address,
                path: target.path,
                scriptHex: target.scriptHex,
                confirmedSats: BitcoinElectrumAddressScan.sum(utxos: utxoList.filter { $0.height > 0 }),
                unconfirmedSats: BitcoinElectrumAddressScan.sum(utxos: utxoList.filter { $0.height <= 0 }),
                utxos: utxoList,
                history: historyList,
                historyCount: historyList.count
            ))
        }
        return scans
    }

    private func request(method: String, params: [BitcoinElectrumJSONValue]) async throws -> BitcoinElectrumJSONValue {
        let id = nextID
        nextID += 1
        let request = BitcoinElectrumJSONRequest(id: id, method: method, params: params)
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)

        var metadata = electrumMetadata()
        metadata["requestId"] = "\(id)"
        let trace = await DiagnosticsAPIMonitor.shared.begin(
            family: "electrum",
            operation: method,
            metadata: metadata
        )
        do {
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BitcoinElectrumJSONValue, Error>) in
                pending[id] = { result in
                    continuation.resume(with: result)
                }
                connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    guard let error else { return }
                    Task { await self?.resume(id: id, throwing: error) }
                })
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    await self?.resume(id: id, throwing: BitcoinElectrumError.requestTimedOut(method))
                }
            }
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "succeeded")
            return value
        } catch is CancellationError {
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "cancelled", error: CancellationError())
            throw CancellationError()
        } catch {
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "failed", error: error)
            throw error
        }
    }

    private func requestBatch(_ specs: [BitcoinElectrumBatchRequestSpec]) async throws -> [BitcoinElectrumBatchResponse] {
        guard !specs.isEmpty else { return [] }

        var requests: [BitcoinElectrumPendingBatchRequest] = []
        var wireRequests: [BitcoinElectrumJSONRequest] = []
        requests.reserveCapacity(specs.count)
        wireRequests.reserveCapacity(specs.count)
        for spec in specs {
            let id = nextID
            nextID += 1
            wireRequests.append(BitcoinElectrumJSONRequest(id: id, method: spec.method, params: spec.params))
            requests.append(BitcoinElectrumPendingBatchRequest(id: id, spec: spec))
        }
        var payload = try JSONEncoder().encode(wireRequests)
        payload.append(0x0A)

        let ids = requests.map(\.id)
        let batchBox = BitcoinElectrumBatchResponseBox(ids: ids)
        for id in ids {
            pending[id] = { result in
                batchBox.complete(id: id, result: result)
            }
        }

        var metadata = electrumMetadata()
        metadata["requestCount"] = "\(specs.count)"
        metadata["method"] = specs.first?.method ?? "batch"
        let trace = await DiagnosticsAPIMonitor.shared.begin(
            family: "electrum",
            operation: specs.first?.method ?? "batch",
            metadata: metadata
        )
        do {
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.fail(ids: ids, error: error) }
            })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.fail(ids: ids, error: BitcoinElectrumError.requestTimedOut("batch(\(specs.count))"))
            }

            let results = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Int: BitcoinElectrumJSONValue], Error>) in
                batchBox.wait(continuation)
            }
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "succeeded")
            return try requests.map { request in
                guard let result = results[request.id] else {
                    throw BitcoinElectrumError.invalidResponse
                }
                return BitcoinElectrumBatchResponse(id: request.id, result: result)
            }
        } catch is CancellationError {
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "cancelled", error: CancellationError())
            throw CancellationError()
        } catch {
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "failed", error: error)
            throw error
        }
    }

    private func electrumMetadata() -> [String: String] {
        [
            "chain": "bitcoin",
            "host": server.host,
            "port": "\(server.port)",
            "tls": "\(server.tls)",
            "source": "BitcoinElectrumClient"
        ]
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] content, _, isComplete, error in
            Task {
                if let content, !content.isEmpty {
                    await self?.handleReceived(content)
                }
                if let error {
                    await self?.failAll(error)
                    return
                }
                if isComplete {
                    await self?.failAll(BitcoinElectrumError.connectionFailed)
                    return
                }
                await self?.receiveLoop()
            }
        }
    }

    private func handleReceived(_ content: Data) {
        receiveBuffer.append(content)
        let newline = Data([0x0A])
        while let range = receiveBuffer.range(of: newline) {
            let line = receiveBuffer.subdata(in: receiveBuffer.startIndex..<range.lowerBound)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<range.upperBound)
            guard !line.isEmpty else { continue }
            do {
                if line.first == 0x5B {
                    let responses = try JSONDecoder().decode([BitcoinElectrumJSONResponse].self, from: line)
                    for response in responses { handle(response) }
                } else {
                    let response = try JSONDecoder().decode(BitcoinElectrumJSONResponse.self, from: line)
                    handle(response)
                }
            } catch {
                failAll(error)
            }
        }
    }

    private func handle(_ response: BitcoinElectrumJSONResponse) {
        guard let id = response.id else { return }
        if let error = response.error {
            resume(id: id, throwing: BitcoinElectrumError.rpcError(error.message))
        } else if let result = response.result {
            resume(id: id, returning: result)
        } else {
            resume(id: id, throwing: BitcoinElectrumError.invalidResponse)
        }
    }

    private func resume(id: Int, returning value: BitcoinElectrumJSONValue) {
        pending.removeValue(forKey: id)?(.success(value))
    }

    private func resume(id: Int, throwing error: Error) {
        pending.removeValue(forKey: id)?(.failure(error))
    }

    private func fail(ids: [Int], error: Error) {
        for id in ids {
            pending.removeValue(forKey: id)?(.failure(error))
        }
    }

    private func failAll(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(error))
        }
    }
}

private struct BitcoinElectrumBatchRequestSpec: Sendable {
    let method: String
    let params: [BitcoinElectrumJSONValue]
}

private struct BitcoinElectrumPendingBatchRequest: Sendable {
    let id: Int
    let spec: BitcoinElectrumBatchRequestSpec
}

private struct BitcoinElectrumBatchResponse: Sendable {
    let id: Int
    let result: BitcoinElectrumJSONValue
}

private final class BitcoinElectrumBatchResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<Int>
    private var results: [Int: BitcoinElectrumJSONValue] = [:]
    private var continuation: CheckedContinuation<[Int: BitcoinElectrumJSONValue], Error>?
    private var completion: Result<[Int: BitcoinElectrumJSONValue], Error>?

    init(ids: [Int]) {
        self.remaining = Set(ids)
    }

    func wait(_ continuation: CheckedContinuation<[Int: BitcoinElectrumJSONValue], Error>) {
        lock.lock()
        if let completion {
            lock.unlock()
            continuation.resume(with: completion)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func complete(id: Int, result: Result<BitcoinElectrumJSONValue, Error>) {
        lock.lock()
        if completion != nil {
            lock.unlock()
            return
        }

        switch result {
        case .success(let value):
            results[id] = value
            remaining.remove(id)
            guard remaining.isEmpty else {
                lock.unlock()
                return
            }
            completion = .success(results)
        case .failure(let error):
            completion = .failure(error)
        }

        let continuation = self.continuation
        let completion = self.completion
        self.continuation = nil
        lock.unlock()

        if let completion {
            continuation?.resume(with: completion)
        }
    }
}

private struct BitcoinElectrumAddressScan: Sendable {
    let address: String
    let path: String
    let scriptHex: String
    let confirmedSats: Int64
    let unconfirmedSats: Int64
    let utxos: [BitcoinElectrumUTXO]
    let history: [BitcoinElectrumHistoryItem]
    let historyCount: Int

    var totalSats: Int64 {
        let (sum, overflow) = confirmedSats.addingReportingOverflow(unconfirmedSats)
        return overflow ? Int64.max : sum
    }

    var hasActivity: Bool {
        totalSats > 0 || historyCount > 0 || !utxos.isEmpty
    }

    static func sum(utxos: [BitcoinElectrumUTXO]) -> Int64 {
        utxos.reduce(Int64(0)) { partial, utxo in
            let (sum, overflow) = partial.addingReportingOverflow(utxo.valueSats)
            return overflow ? Int64.max : sum
        }
    }
}

private struct BitcoinElectrumLiveScanResult: Sendable {
    let serverDescription: String
    let scans: [BitcoinElectrumAddressScan]
}

private struct BitcoinElectrumUTXO: Sendable {
    let txHash: String
    let txPosition: Int
    let height: Int
    let valueSats: Int64

    init(json: BitcoinElectrumJSONValue) throws {
        guard case let .object(object) = json,
              let txHash = object["tx_hash"]?.stringValue,
              let txPosition = object["tx_pos"]?.intValue,
              let height = object["height"]?.intValue,
              let valueSats = object["value"]?.int64Value else {
            throw BitcoinElectrumError.invalidResponse
        }
        self.txHash = txHash
        self.txPosition = txPosition
        self.height = height
        self.valueSats = valueSats
    }
}

private struct BitcoinElectrumHistoryItem: Sendable {
    let txHash: String
    let height: Int

    init(json: BitcoinElectrumJSONValue) throws {
        guard case let .object(object) = json,
              let txHash = object["tx_hash"]?.stringValue,
              let height = object["height"]?.intValue else {
            throw BitcoinElectrumError.invalidResponse
        }
        self.txHash = txHash
        self.height = height
    }
}

private struct BitcoinElectrumTransactionEvent: Sendable {
    let txHash: String
    let direction: TransactionDirection
    let amount: String
    let blockNumber: Int64?
    let occurredAt: Date
    let status: TransactionStatus
    let counterparty: String
    let fee: String?

    init?(
        object: [String: Any],
        txHash: String,
        ownAddresses: Set<String>,
        fallbackHeight: Int?
    ) {
        let vin = object["vin"] as? [[String: Any]] ?? []
        let vout = object["vout"] as? [[String: Any]] ?? []
        let inputRows = vin.compactMap { BitcoinElectrumAddressValue.input($0) }
        let outputRows = vout.compactMap { BitcoinElectrumAddressValue.output($0) }
        let spent = Self.sum(inputRows.filter { ownAddresses.contains($0.address) }.map(\.value))
        let received = Self.sum(outputRows.filter { ownAddresses.contains($0.address) }.map(\.value))
        let feeSats = Self.int64(object["fee"])

        let direction: TransactionDirection
        let amountSats: Int64
        let counterparty: String
        if spent == 0, received > 0 {
            direction = .incoming
            amountSats = received
            counterparty = inputRows.first { !ownAddresses.contains($0.address) }?.address ?? ""
        } else if spent > 0 {
            let externalSent = max(0, spent - received - max(0, feeSats))
            if externalSent > 0 {
                direction = .outgoing
                amountSats = externalSent
                counterparty = outputRows.first { !ownAddresses.contains($0.address) }?.address ?? ""
            } else if received > 0 {
                direction = .internal
                amountSats = received
                counterparty = ""
            } else {
                direction = .outgoing
                amountSats = max(0, spent - max(0, feeSats))
                counterparty = outputRows.first { !ownAddresses.contains($0.address) }?.address ?? ""
            }
        } else {
            return nil
        }
        guard amountSats > 0 else { return nil }

        let statusObject = object["status"] as? [String: Any] ?? [:]
        let confirmed = statusObject["confirmed"] as? Bool ?? false
        let blockHeight = Self.int64(statusObject["block_height"])
        let fallbackBlockHeight = Int64(fallbackHeight ?? 0)
        let blockTime = Self.int64(statusObject["block_time"])
        let occurredAt = blockTime > 0 ? Date(timeIntervalSince1970: TimeInterval(blockTime)) : Date()

        self.txHash = txHash
        self.direction = direction
        self.amount = Self.display(raw: amountSats)
        self.blockNumber = blockHeight > 0 ? blockHeight : (fallbackBlockHeight > 0 ? Optional(fallbackBlockHeight) : nil)
        self.occurredAt = occurredAt
        self.status = confirmed ? .confirmed : .pending
        self.counterparty = counterparty
        self.fee = spent > 0 && feeSats > 0 ? Self.display(raw: feeSats) : nil
    }

    private static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }

    private static func display(raw: Int64) -> String {
        EVMHexQuantity.displayAmount(rawBalance: String(raw), decimals: SupportedChain.bitcoin.nativeDecimals)
            ?? EVMHexQuantity.decimalAmount(rawBalance: String(raw), decimals: SupportedChain.bitcoin.nativeDecimals)
                .map { NSDecimalNumber(decimal: $0).stringValue }
            ?? "0"
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string) ?? 0
        default:
            return 0
        }
    }
}

private struct BitcoinElectrumAddressValue {
    let address: String
    let value: Int64

    static func input(_ object: [String: Any]) -> BitcoinElectrumAddressValue? {
        guard let prevout = object["prevout"] as? [String: Any] else { return nil }
        return output(prevout)
    }

    static func output(_ object: [String: Any]) -> BitcoinElectrumAddressValue? {
        guard let address = object["scriptpubkey_address"] as? String else { return nil }
        let value = int64(object["value"])
        guard value > 0 else { return nil }
        return BitcoinElectrumAddressValue(address: address, value: value)
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string) ?? 0
        default:
            return 0
        }
    }
}

private struct BitcoinElectrumJSONRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [BitcoinElectrumJSONValue]
}

private struct BitcoinElectrumJSONResponse: Decodable {
    let id: Int?
    let result: BitcoinElectrumJSONValue?
    let error: BitcoinElectrumJSONError?
}

private struct BitcoinElectrumJSONError: Decodable {
    let code: Int?
    let message: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let message = try? container.decode(String.self) {
            self.code = nil
            self.message = message
            return
        }

        if let object = try? container.decode([String: BitcoinElectrumJSONValue].self) {
            self.code = object["code"]?.intValue
            self.message = object["message"]?.stringValue
                ?? object["error"]?.stringValue
                ?? "\(object)"
            return
        }

        if let value = try? container.decode(BitcoinElectrumJSONValue.self) {
            self.code = nil
            self.message = "\(value)"
            return
        }

        throw BitcoinElectrumError.invalidResponse
    }
}

private enum BitcoinElectrumJSONValue: Codable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case object([String: BitcoinElectrumJSONValue])
    case array([BitcoinElectrumJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: BitcoinElectrumJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([BitcoinElectrumJSONValue].self) {
            self = .array(value)
        } else {
            throw BitcoinElectrumError.invalidResponse
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if let value = int64Value { return Int(value) }
        return nil
    }

    var int64Value: Int64? {
        switch self {
        case .integer(let value):
            return value
        case .double(let value):
            return Int64(value)
        default:
            return nil
        }
    }
}

private enum BitcoinElectrumError: Error, CustomStringConvertible {
    case invalidMnemonic
    case invalidExtendedKey
    case unsupportedExtendedPrivateVersion(UInt32)
    case invalidPrivateKey
    case invalidPublicKey
    case derivationFailed(String)
    case addressFailed
    case invalidAddress(String)
    case connectionFailed
    case requestTimedOut(String)
    case rpcError(String)
    case invalidResponse

    var description: String {
        switch self {
        case .invalidMnemonic:
            return "Invalid Bitcoin mnemonic"
        case .invalidExtendedKey:
            return "Invalid Bitcoin extended key"
        case .unsupportedExtendedPrivateVersion(let version):
            return "Unsupported Bitcoin extended private-key version: \(String(format: "0x%08x", version))"
        case .invalidPrivateKey:
            return "Invalid Bitcoin private key"
        case .invalidPublicKey:
            return "Invalid Bitcoin public key"
        case .derivationFailed(let path):
            return "Bitcoin derivation failed for \(path)"
        case .addressFailed:
            return "Bitcoin address derivation failed"
        case .invalidAddress(let address):
            return "Invalid Bitcoin address: \(address)"
        case .connectionFailed:
            return "Bitcoin Electrum connection failed"
        case .requestTimedOut(let method):
            return "Bitcoin Electrum request timed out: \(method)"
        case .rpcError(let message):
            return "Bitcoin Electrum RPC error: \(message)"
        case .invalidResponse:
            return "Invalid Bitcoin Electrum response"
        }
    }
}

private final class BitcoinElectrumContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private extension Data {
    var apertureBitcoinHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(apertureBitcoinHex hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }

    func apertureBitcoinUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}

private extension UInt32 {
    var apertureBitcoinBigEndianData: Data {
        Data([
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ])
    }
}
