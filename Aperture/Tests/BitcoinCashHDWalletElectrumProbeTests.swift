import Foundation
import Network
import Testing
import WalletCore
@testable import Aperture

@Suite("Bitcoin Cash HD wallet + Electrum-Cash probe")
struct BitcoinCashHDWalletElectrumProbeTests {
    private static let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private static let gapLimit = 20

    @Test("Mnemonic derives BIP44 BCH receive/change addresses with gap 20")
    func mnemonicBIP44Gap20Addresses() async throws {
        let probe = try BitcoinCashHDProbe.deriveFromMnemonic(Self.mnemonic, gapLimit: Self.gapLimit)

        #expect(probe.addresses.count == 2 * Self.gapLimit)
        #expect(Set(probe.addresses.map(\.address)).count == probe.addresses.count)
        #expect(probe.qrReceiveAddress.branch == 0)
        #expect(probe.qrReceiveAddress.index == 0)
        #expect(probe.qrReceiveAddress.path == "m/44'/145'/0'/0/0")

        for address in probe.addresses {
            #expect(AnyAddress.isValid(string: address.address, coin: .bitcoinCash))
        }
    }

    @Test("BCH private-key imports accept hex and WIF prefixes 5/K/L")
    func bitcoinCashPrivateKeyImportFormats() async throws {
        let privateKeyOne = Data(repeating: 0, count: 31) + Data([1])
        let hex = privateKeyOne.bchProbeHex
        let uncompressedWIF = try BitcoinCashWIFProbe.wif(privateKey: privateKeyOne, compressed: false)
        let kWIF = try BitcoinCashWIFProbe.firstCompressedWIF(prefix: "K")
        let lWIF = try BitcoinCashWIFProbe.firstCompressedWIF(prefix: "L")

        #expect(uncompressedWIF.hasPrefix("5"))
        #expect(kWIF.hasPrefix("K"))
        #expect(lWIF.hasPrefix("L"))

        for raw in [hex, "0x" + hex, uncompressedWIF, kWIF, lWIF] {
            let keyData = try BitcoinCashPrivateKeyProbe.decode(raw)
            let address = try BitcoinCashPrivateKeyProbe.address(fromPrivateKey: keyData)
            #expect(AnyAddress.isValid(string: address, coin: .bitcoinCash))
        }
    }

    @Test("Live Electrum-Cash gap-20 scan returns UTXO/history payloads in parallel")
    func liveElectrumCashGap20Scan() async throws {
        let markerPath = "/tmp/aperture_live_bch_electrum_probe"
        let shouldRunLiveProbe = ProcessInfo.processInfo.environment["APERTURE_LIVE_BCH_ELECTRUM_PROBE"] == "1"
            || FileManager.default.fileExists(atPath: markerPath)
        guard shouldRunLiveProbe else {
            print("[BitcoinCashHDProbe] Skipped live Electrum-Cash probe. Set APERTURE_LIVE_BCH_ELECTRUM_PROBE=1 or create \(markerPath) to run it.")
            return
        }

        let derived = try BitcoinCashHDProbe.deriveFromMnemonic(Self.mnemonic, gapLimit: Self.gapLimit)
        let result = try await BitcoinCashElectrumProbeClient.scanFirst(
            servers: BitcoinCashElectrumProbeServer.defaults,
            addresses: derived.addresses
        )

        let scans = result.scans
        let confirmed = scans.reduce(Int64(0)) { $0 + $1.confirmedSats }
        let unconfirmed = scans.reduce(Int64(0)) { $0 + $1.unconfirmedSats }
        let historyCount = scans.reduce(0) { $0 + $1.historyCount }

        #expect(scans.count == derived.addresses.count)
        #expect(scans.allSatisfy { $0.utxoCount >= 0 && $0.historyCount >= 0 })

        print("""
        [BitcoinCashHDProbe] server=\(result.serverDescription)
        [BitcoinCashHDProbe] scannedAddresses=\(scans.count) gap=\(Self.gapLimit) branches=receive/change
        [BitcoinCashHDProbe] elapsedMS=\(result.elapsedMS) confirmedSats=\(confirmed) unconfirmedSats=\(unconfirmed) historyEntries=\(historyCount)
        [BitcoinCashHDProbe] qrReceiveAddress=\(derived.qrReceiveAddress.path) \(derived.qrReceiveAddress.address)
        """)
    }
}

private struct BitcoinCashHDProbe: Sendable {
    struct DerivedAddress: Sendable {
        let branch: UInt32
        let index: UInt32
        let path: String
        let address: String

        var electrumAddress: String {
            address.replacingOccurrences(of: "bitcoincash:", with: "")
        }
    }

    let addresses: [DerivedAddress]
    let qrReceiveAddress: DerivedAddress

    static func deriveFromMnemonic(_ mnemonic: String, gapLimit: Int) throws -> BitcoinCashHDProbe {
        guard let wallet = HDWallet(mnemonic: mnemonic, passphrase: "") else {
            throw BitcoinCashProbeError.invalidMnemonic
        }

        var addresses: [DerivedAddress] = []
        addresses.reserveCapacity(2 * gapLimit)

        for branch in UInt32(0)...UInt32(1) {
            for index in 0..<UInt32(gapLimit) {
                let path = "m/44'/145'/0'/\(branch)/\(index)"
                let privateKey = wallet.getKey(coin: .bitcoinCash, derivationPath: path)
                let address = CoinType.bitcoinCash.deriveAddress(privateKey: privateKey)
                guard !address.isEmpty else {
                    throw BitcoinCashProbeError.derivationFailed(path)
                }
                addresses.append(DerivedAddress(
                    branch: branch,
                    index: index,
                    path: path,
                    address: address
                ))
            }
        }

        guard let qrReceiveAddress = addresses.first(where: { $0.branch == 0 && $0.index == 0 }) else {
            throw BitcoinCashProbeError.derivationFailed("m/44'/145'/0'/0/0")
        }

        return BitcoinCashHDProbe(addresses: addresses, qrReceiveAddress: qrReceiveAddress)
    }
}

private enum BitcoinCashWIFProbe {
    static func wif(privateKey: Data, compressed: Bool) throws -> String {
        guard privateKey.count == 32 else { throw BitcoinCashProbeError.invalidPrivateKey }
        var payload = Data([0x80])
        payload.append(privateKey)
        if compressed {
            payload.append(0x01)
        }
        return WalletCore.Base58.encode(data: payload)
    }

    static func firstCompressedWIF(prefix: Character) throws -> String {
        for highByte in UInt8(1)...UInt8(240) {
            for lowByte in UInt8(1)...UInt8.max {
                var privateKey = Data(repeating: 0, count: 32)
                privateKey[0] = highByte
                privateKey[31] = lowByte
                guard PrivateKey(data: privateKey) != nil else { continue }
                let wif = try wif(privateKey: privateKey, compressed: true)
                if wif.first == prefix {
                    return wif
                }
            }
        }
        throw BitcoinCashProbeError.invalidPrivateKey
    }
}

private enum BitcoinCashPrivateKeyProbe {
    static func decode(_ raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        if hex.count == 64, hex.allSatisfy(\.isHexDigit), let data = Data(bchProbeHex: hex) {
            return try validate(data)
        }

        guard let payload = WalletCore.Base58.decode(string: trimmed) else {
            throw BitcoinCashProbeError.invalidPrivateKey
        }
        let isUncompressedWIF = payload.count == 33
        let isCompressedWIF = payload.count == 34 && payload.last == 0x01
        guard payload.first == 0x80, isUncompressedWIF || isCompressedWIF else {
            throw BitcoinCashProbeError.invalidPrivateKey
        }
        return try validate(Data(payload.dropFirst().prefix(32)))
    }

    static func address(fromPrivateKey keyData: Data) throws -> String {
        guard let privateKey = PrivateKey(data: try validate(keyData)) else {
            throw BitcoinCashProbeError.invalidPrivateKey
        }
        let address = CoinType.bitcoinCash.deriveAddress(privateKey: privateKey)
        guard !address.isEmpty else {
            throw BitcoinCashProbeError.addressFailed
        }
        return address
    }

    private static func validate(_ keyData: Data) throws -> Data {
        guard keyData.count == 32,
              PrivateKey.isValid(data: keyData, curve: CoinType.bitcoinCash.curve) else {
            throw BitcoinCashProbeError.invalidPrivateKey
        }
        return keyData
    }
}

private struct BitcoinCashElectrumProbeServer: Sendable {
    let host: String
    let port: UInt16
    let tls: Bool

    static let defaults: [BitcoinCashElectrumProbeServer] = [
        BitcoinCashElectrumProbeServer(host: "bch.imaginary.cash", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "electron.jochen-hoenicke.de", port: 51002, tls: true),
        BitcoinCashElectrumProbeServer(host: "electrs.bitcoinunlimited.info", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "bch.crypto.mldlabs.com", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "bch0.kister.net", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "bch.loping.net", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "bch.soul-dev.com", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "blackie.c3-soft.com", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "electroncash.dk", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "bch2.electroncash.dk", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "electrum.imaginary.cash", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "bch.cyberbits.eu", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "bitcoincash.network", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "electrum.bitcoinverde.org", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "cashnode.bch.ninja", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "fulcrum.criptolayer.net", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "fulcrum.jettscythe.xyz", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "fulcrum.aglauck.com", port: 50002, tls: true),
        BitcoinCashElectrumProbeServer(host: "node.minisatoshi.cash", port: 50002, tls: true)
    ]
}

private actor BitcoinCashElectrumProbeClient {
    private let server: BitcoinCashElectrumProbeServer
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Aperture.BitcoinCashElectrumProbeClient")
    private var receiveBuffer = Data()
    private var nextID = 1
    private var pending: [Int: @Sendable (Result<BitcoinCashJSONValue, Error>) -> Void] = [:]

    private init(server: BitcoinCashElectrumProbeServer) {
        self.server = server
        let parameters: NWParameters = server.tls ? .tls : .tcp
        self.connection = NWConnection(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: parameters
        )
    }

    static func connect(to server: BitcoinCashElectrumProbeServer) async throws -> BitcoinCashElectrumProbeClient {
        let client = BitcoinCashElectrumProbeClient(server: server)
        do {
            try await client.connect()
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    static func scanFirst(
        servers: [BitcoinCashElectrumProbeServer],
        addresses: [BitcoinCashHDProbe.DerivedAddress]
    ) async throws -> BitcoinCashElectrumLiveProbeResult {
        var lastError: Error?
        for server in servers {
            do {
                let client = try await connect(to: server)
                defer { Task { await client.close() } }
                let started = Date()
                let scans = try await client.scan(addresses: addresses)
                let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
                return BitcoinCashElectrumLiveProbeResult(
                    serverDescription: "\(server.host):\(server.port)",
                    scans: scans,
                    elapsedMS: elapsedMS
                )
            } catch {
                lastError = error
                print("[BitcoinCashHDProbe] serverFailed=\(server.host):\(server.port) error=\(error)")
            }
        }
        throw lastError ?? BitcoinCashProbeError.electrumConnectionFailed
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeBox = BitcoinCashProbeContinuationBox()
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
                    continuation.resume(throwing: BitcoinCashProbeError.electrumConnectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard resumeBox.resumeOnce() else { return }
                connection.cancel()
                continuation.resume(throwing: BitcoinCashProbeError.electrumRequestTimedOut("connect(\(server.host):\(server.port))"))
            }
        }
        _ = try await request(method: "server.version", params: [.string("ApertureBCHProbe"), .string("1.4")])
    }

    func close() {
        connection.cancel()
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(BitcoinCashProbeError.electrumConnectionFailed))
        }
    }

    func scan(addresses: [BitcoinCashHDProbe.DerivedAddress]) async throws -> [BitcoinCashElectrumAddressScan] {
        let started = Date()
        let unspentRequests = addresses.map { address in
            BitcoinCashElectrumBatchRequestSpec(
                method: "blockchain.address.listunspent",
                params: [.string(address.electrumAddress)]
            )
        }
        let historyRequests = addresses.map { address in
            BitcoinCashElectrumBatchRequestSpec(
                method: "blockchain.address.get_history",
                params: [.string(address.electrumAddress)]
            )
        }

        async let unspentResponsesTask = requestBatch(unspentRequests)
        async let historyResponsesTask = requestBatch(historyRequests)
        let (unspentResponses, historyResponses) = try await (unspentResponsesTask, historyResponsesTask)
        let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)

        var scans: [BitcoinCashElectrumAddressScan] = []
        scans.reserveCapacity(addresses.count)
        for index in addresses.indices {
            let address = addresses[index]
            guard case let .array(utxoItems) = unspentResponses[index].result,
                  case let .array(historyItems) = historyResponses[index].result else {
                throw BitcoinCashProbeError.invalidElectrumResponse
            }
            let utxoList = try utxoItems.map(BitcoinCashElectrumUTXO.init(json:))
            let historyList = try historyItems.map(BitcoinCashElectrumHistoryItem.init(json:))
            let confirmedSats = utxoList
                .filter { $0.height > 0 }
                .reduce(Int64(0)) { $0 + $1.valueSats }
            let unconfirmedSats = utxoList
                .filter { $0.height <= 0 }
                .reduce(Int64(0)) { $0 + $1.valueSats }
            scans.append(BitcoinCashElectrumAddressScan(
                address: address.address,
                path: address.path,
                confirmedSats: confirmedSats,
                unconfirmedSats: unconfirmedSats,
                utxoCount: utxoList.count,
                historyCount: historyList.count,
                elapsedMS: elapsedMS
            ))
        }
        return scans.sorted { $0.path < $1.path }
    }

    private func request(method: String, params: [BitcoinCashJSONValue]) async throws -> BitcoinCashJSONValue {
        let id = nextID
        nextID += 1
        let request = BitcoinCashElectrumJSONRequest(id: id, method: method, params: params)
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BitcoinCashJSONValue, Error>) in
            pending[id] = { result in
                continuation.resume(with: result)
            }
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.resume(id: id, throwing: error) }
            })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                await self?.resume(id: id, throwing: BitcoinCashProbeError.electrumRequestTimedOut(method))
            }
        }
    }

    private func requestBatch(_ specs: [BitcoinCashElectrumBatchRequestSpec]) async throws -> [BitcoinCashElectrumBatchResponse] {
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

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { await self?.fail(ids: ids, error: error) }
        })
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await self?.fail(ids: ids, error: BitcoinCashProbeError.electrumRequestTimedOut("batch(\(specs.count))"))
        }

        let results = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Int: BitcoinCashJSONValue], Error>) in
            batchBox.wait(continuation)
        }
        return try requests.map { request in
            guard let result = results[request.id] else {
                throw BitcoinCashProbeError.invalidElectrumResponse
            }
            return BitcoinCashElectrumBatchResponse(id: request.id, result: result)
        }
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
                    await self?.failAll(BitcoinCashProbeError.electrumConnectionFailed)
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
                    for response in responses {
                        handle(response)
                    }
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
            resume(id: id, throwing: BitcoinCashProbeError.electrumRPCError(error.message))
        } else if let result = response.result {
            resume(id: id, returning: result)
        } else {
            resume(id: id, throwing: BitcoinCashProbeError.invalidElectrumResponse)
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
    let confirmedSats: Int64
    let unconfirmedSats: Int64
    let utxoCount: Int
    let historyCount: Int
    let elapsedMS: Int
}

private struct BitcoinCashElectrumLiveProbeResult: Sendable {
    let serverDescription: String
    let scans: [BitcoinCashElectrumAddressScan]
    let elapsedMS: Int
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
            throw BitcoinCashProbeError.invalidElectrumResponse
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
            throw BitcoinCashProbeError.invalidElectrumResponse
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

        throw BitcoinCashProbeError.invalidElectrumResponse
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
            throw BitcoinCashProbeError.invalidElectrumResponse
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

private enum BitcoinCashProbeError: Error, CustomStringConvertible {
    case invalidMnemonic
    case invalidPrivateKey
    case derivationFailed(String)
    case addressFailed
    case electrumConnectionFailed
    case electrumRequestTimedOut(String)
    case electrumRPCError(String)
    case invalidElectrumResponse

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
        case .electrumConnectionFailed:
            return "Electrum-Cash connection failed"
        case .electrumRequestTimedOut(let method):
            return "Electrum-Cash request timed out: \(method)"
        case .electrumRPCError(let message):
            return "Electrum-Cash RPC error: \(message)"
        case .invalidElectrumResponse:
            return "Invalid Electrum-Cash response"
        }
    }
}

private final class BitcoinCashProbeContinuationBox: @unchecked Sendable {
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
    static func + (lhs: Data, rhs: Data) -> Data {
        var data = lhs
        data.append(rhs)
        return data
    }

    var bchProbeHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(bchProbeHex hex: String) {
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
