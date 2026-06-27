import CryptoKit
import Foundation
import Network
import Testing
import WalletCore
@testable import Aperture

@Suite("Bitcoin HD wallet + Electrum probe")
struct BitcoinHDWalletElectrumProbeTests {
    private static let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private static let gapLimit = 20

    @Test("Mnemonic derives xpub/ypub/zpub, converts xprv/yprv/zprv, and builds gap-20 receive/change addresses")
    func mnemonicExtendedKeysAndGap20Addresses() async throws {
        let probe = try BitcoinHDProbe.deriveFromMnemonic(Self.mnemonic, gapLimit: Self.gapLimit)

        #expect(probe.accounts.count == BitcoinAccountKind.allCases.count)
        #expect(probe.addresses.count == BitcoinAccountKind.allCases.count * 2 * Self.gapLimit)
        #expect(Set(probe.addresses.map(\.address)).count == probe.addresses.count)
        #expect(probe.qrReceiveAddress.kind == .bip84)
        #expect(probe.qrReceiveAddress.change == 0)
        #expect(probe.qrReceiveAddress.index == 0)
        #expect(probe.qrReceiveAddress.address.hasPrefix("bc1q"))

        for account in probe.accounts {
            #expect(account.convertedPublicKey == account.extendedPublicKey)
            #expect(account.extendedPublicKey.hasPrefix(account.kind.publicPrefix))
            #expect(account.extendedPrivateKey.hasPrefix(account.kind.privatePrefix))
        }

        for address in probe.addresses {
            #expect(BitcoinAddress.isValidString(string: address.address) || SegwitAddress.isValidString(string: address.address))
        }
    }

    @Test("Bitcoin private-key imports accept hex and WIF prefixes 5/K/L")
    func bitcoinPrivateKeyImportFormats() async throws {
        let privateKeyOne = Data(repeating: 0, count: 31) + Data([1])
        let hex = privateKeyOne.apertureProbeHex
        let uncompressedWIF = try WIFProbe.wif(privateKey: privateKeyOne, compressed: false)
        let kWIF = try WIFProbe.firstCompressedWIF(prefix: "K")
        let lWIF = try WIFProbe.firstCompressedWIF(prefix: "L")

        #expect(uncompressedWIF.hasPrefix("5"))
        #expect(kWIF.hasPrefix("K"))
        #expect(lWIF.hasPrefix("L"))

        for raw in [hex, "0x" + hex, uncompressedWIF, kWIF, lWIF] {
            let keyData = try BitcoinPrivateKeyProbe.decode(raw)
            let address = try BitcoinPrivateKeyProbe.address(fromPrivateKey: keyData)
            #expect(AnyAddress.isValid(string: address, coin: .bitcoin))
        }
    }

    @Test("Live Electrum gap-20 scan returns UTXO/history payloads in parallel")
    func liveElectrumGap20Scan() async throws {
        let markerPath = "/tmp/aperture_live_electrum_probe"
        let shouldRunLiveProbe = ProcessInfo.processInfo.environment["APERTURE_LIVE_ELECTRUM_PROBE"] == "1"
            || FileManager.default.fileExists(atPath: markerPath)
        guard shouldRunLiveProbe else {
            print("[BitcoinHDProbe] Skipped live Electrum probe. Set APERTURE_LIVE_ELECTRUM_PROBE=1 or create \(markerPath) to run it.")
            return
        }

        let derived = try BitcoinHDProbe.deriveFromMnemonic(Self.mnemonic, gapLimit: Self.gapLimit)
        let largeGap = 167
        let largeDerived = try BitcoinHDProbe.deriveFromMnemonic(Self.mnemonic, gapLimit: largeGap)
        let result = try await ElectrumProbeClient.scanFirst(
            servers: ElectrumProbeServer.defaults,
            addresses: derived.addresses,
            largeAddresses: largeDerived.addresses
        )
        let scans = result.scans
        let confirmed = scans.reduce(Int64(0)) { $0 + $1.confirmedSats }
        let unconfirmed = scans.reduce(Int64(0)) { $0 + $1.unconfirmedSats }
        let historyCount = scans.reduce(0) { $0 + $1.historyCount }

        #expect(scans.count == derived.addresses.count)
        #expect(scans.allSatisfy { $0.utxoCount >= 0 && $0.historyCount >= 0 })

        print("""
        [BitcoinHDProbe] server=\(result.serverDescription)
        [BitcoinHDProbe] scannedAddresses=\(scans.count) gap=\(Self.gapLimit) accounts=xpub/ypub/zpub branches=receive/change
        [BitcoinHDProbe] elapsedMS=\(result.elapsedMS) confirmedSats=\(confirmed) unconfirmedSats=\(unconfirmed) historyEntries=\(historyCount)
        [BitcoinHDProbe] qrReceiveAddress=\(derived.qrReceiveAddress.path) \(derived.qrReceiveAddress.address)
        """)

        let largeScans = result.largeScans
        #expect(largeScans.count == largeDerived.addresses.count)
        print("""
        [BitcoinHDProbe] largeBatchServer=\(result.serverDescription)
        [BitcoinHDProbe] largeBatchAddresses=\(largeScans.count) requests=\(largeScans.count * 2) gap=\(largeGap)
        [BitcoinHDProbe] largeBatchElapsedMS=\(result.largeElapsedMS)
        """)
    }
}

private enum BitcoinAccountKind: CaseIterable, Sendable {
    case bip44
    case bip49
    case bip84

    var purpose: Purpose {
        switch self {
        case .bip44: return .bip44
        case .bip49: return .bip49
        case .bip84: return .bip84
        }
    }

    var publicVersion: HDVersion {
        switch self {
        case .bip44: return .xpub
        case .bip49: return .ypub
        case .bip84: return .zpub
        }
    }

    var privateVersion: HDVersion {
        switch self {
        case .bip44: return .xprv
        case .bip49: return .yprv
        case .bip84: return .zprv
        }
    }

    var publicPrefix: String {
        switch self {
        case .bip44: return "xpub"
        case .bip49: return "ypub"
        case .bip84: return "zpub"
        }
    }

    var privatePrefix: String {
        switch self {
        case .bip44: return "xprv"
        case .bip49: return "yprv"
        case .bip84: return "zprv"
        }
    }
}

private struct BitcoinHDProbe: Sendable {
    struct Account: Sendable {
        let kind: BitcoinAccountKind
        let extendedPrivateKey: String
        let extendedPublicKey: String
        let convertedPublicKey: String
    }

    struct DerivedAddress: Sendable {
        let kind: BitcoinAccountKind
        let change: UInt32
        let index: UInt32
        let path: String
        let address: String
    }

    let accounts: [Account]
    let addresses: [DerivedAddress]
    let qrReceiveAddress: DerivedAddress

    static func deriveFromMnemonic(_ mnemonic: String, gapLimit: Int) throws -> BitcoinHDProbe {
        guard let wallet = HDWallet(mnemonic: mnemonic, passphrase: "") else {
            throw ProbeError.invalidMnemonic
        }

        var accounts: [Account] = []
        var addresses: [DerivedAddress] = []

        for kind in BitcoinAccountKind.allCases {
            let privateKey = wallet.getExtendedPrivateKey(
                purpose: kind.purpose,
                coin: .bitcoin,
                version: kind.privateVersion
            )
            let publicKey = wallet.getExtendedPublicKey(
                purpose: kind.purpose,
                coin: .bitcoin,
                version: kind.publicVersion
            )
            let convertedPublicKey = try ExtendedPrivateKeyProbeConverter.publicExtendedKey(from: privateKey)
            accounts.append(Account(
                kind: kind,
                extendedPrivateKey: privateKey,
                extendedPublicKey: publicKey,
                convertedPublicKey: convertedPublicKey
            ))

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
                        throw ProbeError.derivationFailed(path)
                    }
                    addresses.append(DerivedAddress(
                        kind: kind,
                        change: change,
                        index: index,
                        path: path,
                        address: try address(publicKey: childPublicKey, kind: kind)
                    ))
                }
            }
        }

        guard let qrReceiveAddress = addresses.first(where: {
            $0.kind == .bip84 && $0.change == 0 && $0.index == 0
        }) else {
            throw ProbeError.derivationFailed("m/84'/0'/0'/0/0")
        }

        return BitcoinHDProbe(accounts: accounts, addresses: addresses, qrReceiveAddress: qrReceiveAddress)
    }

    private static func address(publicKey: PublicKey, kind: BitcoinAccountKind) throws -> String {
        switch kind {
        case .bip44:
            guard let address = BitcoinAddress(publicKey: publicKey, prefix: CoinType.bitcoin.p2pkhPrefix) else {
                throw ProbeError.addressFailed
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

private enum ExtendedPrivateKeyProbeConverter {
    private static let versionMap: [UInt32: UInt32] = [
        0x0488_ADE4: 0x0488_B21E, // xprv -> xpub
        0x049D_7878: 0x049D_7CB2, // yprv -> ypub
        0x04B2_430C: 0x04B2_4746  // zprv -> zpub
    ]

    static func publicExtendedKey(from privateExtendedKey: String) throws -> String {
        guard let payload = WalletCore.Base58.decode(string: privateExtendedKey), payload.count == 78 else {
            throw ProbeError.invalidExtendedKey
        }
        let privateVersion = payload.apertureProbeUInt32BE(at: 0)
        guard let publicVersion = versionMap[privateVersion] else {
            throw ProbeError.unsupportedExtendedPrivateVersion(privateVersion)
        }

        let privateKeyPayload = payload.subdata(in: 45..<78)
        guard privateKeyPayload.count == 33, privateKeyPayload.first == 0 else {
            throw ProbeError.invalidExtendedKey
        }
        let privateKeyData = privateKeyPayload.dropFirst()
        guard let privateKey = PrivateKey(data: Data(privateKeyData)) else {
            throw ProbeError.invalidPrivateKey
        }
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true).data
        guard publicKey.count == 33 else {
            throw ProbeError.invalidPublicKey
        }

        var publicPayload = Data()
        publicPayload.append(publicVersion.apertureProbeBigEndianData)
        publicPayload.append(payload.subdata(in: 4..<45))
        publicPayload.append(publicKey)
        return WalletCore.Base58.encode(data: publicPayload)
    }
}

private enum WIFProbe {
    static func wif(privateKey: Data, compressed: Bool) throws -> String {
        guard privateKey.count == 32 else { throw ProbeError.invalidPrivateKey }
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
        throw ProbeError.invalidPrivateKey
    }
}

private enum BitcoinPrivateKeyProbe {
    static func decode(_ raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        if hex.count == 64, hex.allSatisfy(\.isHexDigit), let data = Data(apertureProbeHex: hex) {
            return try validate(data)
        }

        guard let payload = WalletCore.Base58.decode(string: trimmed) else {
            throw ProbeError.invalidPrivateKey
        }
        let isUncompressedWIF = payload.count == 33
        let isCompressedWIF = payload.count == 34 && payload.last == 0x01
        guard payload.first == 0x80, isUncompressedWIF || isCompressedWIF else {
            throw ProbeError.invalidPrivateKey
        }
        return try validate(Data(payload.dropFirst().prefix(32)))
    }

    static func address(fromPrivateKey keyData: Data) throws -> String {
        guard let privateKey = PrivateKey(data: try validate(keyData)) else {
            throw ProbeError.invalidPrivateKey
        }
        return AnyAddress(
            publicKey: privateKey.getPublicKey(coinType: .bitcoin),
            coin: .bitcoin
        ).description
    }

    private static func validate(_ keyData: Data) throws -> Data {
        guard keyData.count == 32,
              PrivateKey.isValid(data: keyData, curve: CoinType.bitcoin.curve) else {
            throw ProbeError.invalidPrivateKey
        }
        return keyData
    }
}

private struct ElectrumProbeServer: Sendable {
    let host: String
    let port: UInt16
    let tls: Bool

    static let defaults: [ElectrumProbeServer] = [
        ElectrumProbeServer(host: "fulcrum.grey.pw", port: 51002, tls: true),
        ElectrumProbeServer(host: "electrum.blockstream.info", port: 50002, tls: true),
        ElectrumProbeServer(host: "bitcoin.lu.ke", port: 50002, tls: true),
        ElectrumProbeServer(host: "electrum.emzy.de", port: 50002, tls: true),
        ElectrumProbeServer(host: "mainnet.foundationdevices.com", port: 50002, tls: true),
        ElectrumProbeServer(host: "btc.lastingcoin.net", port: 50002, tls: true),
        ElectrumProbeServer(host: "vmd71287.contaboserver.net", port: 50002, tls: true),
        ElectrumProbeServer(host: "de.poiuty.com", port: 50002, tls: true),
        ElectrumProbeServer(host: "electrum.jochen-hoenicke.de", port: 50006, tls: true),
        ElectrumProbeServer(host: "btc.cr.ypto.tech", port: 50002, tls: true),
        ElectrumProbeServer(host: "e.keff.org", port: 50002, tls: true),
        ElectrumProbeServer(host: "vmd104014.contaboserver.net", port: 50002, tls: true),
        ElectrumProbeServer(host: "e2.keff.org", port: 50002, tls: true),
        ElectrumProbeServer(host: "fulcrum.sethforprivacy.com", port: 50002, tls: true),
        ElectrumProbeServer(host: "electrum.coinext.com.br", port: 50002, tls: true)
    ]
}

private actor ElectrumProbeClient {
    private let server: ElectrumProbeServer
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Aperture.ElectrumProbeClient")
    private var receiveBuffer = Data()
    private var nextID = 1
    private var pending: [Int: @Sendable (Result<JSONValue, Error>) -> Void] = [:]

    var serverDescription: String {
        "\(server.host):\(server.port)"
    }

    private init(server: ElectrumProbeServer) {
        self.server = server
        let parameters: NWParameters = server.tls ? .tls : .tcp
        self.connection = NWConnection(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: parameters
        )
    }

    static func connectFirst(to servers: [ElectrumProbeServer]) async throws -> ElectrumProbeClient {
        var lastError: Error?
        for server in servers {
            do {
                return try await connect(to: server)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ProbeError.electrumConnectionFailed
    }

    static func connect(to server: ElectrumProbeServer) async throws -> ElectrumProbeClient {
        let client = ElectrumProbeClient(server: server)
        do {
            try await client.connect()
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    static func scanFirst(
        servers: [ElectrumProbeServer],
        addresses: [BitcoinHDProbe.DerivedAddress],
        largeAddresses: [BitcoinHDProbe.DerivedAddress]
    ) async throws -> ElectrumLiveProbeResult {
        var lastError: Error?
        for server in servers {
            do {
                let client = try await connect(to: server)
                defer { Task { await client.close() } }
                let started = Date()
                let scans = try await client.scan(addresses: addresses)
                let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
                let largeStarted = Date()
                let largeScans = try await client.scan(addresses: largeAddresses)
                let largeElapsedMS = Int(Date().timeIntervalSince(largeStarted) * 1_000)
                return ElectrumLiveProbeResult(
                    serverDescription: "\(server.host):\(server.port)",
                    scans: scans,
                    elapsedMS: elapsedMS,
                    largeScans: largeScans,
                    largeElapsedMS: largeElapsedMS
                )
            } catch {
                lastError = error
                print("[BitcoinHDProbe] serverFailed=\(server.host):\(server.port) error=\(error)")
            }
        }
        throw lastError ?? ProbeError.electrumConnectionFailed
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeBox = ProbeContinuationBox()
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
                    continuation.resume(throwing: ProbeError.electrumConnectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard resumeBox.resumeOnce() else { return }
                connection.cancel()
                continuation.resume(throwing: ProbeError.electrumRequestTimedOut("connect(\(server.host):\(server.port))"))
            }
        }
        _ = try await request(method: "server.version", params: [.string("ApertureProbe"), .string("1.4")])
    }

    func close() {
        connection.cancel()
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(ProbeError.electrumConnectionFailed))
        }
    }

    func scan(addresses: [BitcoinHDProbe.DerivedAddress]) async throws -> [ElectrumAddressScan] {
        let started = Date()
        let indexedAddresses = try addresses.map { address in
            (address: address, scriptHash: try Self.scriptHash(for: address.address))
        }
        let unspentRequests = indexedAddresses.map { item in
            ElectrumBatchRequestSpec(
                method: "blockchain.scripthash.listunspent",
                params: [.string(item.scriptHash)]
            )
        }
        let historyRequests = indexedAddresses.map { item in
            ElectrumBatchRequestSpec(
                method: "blockchain.scripthash.get_history",
                params: [.string(item.scriptHash)]
            )
        }
        let unspentResponses = try await requestBatch(unspentRequests)
        let historyResponses = try await requestBatch(historyRequests)
        let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)

        var scans: [ElectrumAddressScan] = []
        scans.reserveCapacity(indexedAddresses.count)
        for index in indexedAddresses.indices {
            let item = indexedAddresses[index]
            guard case let .array(utxoItems) = unspentResponses[index].result,
                  case let .array(historyItems) = historyResponses[index].result else {
                throw ProbeError.invalidElectrumResponse
            }
            let utxoList = try utxoItems.map(ElectrumUTXO.init(json:))
            let historyList = try historyItems.map(ElectrumHistoryItem.init(json:))
            let confirmedSats = utxoList
                .filter { $0.height > 0 }
                .reduce(Int64(0)) { $0 + $1.valueSats }
            let unconfirmedSats = utxoList
                .filter { $0.height <= 0 }
                .reduce(Int64(0)) { $0 + $1.valueSats }

            scans.append(ElectrumAddressScan(
                address: item.address.address,
                path: item.address.path,
                scriptHash: item.scriptHash,
                confirmedSats: confirmedSats,
                unconfirmedSats: unconfirmedSats,
                utxoCount: utxoList.count,
                historyCount: historyList.count,
                elapsedMS: elapsedMS
            ))
        }
        return scans.sorted { $0.path < $1.path }
    }

    private static func scriptHash(for address: String) throws -> String {
        let script = BitcoinScript.lockScriptForAddress(address: address, coin: .bitcoin).data
        guard !script.isEmpty else { throw ProbeError.invalidAddress(address) }
        let digest = SHA256.hash(data: script)
        return Data(Data(digest).reversed()).apertureProbeHex
    }

    private func listUnspent(scriptHash: String) async throws -> [ElectrumUTXO] {
        let result = try await request(
            method: "blockchain.scripthash.listunspent",
            params: [.string(scriptHash)]
        )
        guard case let .array(items) = result else { throw ProbeError.invalidElectrumResponse }
        return try items.map(ElectrumUTXO.init(json:))
    }

    private func history(scriptHash: String) async throws -> [ElectrumHistoryItem] {
        let result = try await request(
            method: "blockchain.scripthash.get_history",
            params: [.string(scriptHash)]
        )
        guard case let .array(items) = result else { throw ProbeError.invalidElectrumResponse }
        return try items.map(ElectrumHistoryItem.init(json:))
    }

    private func request(method: String, params: [JSONValue]) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let request = ElectrumJSONRequest(id: id, method: method, params: params)
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            pending[id] = { result in
                continuation.resume(with: result)
            }
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.resume(id: id, throwing: error) }
            })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                await self?.resume(id: id, throwing: ProbeError.electrumRequestTimedOut(method))
            }
        }
    }

    private func requestBatch(_ specs: [ElectrumBatchRequestSpec]) async throws -> [ElectrumBatchResponse] {
        var requests: [ElectrumPendingBatchRequest] = []
        var wireRequests: [ElectrumJSONRequest] = []
        requests.reserveCapacity(specs.count)
        wireRequests.reserveCapacity(specs.count)
        for spec in specs {
            let id = nextID
            nextID += 1
            wireRequests.append(ElectrumJSONRequest(id: id, method: spec.method, params: spec.params))
            requests.append(ElectrumPendingBatchRequest(id: id, spec: spec))
        }
        var payload = try JSONEncoder().encode(wireRequests)
        payload.append(0x0A)

        let ids = requests.map(\.id)
        let batchBox = ElectrumBatchResponseBox(ids: ids)
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
            await self?.fail(ids: ids, error: ProbeError.electrumRequestTimedOut("batch(\(specs.count))"))
        }

        let results = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Int: JSONValue], Error>) in
            batchBox.wait(continuation)
        }
        return try requests.map { request in
            guard let result = results[request.id] else {
                throw ProbeError.invalidElectrumResponse
            }
            return ElectrumBatchResponse(id: request.id, result: result)
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
                    await self?.failAll(ProbeError.electrumConnectionFailed)
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
                    let responses = try JSONDecoder().decode([ElectrumJSONResponse].self, from: line)
                    for response in responses {
                        handle(response)
                    }
                } else {
                    let response = try JSONDecoder().decode(ElectrumJSONResponse.self, from: line)
                    handle(response)
                }
            } catch {
                failAll(error)
            }
        }
    }

    private func handle(_ response: ElectrumJSONResponse) {
        guard let id = response.id else { return }
        if let error = response.error {
            resume(id: id, throwing: ProbeError.electrumRPCError(error.message))
        } else if let result = response.result {
            resume(id: id, returning: result)
        } else {
            resume(id: id, throwing: ProbeError.invalidElectrumResponse)
        }
    }

    private func resume(id: Int, returning value: JSONValue) {
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

private struct ElectrumBatchRequestSpec: Sendable {
    let method: String
    let params: [JSONValue]
}

private struct ElectrumPendingBatchRequest: Sendable {
    let id: Int
    let spec: ElectrumBatchRequestSpec
}

private struct ElectrumBatchResponse: Sendable {
    let id: Int
    let result: JSONValue
}

private final class ElectrumBatchResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<Int>
    private var results: [Int: JSONValue] = [:]
    private var continuation: CheckedContinuation<[Int: JSONValue], Error>?
    private var completion: Result<[Int: JSONValue], Error>?

    init(ids: [Int]) {
        self.remaining = Set(ids)
    }

    func wait(_ continuation: CheckedContinuation<[Int: JSONValue], Error>) {
        lock.lock()
        if let completion {
            lock.unlock()
            continuation.resume(with: completion)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func complete(id: Int, result: Result<JSONValue, Error>) {
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
            let finalResults = results
            completion = .success(finalResults)
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

private struct ElectrumAddressScan: Sendable {
    let address: String
    let path: String
    let scriptHash: String
    let confirmedSats: Int64
    let unconfirmedSats: Int64
    let utxoCount: Int
    let historyCount: Int
    let elapsedMS: Int
}

private struct ElectrumLiveProbeResult: Sendable {
    let serverDescription: String
    let scans: [ElectrumAddressScan]
    let elapsedMS: Int
    let largeScans: [ElectrumAddressScan]
    let largeElapsedMS: Int
}

private struct ElectrumUTXO: Sendable {
    let txHash: String
    let txPosition: Int
    let height: Int
    let valueSats: Int64

    init(json: JSONValue) throws {
        guard case let .object(object) = json,
              let txHash = object["tx_hash"]?.stringValue,
              let txPosition = object["tx_pos"]?.intValue,
              let height = object["height"]?.intValue,
              let valueSats = object["value"]?.int64Value else {
            throw ProbeError.invalidElectrumResponse
        }
        self.txHash = txHash
        self.txPosition = txPosition
        self.height = height
        self.valueSats = valueSats
    }
}

private struct ElectrumHistoryItem: Sendable {
    let txHash: String
    let height: Int

    init(json: JSONValue) throws {
        guard case let .object(object) = json,
              let txHash = object["tx_hash"]?.stringValue,
              let height = object["height"]?.intValue else {
            throw ProbeError.invalidElectrumResponse
        }
        self.txHash = txHash
        self.height = height
    }
}

private struct ElectrumJSONRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [JSONValue]
}

private struct ElectrumJSONResponse: Decodable {
    let id: Int?
    let result: JSONValue?
    let error: ElectrumJSONError?
}

private struct ElectrumJSONError: Decodable {
    let code: Int?
    let message: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let message = try? container.decode(String.self) {
            self.code = nil
            self.message = message
            return
        }

        if let object = try? container.decode([String: JSONValue].self) {
            self.code = object["code"]?.intValue
            self.message = object["message"]?.stringValue
                ?? object["error"]?.stringValue
                ?? "\(object)"
            return
        }

        if let value = try? container.decode(JSONValue.self) {
            self.code = nil
            self.message = "\(value)"
            return
        }

        throw ProbeError.invalidElectrumResponse
    }
}

private enum JSONValue: Codable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
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
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw ProbeError.invalidElectrumResponse
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

private enum ProbeError: Error, CustomStringConvertible {
    case invalidMnemonic
    case invalidExtendedKey
    case unsupportedExtendedPrivateVersion(UInt32)
    case invalidPrivateKey
    case invalidPublicKey
    case derivationFailed(String)
    case addressFailed
    case invalidAddress(String)
    case electrumConnectionFailed
    case electrumRequestTimedOut(String)
    case electrumRPCError(String)
    case invalidElectrumResponse

    var description: String {
        switch self {
        case .invalidMnemonic:
            return "Invalid mnemonic"
        case .invalidExtendedKey:
            return "Invalid extended key"
        case .unsupportedExtendedPrivateVersion(let version):
            return "Unsupported extended private-key version: \(String(format: "0x%08x", version))"
        case .invalidPrivateKey:
            return "Invalid private key"
        case .invalidPublicKey:
            return "Invalid public key"
        case .derivationFailed(let path):
            return "Derivation failed for \(path)"
        case .addressFailed:
            return "Address derivation failed"
        case .invalidAddress(let address):
            return "Invalid Bitcoin address: \(address)"
        case .electrumConnectionFailed:
            return "Electrum connection failed"
        case .electrumRequestTimedOut(let method):
            return "Electrum request timed out: \(method)"
        case .electrumRPCError(let message):
            return "Electrum RPC error: \(message)"
        case .invalidElectrumResponse:
            return "Invalid Electrum response"
        }
    }
}

private final class ProbeContinuationBox: @unchecked Sendable {
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

    var apertureProbeHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    func apertureProbeUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    init?(apertureProbeHex hex: String) {
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

private extension UInt32 {
    var apertureProbeBigEndianData: Data {
        Data([
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ])
    }
}
