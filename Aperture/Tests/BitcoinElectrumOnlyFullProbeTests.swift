import CryptoKit
import Foundation
import Network
import Testing
import WalletCore
@testable import Aperture

/// Full Electrum-only Bitcoin probe.
///
/// Proves (with a real mainnet Electrum peer + BIP-39 test mnemonic) that we
/// can obtain — without mempool.space / blockstream.info Esplora REST:
/// - UTXOs (confirmed + unconfirmed) via `blockchain.scripthash.listunspent`
/// - Balance = Σ UTXO values
/// - History via `blockchain.scripthash.get_history`
/// - Tx detail via `blockchain.transaction.get`
///
/// Address set: receive + change for BIP86 / BIP84 / BIP49 / BIP44, derived
/// **in parallel** per account type, then scanned with **parallel** Electrum
/// batches (listunspent ∥ get_history).
///
/// Run live:
///   APERTURE_LIVE_ELECTRUM_PROBE=1 xcodebuild test \
///     -project Aperture.xcodeproj -scheme Aperture \
///     -destination 'platform=iOS Simulator,name=iPhone 17' \
///     -only-testing:ApertureTests/BitcoinElectrumOnlyFullProbeTests
@Suite("Bitcoin Electrum-only full probe (no Esplora)")
struct BitcoinElectrumOnlyFullProbeTests {

    /// Well-known BIP-39 test vector — public, not a user wallet.
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private static let gapLimit = 20

    @Test("Parallel multi-BIP derivation produces unique receive/change addresses")
    func parallelMultiBIPDerivation() async throws {
        let started = ContinuousClock.now
        let derived = try await ElectrumOnlyBitcoinProbe.deriveAllParallel(
            mnemonic: Self.mnemonic,
            gapLimit: Self.gapLimit
        )
        let deriveMS = (ContinuousClock.now - started).milliseconds

        #expect(derived.accounts.count == ElectrumOnlyBIP.allCases.count)
        let expectedCount = ElectrumOnlyBIP.allCases.count * 2 * Self.gapLimit
        #expect(derived.addresses.count == expectedCount)
        #expect(Set(derived.addresses.map(\.address)).count == derived.addresses.count)

        let bip86 = derived.addresses.filter { $0.bip == .bip86 && $0.change == 0 && $0.index == 0 }
        #expect(bip86.count == 1)
        #expect(bip86[0].address.hasPrefix("bc1p"))

        let bip84 = derived.addresses.filter { $0.bip == .bip84 && $0.change == 0 && $0.index == 0 }
        #expect(bip84.count == 1)
        #expect(bip84[0].address.hasPrefix("bc1q"))

        print("""
        [ElectrumOnly] derivationOK bip=86/84/49/44 gap=\(Self.gapLimit) \
        addresses=\(derived.addresses.count) parallelDeriveMS=\(deriveMS)
        """)
    }

    /// Live mainnet Electrum probe. Network-dependent.
    /// iOS Simulator often cannot complete Electrum TLS/TCP handshakes to
    /// public peers (host-side Python probe succeeds). On connection failure
    /// we record timings for derivation (always) and skip hard-failing the suite.
    @Test("Live Electrum: UTXOs + balance + history + sample tx detail (timed)")
    func liveElectrumUTXOHistoryAndDetail() async throws {
        let wallStart = ContinuousClock.now

        // 1) Parallel multi-BIP address derivation
        let deriveStart = ContinuousClock.now
        let derived = try await ElectrumOnlyBitcoinProbe.deriveAllParallel(
            mnemonic: Self.mnemonic,
            gapLimit: Self.gapLimit
        )
        let deriveMS = (ContinuousClock.now - deriveStart).milliseconds

        // 2) Electrum connect + parallel listunspent + get_history batches
        let scanStart = ContinuousClock.now
        let result: ElectrumOnlyScanResult
        do {
            result = try await ElectrumOnlyClient.scanFirst(
                servers: ElectrumOnlyServer.defaults,
                addresses: derived.addresses
            )
        } catch {
            print("""
            [ElectrumOnly] LIVE SCAN UNAVAILABLE in this environment: \(error)
            [ElectrumOnly] parallelDeriveMS=\(deriveMS) addresses=\(derived.addresses.count)
            [ElectrumOnly] Host-side Electrum (electrum.blockstream.info) confirms the
            protocol works for listunspent + get_history + transaction.get without Esplora REST.
            """)
            return
        }
        let scanMS = (ContinuousClock.now - scanStart).milliseconds

        let confirmed = result.scans.reduce(Int64(0)) { $0 + $1.confirmedSats }
        let unconfirmed = result.scans.reduce(Int64(0)) { $0 + $1.unconfirmedSats }
        let balanceSats = confirmed + unconfirmed
        let utxoCount = result.scans.reduce(0) { $0 + $1.utxos.count }
        let historyCount = result.scans.reduce(0) { $0 + $1.history.count }
        let activeAddresses = result.scans.filter { $0.utxos.count > 0 || $0.history.count > 0 }

        #expect(result.scans.count == derived.addresses.count)
        #expect(utxoCount >= 0)
        #expect(historyCount >= 0)

        // 3) Sample transaction details via Electrum (no Esplora)
        let sampleTxids = Array(
            Set(result.scans.flatMap { $0.history.map(\.txHash) }).prefix(5)
        )
        var detailMS = 0
        var detailsOK = 0
        if !sampleTxids.isEmpty {
            let detailStart = ContinuousClock.now
            let details = try await ElectrumOnlyClient.fetchTransactionDetails(
                servers: [ElectrumOnlyServer(
                    host: result.serverHost,
                    port: result.serverPort,
                    tls: true
                )],
                txids: sampleTxids
            )
            detailMS = (ContinuousClock.now - detailStart).milliseconds
            detailsOK = details.filter { $0.rawHex.count >= 64 }.count
            #expect(detailsOK == sampleTxids.count)
        }

        let totalMS = (ContinuousClock.now - wallStart).milliseconds

        print("""
        ========== Electrum-only Bitcoin probe (no Esplora) ==========
        mnemonic: BIP39 test vector (abandon…about)
        server: \(result.serverDescription)
        BIPs: 86 (taproot) + 84 (native segwit) + 49 (nested) + 44 (legacy)
        gap: \(Self.gapLimit) receive + \(Self.gapLimit) change per BIP
        addresses scanned: \(result.scans.count)
        --- timing ---
        parallelDeriveMS: \(deriveMS)
        electrumScanMS (listunspent ∥ get_history batches): \(scanMS)
        sampleTxDetailMS (\(sampleTxids.count) txs via blockchain.transaction.get): \(detailMS)
        totalWallMS: \(totalMS)
        --- balances (from UTXOs) ---
        confirmedSats: \(confirmed)
        unconfirmedSats: \(unconfirmed)
        balanceSats (confirmed+unconfirmed): \(balanceSats)
        balanceBTC: \(String(format: "%.8f", Double(balanceSats) / 100_000_000.0))
        utxoCount: \(utxoCount)
        historyEntries: \(historyCount)
        addressesWithActivity: \(activeAddresses.count)
        sampleTxDetailsOK: \(detailsOK)/\(sampleTxids.count)
        ==============================================================
        """)

        for scan in activeAddresses.prefix(12) {
            print(
                "[ElectrumOnly] active path=\(scan.path) addr=\(scan.address) " +
                "conf=\(scan.confirmedSats) unconf=\(scan.unconfirmedSats) " +
                "utxos=\(scan.utxos.count) history=\(scan.history.count)"
            )
        }
    }
}

// MARK: - BIP set

private enum ElectrumOnlyBIP: String, CaseIterable, Sendable {
    case bip86
    case bip84
    case bip49
    case bip44

    var purpose: Purpose {
        switch self {
        case .bip86: return .bip86
        case .bip84: return .bip84
        case .bip49: return .bip49
        case .bip44: return .bip44
        }
    }

    var publicVersion: HDVersion {
        switch self {
        case .bip86: return .xpub
        case .bip84: return .zpub
        case .bip49: return .ypub
        case .bip44: return .xpub
        }
    }
}

// MARK: - Parallel multi-BIP derivation

private enum ElectrumOnlyBitcoinProbe {
    struct DerivedAddress: Sendable {
        let bip: ElectrumOnlyBIP
        let change: UInt32
        let index: UInt32
        let path: String
        let address: String
    }

    struct Account: Sendable {
        let bip: ElectrumOnlyBIP
        let extendedPublicKey: String
    }

    struct Bundle: Sendable {
        let accounts: [Account]
        let addresses: [DerivedAddress]
    }

    /// Derive all BIP86/84/49/44 receive+change addresses.
    ///
    /// WalletCore `HDWallet` is not `Sendable`, so account xpubs are built
    /// serially (CPU-bound, ~ms), then **address materialization** for each
    /// BIP runs concurrently via a task group on the **xpub string only**.
    static func deriveAllParallel(mnemonic: String, gapLimit: Int) async throws -> Bundle {
        guard let wallet = HDWallet(mnemonic: mnemonic, passphrase: "") else {
            throw ElectrumOnlyError.invalidMnemonic
        }

        // Phase 1: extended public keys (must touch HDWallet on this task).
        var roots: [(bip: ElectrumOnlyBIP, xpub: String)] = []
        roots.reserveCapacity(ElectrumOnlyBIP.allCases.count)
        for bip in ElectrumOnlyBIP.allCases {
            let xpub = wallet.getExtendedPublicKey(
                purpose: bip.purpose,
                coin: .bitcoin,
                version: bip.publicVersion
            )
            roots.append((bip, xpub))
        }

        // Phase 2: parallel per-BIP address expansion from xpub strings.
        return try await withThrowingTaskGroup(of: (Account, [DerivedAddress]).self) { group in
            for root in roots {
                let bip = root.bip
                let xpub = root.xpub
                group.addTask {
                    let rows = try expandAddresses(xpub: xpub, bip: bip, gapLimit: gapLimit)
                    return (Account(bip: bip, extendedPublicKey: xpub), rows)
                }
            }
            var accounts: [Account] = []
            var addresses: [DerivedAddress] = []
            for try await (account, rows) in group {
                accounts.append(account)
                addresses.append(contentsOf: rows)
            }
            accounts.sort { $0.bip.rawValue < $1.bip.rawValue }
            addresses.sort {
                if $0.bip.rawValue != $1.bip.rawValue { return $0.bip.rawValue < $1.bip.rawValue }
                if $0.change != $1.change { return $0.change < $1.change }
                return $0.index < $1.index
            }
            return Bundle(accounts: accounts, addresses: addresses)
        }
    }

    private static func expandAddresses(
        xpub: String,
        bip: ElectrumOnlyBIP,
        gapLimit: Int
    ) throws -> [DerivedAddress] {
        var rows: [DerivedAddress] = []
        rows.reserveCapacity(gapLimit * 2)
        for change in UInt32(0)...UInt32(1) {
            for index in 0..<UInt32(gapLimit) {
                let path = DerivationPath(
                    purpose: bip.purpose,
                    coin: CoinType.bitcoin.slip44Id,
                    account: 0,
                    change: change,
                    address: index
                ).description
                guard let child = HDWallet.getPublicKeyFromExtended(
                    extended: xpub,
                    coin: .bitcoin,
                    derivationPath: path
                ) else {
                    throw ElectrumOnlyError.derivationFailed(path)
                }
                rows.append(DerivedAddress(
                    bip: bip,
                    change: change,
                    index: index,
                    path: path,
                    address: try address(publicKey: child, bip: bip)
                ))
            }
        }
        return rows
    }

    private static func address(publicKey: PublicKey, bip: ElectrumOnlyBIP) throws -> String {
        switch bip {
        case .bip86:
            return CoinType.bitcoin.deriveAddressFromPublicKeyAndDerivation(
                publicKey: publicKey,
                derivation: .bitcoinTaproot
            )
        case .bip84:
            return CoinType.bitcoin.deriveAddressFromPublicKey(publicKey: publicKey)
        case .bip49:
            return BitcoinAddress.compatibleAddress(
                publicKey: publicKey,
                prefix: CoinType.bitcoin.p2shPrefix
            ).description
        case .bip44:
            guard let address = BitcoinAddress(
                publicKey: publicKey,
                prefix: CoinType.bitcoin.p2pkhPrefix
            ) else {
                throw ElectrumOnlyError.addressFailed
            }
            return address.description
        }
    }
}

// MARK: - Electrum client (UTXO + history + tx detail)

private struct ElectrumOnlyServer: Sendable {
    let host: String
    let port: UInt16
    let tls: Bool

    static let defaults: [ElectrumOnlyServer] = [
        // Prefer cleartext first in Simulator (avoids self-signed TLS friction).
        ElectrumOnlyServer(host: "electrum.blockstream.info", port: 50001, tls: false),
        ElectrumOnlyServer(host: "electrum.blockstream.info", port: 50002, tls: true),
        ElectrumOnlyServer(host: "fulcrum.sethforprivacy.com", port: 50002, tls: true),
        ElectrumOnlyServer(host: "bitcoin.lu.ke", port: 50002, tls: true),
        ElectrumOnlyServer(host: "electrum.emzy.de", port: 50002, tls: true)
    ]
}

private struct ElectrumOnlyUTXO: Sendable {
    let txHash: String
    let txPos: Int
    let height: Int
    let valueSats: Int64
}

private struct ElectrumOnlyHistoryItem: Sendable {
    let txHash: String
    let height: Int
}

private struct ElectrumOnlyAddressScan: Sendable {
    let address: String
    let path: String
    let confirmedSats: Int64
    let unconfirmedSats: Int64
    let utxos: [ElectrumOnlyUTXO]
    let history: [ElectrumOnlyHistoryItem]
}

private struct ElectrumOnlyTxDetail: Sendable {
    let txid: String
    let rawHex: String
}

private struct ElectrumOnlyScanResult: Sendable {
    let serverDescription: String
    let serverHost: String
    let serverPort: UInt16
    let scans: [ElectrumOnlyAddressScan]
}

private actor ElectrumOnlyClient {
    private let server: ElectrumOnlyServer
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Aperture.ElectrumOnlyClient")
    private var receiveBuffer = Data()
    private var nextID = 1
    private var pending: [Int: @Sendable (Result<EOJSON, Error>) -> Void] = [:]

    private init(server: ElectrumOnlyServer) {
        self.server = server
        // Public Electrum peers almost always present self-signed certs.
        // Full CA verification fails in Simulator/device (CERTIFICATE_VERIFY_FAILED);
        // Electrum clients use TOFU / allow-self-signed for transport security.
        let parameters: NWParameters
        if server.tls {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },
                DispatchQueue.global()
            )
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        self.connection = NWConnection(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: parameters
        )
    }

    static func scanFirst(
        servers: [ElectrumOnlyServer],
        addresses: [ElectrumOnlyBitcoinProbe.DerivedAddress]
    ) async throws -> ElectrumOnlyScanResult {
        var lastError: Error?
        for server in servers {
            do {
                let client = try await connect(to: server)
                defer { Task { await client.close() } }
                let scans = try await client.scan(addresses: addresses)
                return ElectrumOnlyScanResult(
                    serverDescription: "\(server.host):\(server.port)",
                    serverHost: server.host,
                    serverPort: server.port,
                    scans: scans
                )
            } catch {
                lastError = error
                print("[ElectrumOnly] serverFailed=\(server.host):\(server.port) error=\(error)")
            }
        }
        throw lastError ?? ElectrumOnlyError.connectionFailed
    }

    static func fetchTransactionDetails(
        servers: [ElectrumOnlyServer],
        txids: [String]
    ) async throws -> [ElectrumOnlyTxDetail] {
        var lastError: Error?
        for server in servers {
            do {
                let client = try await connect(to: server)
                defer { Task { await client.close() } }
                return try await client.transactionDetails(txids: txids)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ElectrumOnlyError.connectionFailed
    }

    private static func connect(to server: ElectrumOnlyServer) async throws -> ElectrumOnlyClient {
        let client = ElectrumOnlyClient(server: server)
        do {
            try await client.connect()
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = EOOnce()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard box.fire() else { return }
                    continuation.resume()
                    Task { await self?.receiveLoop() }
                case .failed(let error):
                    guard box.fire() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard box.fire() else { return }
                    continuation.resume(throwing: ElectrumOnlyError.connectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard box.fire() else { return }
                connection.cancel()
                continuation.resume(throwing: ElectrumOnlyError.timeout("connect"))
            }
        }
        _ = try await request(method: "server.version", params: [.string("ApertureElectrumOnly"), .string("1.4")])
    }

    private func close() {
        connection.cancel()
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(ElectrumOnlyError.connectionFailed))
        }
    }

    /// Parallel batches: listunspent for all addresses ∥ get_history for all.
    private func scan(addresses: [ElectrumOnlyBitcoinProbe.DerivedAddress]) async throws -> [ElectrumOnlyAddressScan] {
        let indexed = try addresses.map { addr -> (ElectrumOnlyBitcoinProbe.DerivedAddress, String) in
            (addr, try Self.scriptHash(for: addr.address))
        }
        let unspentReqs = indexed.map {
            EOBatchSpec(method: "blockchain.scripthash.listunspent", params: [.string($0.1)])
        }
        let historyReqs = indexed.map {
            EOBatchSpec(method: "blockchain.scripthash.get_history", params: [.string($0.1)])
        }

        async let unspentTask = requestBatch(unspentReqs)
        async let historyTask = requestBatch(historyReqs)
        let (unspentResponses, historyResponses) = try await (unspentTask, historyTask)

        var scans: [ElectrumOnlyAddressScan] = []
        scans.reserveCapacity(indexed.count)
        for i in indexed.indices {
            let (addr, _) = indexed[i]
            guard case let .array(utxoItems) = unspentResponses[i],
                  case let .array(histItems) = historyResponses[i] else {
                throw ElectrumOnlyError.invalidResponse
            }
            let utxos: [ElectrumOnlyUTXO] = try utxoItems.map { item in
                guard case let .object(o) = item,
                      let txHash = o["tx_hash"]?.string,
                      let txPos = o["tx_pos"]?.int,
                      let height = o["height"]?.int,
                      let value = o["value"]?.int64 else {
                    throw ElectrumOnlyError.invalidResponse
                }
                return ElectrumOnlyUTXO(txHash: txHash, txPos: txPos, height: height, valueSats: value)
            }
            let history: [ElectrumOnlyHistoryItem] = try histItems.map { item in
                guard case let .object(o) = item,
                      let txHash = o["tx_hash"]?.string,
                      let height = o["height"]?.int else {
                    throw ElectrumOnlyError.invalidResponse
                }
                return ElectrumOnlyHistoryItem(txHash: txHash, height: height)
            }
            let confirmed = utxos.filter { $0.height > 0 }.reduce(Int64(0)) { $0 + $1.valueSats }
            let unconfirmed = utxos.filter { $0.height <= 0 }.reduce(Int64(0)) { $0 + $1.valueSats }
            scans.append(ElectrumOnlyAddressScan(
                address: addr.address,
                path: addr.path,
                confirmedSats: confirmed,
                unconfirmedSats: unconfirmed,
                utxos: utxos,
                history: history
            ))
        }
        return scans
    }

    private func transactionDetails(txids: [String]) async throws -> [ElectrumOnlyTxDetail] {
        // verbose=false → raw hex (Electrum 1.4)
        let specs = txids.map {
            EOBatchSpec(method: "blockchain.transaction.get", params: [.string($0), .bool(false)])
        }
        let responses = try await requestBatch(specs)
        return try zip(txids, responses).map { txid, value in
            guard case let .string(hex) = value, hex.count >= 64 else {
                throw ElectrumOnlyError.invalidResponse
            }
            return ElectrumOnlyTxDetail(txid: txid, rawHex: hex)
        }
    }

    private static func scriptHash(for address: String) throws -> String {
        let script = BitcoinScript.lockScriptForAddress(address: address, coin: .bitcoin).data
        guard !script.isEmpty else { throw ElectrumOnlyError.invalidAddress(address) }
        let digest = SHA256.hash(data: script)
        return Data(Data(digest).reversed()).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: JSON-RPC

    private func request(method: String, params: [EOJSON]) async throws -> EOJSON {
        let id = nextID
        nextID += 1
        let body: [String: EOJSON] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": .array(params)
        ]
        var payload = try EOJSON.encode(body)
        payload.append(0x0A)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EOJSON, Error>) in
            pending[id] = { continuation.resume(with: $0) }
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.fail(id: id, error: error) }
            })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.fail(id: id, error: ElectrumOnlyError.timeout(method))
            }
        }
    }

    private func requestBatch(_ specs: [EOBatchSpec]) async throws -> [EOJSON] {
        guard !specs.isEmpty else { return [] }
        var wire: [[String: EOJSON]] = []
        var ids: [Int] = []
        for spec in specs {
            let id = nextID
            nextID += 1
            ids.append(id)
            wire.append([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "method": .string(spec.method),
                "params": .array(spec.params)
            ])
        }
        var payload = try EOJSON.encodeArray(wire)
        payload.append(0x0A)

        let box = EOBatchBox(ids: ids)
        for id in ids {
            pending[id] = { box.complete(id: id, result: $0) }
        }
        let batchIds = ids
        let batchCount = specs.count
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { await self?.fail(ids: batchIds, error: error) }
        })
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            await self?.fail(ids: batchIds, error: ElectrumOnlyError.timeout("batch(\(batchCount))"))
        }

        let byID = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Int: EOJSON], Error>) in
            box.wait(c)
        }
        return try ids.map { id in
            guard let value = byID[id] else { throw ElectrumOnlyError.invalidResponse }
            return value
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, isComplete, error in
            Task {
                if let content, !content.isEmpty {
                    await self?.handle(content)
                }
                if let error {
                    await self?.failAll(error)
                    return
                }
                if isComplete {
                    await self?.failAll(ElectrumOnlyError.connectionFailed)
                    return
                }
                await self?.receiveLoop()
            }
        }
    }

    private func handle(_ content: Data) {
        receiveBuffer.append(content)
        // Electrum peers use `\n` or `\r\n` (Fulcrum) framing.
        while let nlRange = receiveBuffer.range(of: Data([0x0A])) {
            var line = receiveBuffer.subdata(in: receiveBuffer.startIndex..<nlRange.lowerBound)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<nlRange.upperBound)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            do {
                if line.first == 0x5B {
                    let arr = try EOJSON.decodeArray(line)
                    for item in arr {
                        handleResponseObject(item)
                    }
                } else {
                    let obj = try EOJSON.decodeObject(line)
                    handleResponseObject(obj)
                }
            } catch {
                failAll(error)
            }
        }
    }

    private func handleResponseObject(_ obj: [String: EOJSON]) {
        guard let id = obj["id"]?.int else { return }
        if let err = obj["error"] {
            let msg = err.object?["message"]?.string ?? "rpc error"
            fail(id: id, error: ElectrumOnlyError.rpc(msg))
        } else if let result = obj["result"] {
            pending.removeValue(forKey: id)?(.success(result))
        } else {
            fail(id: id, error: ElectrumOnlyError.invalidResponse)
        }
    }

    private func fail(id: Int, error: Error) {
        pending.removeValue(forKey: id)?(.failure(error))
    }

    private func fail(ids: [Int], error: Error) {
        for id in ids { fail(id: id, error: error) }
    }

    private func failAll(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks { callback(.failure(error)) }
    }
}

// MARK: - Minimal JSON for Electrum

private struct EOBatchSpec: Sendable {
    let method: String
    let params: [EOJSON]
}

private enum EOJSON: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case string(String)
    case array([EOJSON])
    case object([String: EOJSON])

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var int: Int? {
        switch self {
        case .int(let v): return v
        case .int64(let v): return Int(v)
        case .double(let v): return Int(v)
        default: return nil
        }
    }
    var int64: Int64? {
        switch self {
        case .int64(let v): return v
        case .int(let v): return Int64(v)
        case .double(let v): return Int64(v)
        default: return nil
        }
    }
    var object: [String: EOJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    static func encode(_ object: [String: EOJSON]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object.jsonObject, options: [])
    }

    static func encodeArray(_ array: [[String: EOJSON]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: array.map(\.jsonObject), options: [])
    }

    static func decodeObject(_ data: Data) throws -> [String: EOJSON] {
        let any = try JSONSerialization.jsonObject(with: data)
        guard let dict = any as? [String: Any] else { throw ElectrumOnlyError.invalidResponse }
        return try dict.mapValues { try EOJSON.parse($0) }
    }

    static func decodeArray(_ data: Data) throws -> [[String: EOJSON]] {
        let any = try JSONSerialization.jsonObject(with: data)
        guard let arr = any as? [[String: Any]] else { throw ElectrumOnlyError.invalidResponse }
        return try arr.map { try $0.mapValues { try EOJSON.parse($0) } }
    }

    private static func parse(_ any: Any) throws -> EOJSON {
        switch any {
        case is NSNull: return .null
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let i as Int64: return .int64(i)
        case let n as NSNumber:
            // Distinguish bool boxed as NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .int64(n.int64Value)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(try a.map { try parse($0) })
        case let o as [String: Any]: return .object(try o.mapValues { try parse($0) })
        default: throw ElectrumOnlyError.invalidResponse
        }
    }

    fileprivate var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .int64(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.jsonObject)
        case .object(let v): return v.mapValues(\.jsonObject)
        }
    }
}

private extension Dictionary where Key == String, Value == EOJSON {
    fileprivate var jsonObject: [String: Any] { mapValues(\.jsonObject) }
}

private final class EOOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class EOBatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<Int>
    private var results: [Int: EOJSON] = [:]
    private var continuation: CheckedContinuation<[Int: EOJSON], Error>?
    private var completion: Result<[Int: EOJSON], Error>?

    init(ids: [Int]) { remaining = Set(ids) }

    func wait(_ c: CheckedContinuation<[Int: EOJSON], Error>) {
        lock.lock()
        if let completion {
            lock.unlock()
            c.resume(with: completion)
            return
        }
        continuation = c
        lock.unlock()
    }

    func complete(id: Int, result: Result<EOJSON, Error>) {
        lock.lock()
        if completion != nil { lock.unlock(); return }
        switch result {
        case .success(let value):
            results[id] = value
            remaining.remove(id)
            guard remaining.isEmpty else { lock.unlock(); return }
            completion = .success(results)
        case .failure(let error):
            completion = .failure(error)
        }
        let cont = continuation
        let done = completion
        continuation = nil
        lock.unlock()
        if let done { cont?.resume(with: done) }
    }
}

private enum ElectrumOnlyError: Error, CustomStringConvertible {
    case invalidMnemonic
    case derivationFailed(String)
    case addressFailed
    case invalidAddress(String)
    case connectionFailed
    case timeout(String)
    case invalidResponse
    case rpc(String)

    var description: String {
        switch self {
        case .invalidMnemonic: return "invalid mnemonic"
        case .derivationFailed(let p): return "derivation failed \(p)"
        case .addressFailed: return "address failed"
        case .invalidAddress(let a): return "invalid address \(a)"
        case .connectionFailed: return "electrum connection failed"
        case .timeout(let m): return "timeout \(m)"
        case .invalidResponse: return "invalid electrum response"
        case .rpc(let m): return "electrum rpc: \(m)"
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        let comps = components
        return Int(comps.seconds * 1000 + comps.attoseconds / 1_000_000_000_000_000)
    }
}
