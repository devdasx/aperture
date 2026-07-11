import Foundation
import GRDB
import Network
import OSLog
import WalletCore

/// Single store of truth for Bitcoin Cash UTXOs: the same Electrum
/// `blockchain.address.listunspent` path used by
/// `BitcoinCashElectrumBalanceScanner`. Compose/sign must call this instead
/// of Haskoin REST so balance and coin selection never diverge.
enum BitcoinCashElectrumUTXOSource {
    /// Batch listunspent for every address (one Electrum connection).
    static func fetchUTXOs(addresses: [String]) async throws -> [SelectedUTXO] {
        var seen = Set<String>()
        let unique = addresses.compactMap { raw -> String? in
            let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, seen.insert(address).inserted else { return nil }
            return address
        }
        guard !unique.isEmpty else { return [] }

        let targets = try unique.map {
            try BitcoinCashElectrumScanTarget(address: $0, path: "")
        }
        let result = try await BitcoinCashElectrumClient.scanFirst(
            servers: BitcoinCashElectrumServer.defaults,
            targets: targets,
            includeHistory: false
        )
        return result.scans.flatMap { scan in
            scan.utxos.map { utxo in
                SelectedUTXO(
                    ownerAddress: scan.address,
                    txid: utxo.txHash,
                    vout: utxo.txPosition,
                    valueSats: utxo.valueSats,
                    scriptHex: scan.scriptHex,
                    confirmed: utxo.height > 0
                )
            }
        }
    }
}

actor BitcoinCashElectrumBalanceScanner {
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "bitcoin-cash-electrum")
    private let client = RPCClient.shared

    /// BUG-010: mirrors `BitcoinElectrumBalanceScanner` — balance/UTXOs plus
    /// Electrum history hashes normalized via Haskoin REST and persisted with
    /// `upsertTransaction` when `includeHistory` is true.
    func scanAndPersist(
        walletId: UUID,
        currencyCode: String,
        database: AppDatabase,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        let targetRepository = BitcoinCashWalletScanTargetRepository(database: database)
        let plan = try await targetRepository.scanPlan(walletId: walletId)
        guard let plan, !plan.targets.isEmpty else { return }

        async let prices: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: [SupportedChain.bitcoinCash.ticker],
                currencyCode: currencyCode
            )
            : [:]
        async let liveScan = BitcoinCashElectrumClient.scanFirst(
            servers: BitcoinCashElectrumServer.defaults,
            targets: plan.targets,
            includeHistory: includeHistory
        )

        let (priceMap, result) = try await (prices, liveScan)
        let scans = result.scans
        let totalSats = scans.reduce(Int64(0)) { partial, scan in
            let (sum, overflow) = partial.addingReportingOverflow(scan.totalSats)
            return overflow ? Int64.max : sum
        }
        let isUsed = totalSats > 0 || scans.contains { $0.historyCount > 0 }
        let fiat = fiatValue(sats: totalSats, prices: priceMap)

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: plan.primaryAddressId,
            tokenSymbol: SupportedChain.bitcoinCash.ticker,
            tokenContract: nil,
            decimals: SupportedChain.bitcoinCash.nativeDecimals,
            rawBalance: String(totalSats),
            fiatValueCached: fiat,
            fiatCurrencyCode: currencyCode,
            save: false
        )
        // BUG-010: persist activity rows so BCH Activity is not empty.
        if includeHistory {
            let history = await safeRecentEvents(scans: scans)
            for event in history.prefix(50) {
                try txRepo.upsertTransaction(
                    addressId: plan.primaryAddressId,
                    txHash: event.txHash,
                    direction: event.direction,
                    amountRaw: event.amount,
                    tokenSymbol: SupportedChain.bitcoinCash.ticker,
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

        // BUG-016: persist every scanned BCH path (quiet + active).
        let chainRepo = ChainStateRepository(database: database)
        _ = try chainRepo.upsertDiscoveredAddresses(
            walletId: walletId,
            chain: .bitcoinCash,
            addresses: scans.map {
                .init(address: $0.address, derivationPath: $0.path, isUsed: $0.historyCount > 0 || $0.totalSats > 0)
            }
        )
        let words = try? WalletSecretPersistence.loadMnemonic(for: walletId, database: database)
        let active = Set(scans.filter { $0.historyCount > 0 || $0.totalSats > 0 }.map(\.address))
        var extensionTargets = (try? BitcoinFamilyAddressBook.markUsedAndExtendIfNeeded(
            walletId: walletId,
            chain: .bitcoinCash,
            activeAddresses: active,
            words: words,
            database: database
        )) ?? []

        var allScans = scans
        var loopGuard = 0
        while !extensionTargets.isEmpty, loopGuard < 10 {
            loopGuard += 1
            let electrumTargets: [BitcoinCashElectrumScanTarget] = extensionTargets.compactMap { item in
                try? BitcoinCashElectrumScanTarget(address: item.address, path: item.path)
            }
            guard !electrumTargets.isEmpty else { break }
            guard let ext = try? await BitcoinCashElectrumClient.scanFirst(
                servers: BitcoinCashElectrumServer.defaults,
                targets: electrumTargets,
                includeHistory: includeHistory
            ) else { break }
            allScans.append(contentsOf: ext.scans)
            _ = try? chainRepo.upsertDiscoveredAddresses(
                walletId: walletId,
                chain: .bitcoinCash,
                addresses: ext.scans.map {
                    .init(
                        address: $0.address,
                        derivationPath: $0.path,
                        isUsed: $0.historyCount > 0 || $0.totalSats > 0
                    )
                }
            )
            let extActive = Set(ext.scans.filter { $0.historyCount > 0 || $0.totalSats > 0 }.map(\.address))
            extensionTargets = (try? BitcoinFamilyAddressBook.markUsedAndExtendIfNeeded(
                walletId: walletId,
                chain: .bitcoinCash,
                activeAddresses: extActive,
                words: words,
                database: database
            )) ?? []
            let scannedSet = Set(ext.scans.map(\.address))
            extensionTargets = extensionTargets.filter { !scannedSet.contains($0.address) }
        }

        let totalSatsAll = allScans.reduce(Int64(0)) { partial, scan in
            let (sum, overflow) = partial.addingReportingOverflow(scan.totalSats)
            return overflow ? Int64.max : sum
        }
        if totalSatsAll != totalSats {
            let fiatAll = fiatValue(sats: totalSatsAll, prices: priceMap)
            try txRepo.upsertBalance(
                addressId: plan.primaryAddressId,
                tokenSymbol: SupportedChain.bitcoinCash.ticker,
                tokenContract: nil,
                decimals: SupportedChain.bitcoinCash.nativeDecimals,
                rawBalance: String(totalSatsAll),
                fiatValueCached: fiatAll,
                fiatCurrencyCode: currencyCode,
                save: false
            )
            try txRepo.flush()
        }

        let utxos = allScans.flatMap { scan in
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
            chain: .bitcoinCash,
            utxos: utxos
        )
        _ = try chainRepo.rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: [.bitcoinCash],
            failedChains: [],
            interim: false
        )

        log.debug(
            "Bitcoin Cash Electrum scan succeeded via \(result.serverDescription, privacy: .public): \(allScans.count, privacy: .public) addresses, \(utxos.count, privacy: .public) utxos, history=\(includeHistory, privacy: .public)"
        )
    }

    private func safeRecentEvents(scans: [BitcoinCashElectrumAddressScan]) async -> [BitcoinCashHistoryEvent] {
        do {
            return try await recentEvents(scans: scans)
        } catch {
            log.debug("Bitcoin Cash history normalization failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Electrum `get_history` → Haskoin `bch/transaction/{txid}` detail,
    /// same shape `TransactionDetailService.bitcoinHaskoin` already uses.
    private func recentEvents(scans: [BitcoinCashElectrumAddressScan]) async throws -> [BitcoinCashHistoryEvent] {
        let ownAddresses = Set(scans.map { BitcoinCashHistorySupport.normalizeAddress($0.address) })
        guard !ownAddresses.isEmpty else { return [] }

        var heightsByHash: [String: Int] = [:]
        for scan in scans {
            for item in scan.history {
                heightsByHash[item.txHash] = item.height
            }
        }
        guard !heightsByHash.isEmpty else { return [] }

        // Newest heights first (mempool height 0 / -1 last among ties).
        let txHashes = heightsByHash
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(50)
            .map(\.key)

        var events: [BitcoinCashHistoryEvent] = []
        events.reserveCapacity(txHashes.count)
        await withTaskGroup(of: BitcoinCashHistoryEvent?.self) { group in
            for txHash in txHashes {
                let fallbackHeight = heightsByHash[txHash]
                group.addTask { [client] in
                    guard
                        let data = try? await client.callREST(
                            chain: .bitcoinCash,
                            path: "bch/transaction/\(txHash)"
                        ),
                        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    else {
                        return nil
                    }
                    return BitcoinCashHistorySupport.event(
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
        guard let price = prices[SupportedChain.bitcoinCash.ticker] else { return nil }
        guard let amount = EVMHexQuantity.decimalAmount(
            rawBalance: String(sats),
            decimals: SupportedChain.bitcoinCash.nativeDecimals
        ) else { return nil }
        return amount * price.amount
    }
}

// MARK: - BUG-010 history normalization (testable, Haskoin-shaped)

/// Pure helpers for BCH cashaddr matching + Haskoin tx → activity event.
/// Kept internal (not `private`) so unit tests can pin real mainnet fixtures.
enum BitcoinCashHistorySupport {
    struct Event: Sendable, Equatable {
        let txHash: String
        let direction: TransactionDirection
        let amount: String
        let blockNumber: Int64?
        let occurredAt: Date
        let status: TransactionStatus
        let counterparty: String
        let fee: String?
    }

    /// Cashaddr compare key: strip `bitcoincash:` prefix, lowercased.
    static func normalizeAddress(_ address: String) -> String {
        address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "bitcoincash:", with: "", options: .caseInsensitive)
            .lowercased()
    }

    static func normalizeAddressSet(_ addresses: [String]) -> Set<String> {
        Set(addresses.map(normalizeAddress).filter { !$0.isEmpty })
    }

    /// Parse a Haskoin `GET /bch/transaction/{txid}` JSON object into an
    /// activity event relative to `ownAddresses` (already normalized).
    static func event(
        object: [String: Any],
        txHash: String,
        ownAddresses: Set<String>,
        fallbackHeight: Int?
    ) -> Event? {
        let inputs = object["inputs"] as? [[String: Any]] ?? []
        let outputs = object["outputs"] as? [[String: Any]] ?? []
        let inputRows = inputs.compactMap(addressValue(fromHaskoinIO:))
        let outputRows = outputs.compactMap(addressValue(fromHaskoinIO:))

        let spent = sum(inputRows.filter { ownAddresses.contains($0.normalized) }.map(\.value))
        let received = sum(outputRows.filter { ownAddresses.contains($0.normalized) }.map(\.value))
        let feeSats = int64(object["fee"])

        let direction: TransactionDirection
        let amountSats: Int64
        let counterparty: String
        if spent == 0, received > 0 {
            direction = .incoming
            amountSats = received
            counterparty = inputRows.first { !ownAddresses.contains($0.normalized) }?.display ?? ""
        } else if spent > 0 {
            let externalSent = max(0, spent - received - max(0, feeSats))
            if externalSent > 0 {
                direction = .outgoing
                amountSats = externalSent
                counterparty = outputRows.first { !ownAddresses.contains($0.normalized) }?.display ?? ""
            } else if received > 0 {
                direction = .internal
                amountSats = received
                counterparty = ""
            } else {
                direction = .outgoing
                amountSats = max(0, spent - max(0, feeSats))
                counterparty = outputRows.first { !ownAddresses.contains($0.normalized) }?.display ?? ""
            }
        } else {
            return nil
        }
        guard amountSats > 0 else { return nil }

        let blockObj = object["block"] as? [String: Any] ?? [:]
        // Haskoin uses height == -1 for mempool; only positive is confirmed.
        let blockHeightRaw = int64(blockObj["height"])
        let blockHeight: Int64? = blockHeightRaw > 0 ? blockHeightRaw : nil
        let fallbackBlockHeight = Int64(fallbackHeight ?? 0)
        let confirmed = blockHeight != nil
        let blockTime = int64(object["time"])
        let occurredAt = blockTime > 0
            ? Date(timeIntervalSince1970: TimeInterval(blockTime))
            : Date()

        return Event(
            txHash: txHash,
            direction: direction,
            amount: display(raw: amountSats),
            blockNumber: blockHeight ?? (fallbackBlockHeight > 0 ? fallbackBlockHeight : nil),
            occurredAt: occurredAt,
            status: confirmed ? .confirmed : .pending,
            counterparty: counterparty,
            fee: spent > 0 && feeSats > 0 ? display(raw: feeSats) : nil
        )
    }

    private struct AddressValue {
        /// Normalized key used for own-wallet matching.
        let normalized: String
        /// Original cashaddr (usually with `bitcoincash:` prefix) for UI.
        let display: String
        let value: Int64
    }

    private static func addressValue(fromHaskoinIO object: [String: Any]) -> AddressValue? {
        guard let rawAddress = object["address"] as? String else { return nil }
        let normalized = normalizeAddress(rawAddress)
        guard !normalized.isEmpty else { return nil }
        let value = int64(object["value"])
        guard value > 0 else { return nil }
        return AddressValue(normalized: normalized, display: rawAddress, value: value)
    }

    private static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }

    private static func display(raw: Int64) -> String {
        EVMHexQuantity.displayAmount(
            rawBalance: String(raw),
            decimals: SupportedChain.bitcoinCash.nativeDecimals
        )
            ?? EVMHexQuantity.decimalAmount(
                rawBalance: String(raw),
                decimals: SupportedChain.bitcoinCash.nativeDecimals
            ).map { NSDecimalNumber(decimal: $0).stringValue }
            ?? "0"
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string) ?? 0
        case let int as Int:
            return Int64(int)
        case let int64 as Int64:
            return int64
        default:
            return 0
        }
    }
}

typealias BitcoinCashHistoryEvent = BitcoinCashHistorySupport.Event

private actor BitcoinCashWalletScanTargetRepository {
    private let gapLimit = BitcoinFamilyAddressBook.gapLimit
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func scanPlan(walletId: UUID) throws -> BitcoinCashElectrumScanPlan? {
        let chainRaw = SupportedChain.bitcoinCash.rawValue
        let snapshot = try database.read { db -> BitcoinCashWalletScanSnapshot? in
            guard let wallet = try BitcoinCashWalletRow.fetchOne(db, walletId: walletId) else { return nil }
            let addresses = try BitcoinCashWalletAddressRow.fetchAll(db, walletId: walletId, chainRaw: chainRaw)
            guard !addresses.isEmpty else { return nil }
            return BitcoinCashWalletScanSnapshot(wallet: wallet, addresses: addresses)
        }
        guard let snapshot else { return nil }
        let wallet = snapshot.wallet
        let addresses = snapshot.addresses
        guard let primary = addresses.first else { return nil }

        var targets: [BitcoinCashElectrumScanTarget] = []
        func append(address: String, path: String) {
            guard !targets.contains(where: { $0.address == address }),
                  let target = try? BitcoinCashElectrumScanTarget(address: address, path: path) else {
                return
            }
            targets.append(target)
        }
        for address in addresses {
            append(address: address.address, path: address.derivationPath)
        }

        switch wallet.kind {
        case .created, .importedMnemonic:
            if !wallet.hasPassphrase,
               let words = loadMnemonic(walletId: wallet.id) {
                _ = try? BitcoinFamilyAddressBook.ensureGapCoverage(
                    walletId: walletId,
                    chain: .bitcoinCash,
                    words: words,
                    database: database
                )
                if let persisted = try? BitcoinFamilyAddressBook.persistedAddresses(
                    walletId: walletId,
                    chain: .bitcoinCash,
                    database: database
                ) {
                    for item in persisted {
                        append(address: item.address, path: item.path)
                    }
                }
            }
        case .importedKey:
            if let keyString = loadPrivateKey(walletId: wallet.id),
               let target = try? BitcoinCashHDAddressDeriver.deriveFromPrivateKeyInput(keyString) {
                append(address: target.address, path: target.path)
            }
        case .watchOnly:
            break
        }

        guard !targets.isEmpty else { return nil }
        return BitcoinCashElectrumScanPlan(
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

private struct BitcoinCashElectrumScanPlan: Sendable {
    let primaryAddressId: UUID
    let targets: [BitcoinCashElectrumScanTarget]
}

private struct BitcoinCashWalletScanSnapshot: Sendable {
    let wallet: BitcoinCashWalletRow
    let addresses: [BitcoinCashWalletAddressRow]
}

private struct BitcoinCashWalletRow: Sendable {
    let id: UUID
    let kind: WalletKind
    let hasPassphrase: Bool

    static func fetchOne(_ db: Database, walletId: UUID) throws -> BitcoinCashWalletRow? {
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
        return BitcoinCashWalletRow(
            id: id,
            kind: WalletKind(rawValue: row["kind_raw"]) ?? .watchOnly,
            hasPassphrase: (row["has_passphrase"] as Int) != 0
        )
    }
}

private struct BitcoinCashWalletAddressRow: Sendable {
    let id: UUID
    let address: String
    let derivationPath: String

    static func fetchAll(_ db: Database, walletId: UUID, chainRaw: String) throws -> [BitcoinCashWalletAddressRow] {
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
            return BitcoinCashWalletAddressRow(
                id: id,
                address: row["address"],
                derivationPath: row["derivation_path"]
            )
        }
    }
}

private struct BitcoinCashElectrumScanTarget: Sendable {
    let address: String
    let electrumAddress: String
    let path: String
    let scriptHex: String

    init(address: String, path: String) throws {
        let script = BitcoinScript.lockScriptForAddress(address: address, coin: .bitcoinCash).data
        guard !script.isEmpty else { throw BitcoinCashElectrumError.invalidAddress(address) }
        self.address = address
        self.electrumAddress = address.replacingOccurrences(of: "bitcoincash:", with: "")
        self.path = path
        self.scriptHex = script.apertureBCHHex
    }
}

private enum BitcoinCashHDAddressDeriver {
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
            throw BitcoinCashElectrumError.invalidMnemonic
        }

        var targets: [DerivedTarget] = []
        targets.reserveCapacity(2 * gapLimit)
        for change in UInt32(0)...UInt32(1) {
            for index in 0..<UInt32(gapLimit) {
                let path = "m/44'/145'/0'/\(change)/\(index)"
                let privateKey = wallet.getKey(coin: .bitcoinCash, derivationPath: path)
                let address = CoinType.bitcoinCash.deriveAddress(privateKey: privateKey)
                guard !address.isEmpty else {
                    throw BitcoinCashElectrumError.derivationFailed(path)
                }
                targets.append(DerivedTarget(address: address, path: path))
            }
        }
        return targets
    }

    static func deriveFromPrivateKeyInput(_ raw: String) throws -> DerivedTarget {
        let keyData = try BitcoinCashPrivateKeyDecoder.decode(raw)
        guard let privateKey = PrivateKey(data: keyData) else {
            throw BitcoinCashElectrumError.invalidPrivateKey
        }
        let address = CoinType.bitcoinCash.deriveAddress(privateKey: privateKey)
        guard !address.isEmpty else { throw BitcoinCashElectrumError.addressFailed }
        return DerivedTarget(address: address, path: "imported-key")
    }
}

private enum BitcoinCashPrivateKeyDecoder {
    static func decode(_ raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X")
            ? String(trimmed.dropFirst(2))
            : trimmed
        if hex.count == 64,
           hex.allSatisfy(\.isHexDigit),
           let data = Data(apertureBCHHex: hex) {
            return try validate(data)
        }

        guard let payload = WalletCore.Base58.decode(string: trimmed) else {
            throw BitcoinCashElectrumError.invalidPrivateKey
        }
        let isUncompressedWIF = payload.count == 33
        let isCompressedWIF = payload.count == 34 && payload.last == 0x01
        guard payload.first == 0x80, isUncompressedWIF || isCompressedWIF else {
            throw BitcoinCashElectrumError.invalidPrivateKey
        }
        return try validate(Data(payload.dropFirst().prefix(32)))
    }

    private static func validate(_ keyData: Data) throws -> Data {
        guard keyData.count == 32,
              PrivateKey.isValid(data: keyData, curve: CoinType.bitcoinCash.curve) else {
            throw BitcoinCashElectrumError.invalidPrivateKey
        }
        return keyData
    }
}

private struct BitcoinCashElectrumServer: Sendable {
    let host: String
    let port: UInt16
    let tls: Bool

    static let defaults: [BitcoinCashElectrumServer] = [
        BitcoinCashElectrumServer(host: "bch.imaginary.cash", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "bch0.kister.net", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "bch.soul-dev.com", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "blackie.c3-soft.com", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "electrum.imaginary.cash", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "bch.cyberbits.eu", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "fulcrum.jettscythe.xyz", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "fulcrum.aglauck.com", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "electron.jochen-hoenicke.de", port: 51002, tls: true),
        BitcoinCashElectrumServer(host: "electrs.bitcoinunlimited.info", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "bch.crypto.mldlabs.com", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "bch.loping.net", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "electroncash.dk", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "bch2.electroncash.dk", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "bitcoincash.network", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "electrum.bitcoinverde.org", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "cashnode.bch.ninja", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "fulcrum.criptolayer.net", port: 50002, tls: true),
        BitcoinCashElectrumServer(host: "node.minisatoshi.cash", port: 50002, tls: true)
    ]
}

private actor BitcoinCashElectrumClient {
    private let server: BitcoinCashElectrumServer
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Aperture.BitcoinCashElectrumClient")
    private var receiveBuffer = Data()
    private var nextID = 1
    private var pending: [Int: @Sendable (Result<BitcoinCashJSONValue, Error>) -> Void] = [:]

    private init(server: BitcoinCashElectrumServer) {
        self.server = server
        let parameters: NWParameters = server.tls ? .tls : .tcp
        self.connection = NWConnection(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: parameters
        )
    }

    static func scanFirst(
        servers: [BitcoinCashElectrumServer],
        targets: [BitcoinCashElectrumScanTarget],
        includeHistory: Bool = true
    ) async throws -> BitcoinCashElectrumLiveScanResult {
        var lastError: Error?
        for server in servers {
            do {
                let client = try await connect(to: server)
                defer { Task { await client.close() } }
                let scans = try await client.scan(targets: targets, includeHistory: includeHistory)
                return BitcoinCashElectrumLiveScanResult(
                    serverDescription: "\(server.host):\(server.port)",
                    scans: scans
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? BitcoinCashElectrumError.connectionFailed
    }

    static func connect(to server: BitcoinCashElectrumServer) async throws -> BitcoinCashElectrumClient {
        let client = BitcoinCashElectrumClient(server: server)
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
                let resumeBox = BitcoinCashElectrumContinuationBox()
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
                        continuation.resume(throwing: BitcoinCashElectrumError.connectionFailed)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard resumeBox.resumeOnce() else { return }
                    connection.cancel()
                    continuation.resume(throwing: BitcoinCashElectrumError.requestTimedOut("connect(\(server.host):\(server.port))"))
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
        _ = try await request(method: "server.version", params: [.string("ApertureBCH"), .string("1.4")])
    }

    func close() {
        connection.cancel()
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(BitcoinCashElectrumError.connectionFailed))
        }
    }

    func scan(
        targets: [BitcoinCashElectrumScanTarget],
        includeHistory: Bool
    ) async throws -> [BitcoinCashElectrumAddressScan] {
        guard !targets.isEmpty else { return [] }
        let unspentRequests = targets.map { target in
            BitcoinCashElectrumBatchRequestSpec(
                method: "blockchain.address.listunspent",
                params: [.string(target.electrumAddress)]
            )
        }

        let unspentResponses: [BitcoinCashElectrumBatchResponse]
        let historyResponses: [BitcoinCashElectrumBatchResponse]
        if includeHistory {
            let historyRequests = targets.map { target in
                BitcoinCashElectrumBatchRequestSpec(
                    method: "blockchain.address.get_history",
                    params: [.string(target.electrumAddress)]
                )
            }
            async let unspentResponsesTask = requestBatch(unspentRequests)
            async let historyResponsesTask = requestBatch(historyRequests)
            (unspentResponses, historyResponses) = try await (unspentResponsesTask, historyResponsesTask)
        } else {
            unspentResponses = try await requestBatch(unspentRequests)
            historyResponses = []
        }

        var scans: [BitcoinCashElectrumAddressScan] = []
        scans.reserveCapacity(targets.count)
        for index in targets.indices {
            let target = targets[index]
            guard case let .array(utxoItems) = unspentResponses[index].result else {
                throw BitcoinCashElectrumError.invalidResponse
            }
            let historyItems: [BitcoinCashJSONValue]
            if includeHistory {
                guard case let .array(items) = historyResponses[index].result else {
                    throw BitcoinCashElectrumError.invalidResponse
                }
                historyItems = items
            } else {
                historyItems = []
            }
            let utxoList = try utxoItems.map(BitcoinCashElectrumUTXO.init(json:))
            let historyList = try historyItems.map(BitcoinCashElectrumHistoryItem.init(json:))
            scans.append(BitcoinCashElectrumAddressScan(
                address: target.address,
                path: target.path,
                scriptHex: target.scriptHex,
                confirmedSats: BitcoinCashElectrumAddressScan.sum(utxos: utxoList.filter { $0.height > 0 }),
                unconfirmedSats: BitcoinCashElectrumAddressScan.sum(utxos: utxoList.filter { $0.height <= 0 }),
                utxos: utxoList,
                history: historyList,
                historyCount: historyList.count
            ))
        }
        return scans
    }

    private func request(method: String, params: [BitcoinCashJSONValue]) async throws -> BitcoinCashJSONValue {
        let id = nextID
        nextID += 1
        let request = BitcoinCashElectrumJSONRequest(id: id, method: method, params: params)
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
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BitcoinCashJSONValue, Error>) in
                pending[id] = { result in
                    continuation.resume(with: result)
                }
                connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    guard let error else { return }
                    Task { await self?.resume(id: id, throwing: error) }
                })
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    await self?.resume(id: id, throwing: BitcoinCashElectrumError.requestTimedOut(method))
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

    private func requestBatch(_ specs: [BitcoinCashElectrumBatchRequestSpec]) async throws -> [BitcoinCashElectrumBatchResponse] {
        guard !specs.isEmpty else { return [] }

        var requests: [BitcoinCashElectrumPendingBatchRequest] = []
        var wireRequests: [BitcoinCashElectrumJSONRequest] = []
        requests.reserveCapacity(specs.count)
        wireRequests.reserveCapacity(specs.count)
        for spec in specs {
            let id = nextID
            nextID += 1
            wireRequests.append(BitcoinCashElectrumJSONRequest(id: id, method: spec.method, params: spec.params))
            requests.append(BitcoinCashElectrumPendingBatchRequest(id: id, spec: spec))
        }
        var payload = try JSONEncoder().encode(wireRequests)
        payload.append(0x0A)

        let ids = requests.map(\.id)
        let batchBox = BitcoinCashElectrumBatchResponseBox(ids: ids)
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
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.fail(ids: ids, error: BitcoinCashElectrumError.requestTimedOut("batch(\(specs.count))"))
            }

            let results = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Int: BitcoinCashJSONValue], Error>) in
                batchBox.wait(continuation)
            }
            await DiagnosticsAPIMonitor.shared.finish(trace, outcome: "succeeded")
            return try requests.map { request in
                guard let result = results[request.id] else {
                    throw BitcoinCashElectrumError.invalidResponse
                }
                return BitcoinCashElectrumBatchResponse(id: request.id, result: result)
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
            "chain": "bitcoinCash",
            "host": server.host,
            "port": "\(server.port)",
            "tls": "\(server.tls)",
            "source": "BitcoinCashElectrumClient"
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
                    await self?.failAll(BitcoinCashElectrumError.connectionFailed)
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
                    let responses = try JSONDecoder().decode([BitcoinCashElectrumJSONResponse].self, from: line)
                    for response in responses { handle(response) }
                } else {
                    let response = try JSONDecoder().decode(BitcoinCashElectrumJSONResponse.self, from: line)
                    handle(response)
                }
            } catch {
                failAll(error)
            }
        }
    }

    private func handle(_ response: BitcoinCashElectrumJSONResponse) {
        guard let id = response.id else { return }
        if let error = response.error {
            resume(id: id, throwing: BitcoinCashElectrumError.rpcError(error.message))
        } else if let result = response.result {
            resume(id: id, returning: result)
        } else {
            resume(id: id, throwing: BitcoinCashElectrumError.invalidResponse)
        }
    }

    private func resume(id: Int, returning value: BitcoinCashJSONValue) {
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

private struct BitcoinCashElectrumBatchRequestSpec: Sendable {
    let method: String
    let params: [BitcoinCashJSONValue]
}

private struct BitcoinCashElectrumPendingBatchRequest: Sendable {
    let id: Int
    let spec: BitcoinCashElectrumBatchRequestSpec
}

private struct BitcoinCashElectrumBatchResponse: Sendable {
    let id: Int
    let result: BitcoinCashJSONValue
}

private final class BitcoinCashElectrumBatchResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<Int>
    private var results: [Int: BitcoinCashJSONValue] = [:]
    private var continuation: CheckedContinuation<[Int: BitcoinCashJSONValue], Error>?
    private var completion: Result<[Int: BitcoinCashJSONValue], Error>?

    init(ids: [Int]) {
        self.remaining = Set(ids)
    }

    func wait(_ continuation: CheckedContinuation<[Int: BitcoinCashJSONValue], Error>) {
        lock.lock()
        if let completion {
            lock.unlock()
            continuation.resume(with: completion)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func complete(id: Int, result: Result<BitcoinCashJSONValue, Error>) {
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

private struct BitcoinCashElectrumAddressScan: Sendable {
    let address: String
    let path: String
    let scriptHex: String
    let confirmedSats: Int64
    let unconfirmedSats: Int64
    let utxos: [BitcoinCashElectrumUTXO]
    /// BUG-010: keep full Electrum history items (not just a count) so
    /// `scanAndPersist` can normalize and upsert activity rows.
    let history: [BitcoinCashElectrumHistoryItem]
    let historyCount: Int

    var totalSats: Int64 {
        let (sum, overflow) = confirmedSats.addingReportingOverflow(unconfirmedSats)
        return overflow ? Int64.max : sum
    }

    static func sum(utxos: [BitcoinCashElectrumUTXO]) -> Int64 {
        utxos.reduce(Int64(0)) { partial, utxo in
            let (sum, overflow) = partial.addingReportingOverflow(utxo.valueSats)
            return overflow ? Int64.max : sum
        }
    }
}

private struct BitcoinCashElectrumLiveScanResult: Sendable {
    let serverDescription: String
    let scans: [BitcoinCashElectrumAddressScan]
}

private struct BitcoinCashElectrumUTXO: Sendable {
    let txHash: String
    let txPosition: Int
    let height: Int
    let valueSats: Int64

    init(json: BitcoinCashJSONValue) throws {
        guard case let .object(object) = json,
              let txHash = object["tx_hash"]?.stringValue,
              let txPosition = object["tx_pos"]?.intValue,
              let height = object["height"]?.intValue,
              let valueSats = object["value"]?.int64Value else {
            throw BitcoinCashElectrumError.invalidResponse
        }
        self.txHash = txHash
        self.txPosition = txPosition
        self.height = height
        self.valueSats = valueSats
    }
}

private struct BitcoinCashElectrumHistoryItem: Sendable {
    let txHash: String
    let height: Int

    init(json: BitcoinCashJSONValue) throws {
        guard case let .object(object) = json,
              let txHash = object["tx_hash"]?.stringValue,
              let height = object["height"]?.intValue else {
            throw BitcoinCashElectrumError.invalidResponse
        }
        self.txHash = txHash
        self.height = height
    }
}

private struct BitcoinCashElectrumJSONRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [BitcoinCashJSONValue]
}

private struct BitcoinCashElectrumJSONResponse: Decodable {
    let id: Int?
    let result: BitcoinCashJSONValue?
    let error: BitcoinCashElectrumJSONError?
}

private struct BitcoinCashElectrumJSONError: Decodable {
    let code: Int?
    let message: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let message = try? container.decode(String.self) {
            self.code = nil
            self.message = message
            return
        }

        if let object = try? container.decode([String: BitcoinCashJSONValue].self) {
            self.code = object["code"]?.intValue
            self.message = object["message"]?.stringValue
                ?? object["error"]?.stringValue
                ?? "\(object)"
            return
        }

        if let value = try? container.decode(BitcoinCashJSONValue.self) {
            self.code = nil
            self.message = "\(value)"
            return
        }

        throw BitcoinCashElectrumError.invalidResponse
    }
}

private enum BitcoinCashJSONValue: Codable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case object([String: BitcoinCashJSONValue])
    case array([BitcoinCashJSONValue])
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
        } else if let value = try? container.decode([String: BitcoinCashJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([BitcoinCashJSONValue].self) {
            self = .array(value)
        } else {
            throw BitcoinCashElectrumError.invalidResponse
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

private enum BitcoinCashElectrumError: Error, CustomStringConvertible {
    case invalidMnemonic
    case invalidPrivateKey
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
            return "Invalid BCH mnemonic"
        case .invalidPrivateKey:
            return "Invalid BCH private key"
        case .derivationFailed(let path):
            return "BCH derivation failed for \(path)"
        case .addressFailed:
            return "BCH address derivation failed"
        case .invalidAddress(let address):
            return "Invalid BCH address: \(address)"
        case .connectionFailed:
            return "BCH Electrum connection failed"
        case .requestTimedOut(let method):
            return "BCH Electrum request timed out: \(method)"
        case .rpcError(let message):
            return "BCH Electrum RPC error: \(message)"
        case .invalidResponse:
            return "Invalid BCH Electrum response"
        }
    }
}

private final class BitcoinCashElectrumContinuationBox: @unchecked Sendable {
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
    var apertureBCHHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(apertureBCHHex hex: String) {
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
}
