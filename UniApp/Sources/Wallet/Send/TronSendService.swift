import Foundation
import SwiftData
import WalletCore

/// Real TRON send — native TRX (TransferContract) and TRC-20
/// (TransferTRC20Contract). One implementation; `isNative` differentiates.
///
/// Pipeline (per `/tmp/recipe-tron.md`): fetch the latest block header
/// (`wallet/getnowblock`) + resources/fee context → derive key via
/// `ChainKeyProvider` → build a `TronSigningInput` exactly as the proven
/// Stabro signer (timestamp / expiration / feeLimit / blockHeader) →
/// `AnySigner.sign(.tron)` → `output.json` is the signed-tx JSON +
/// `output.id` is the txid → broadcast the signed-tx object via
/// `wallet/broadcasttransaction` → poll `wallet/gettransactionbyid`.
///
/// **Resource-fee model (not gas).** TRON pays bandwidth/energy, not a
/// per-gas market. There are no slow/normal/fast tiers — `loadFees`
/// returns a single `.normal` option with a realistic TRX estimate
/// (free if staked/free resources cover it, else the bandwidth/energy
/// deficit converted to TRX). A fee-estimate fetch failure never throws;
/// it falls back to the recipe default (Rule #16 / Rule #26).
///
/// **Off-main (Rule #28).** Every RPC + the seed-stretch + signing run
/// off the main actor; only the small `Sendable` result crosses back.
/// **Honest (Rule #16 / Rule #26).** A node rejection surfaces its real
/// (hex-decoded) reason; nothing key-, mnemonic-, or signature-shaped is
/// ever logged.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet test send on-device —
/// the crypto is wallet-core's; this wiring is exercised by that send.
enum TronSendService {

    // MARK: - Constants (per recipe)

    /// Native TRX simple-transfer bandwidth cost in bytes.
    private static let nativeBandwidthBytes: Int64 = 267
    /// Typical TRC-20 transfer bandwidth cost in bytes.
    private static let trc20BandwidthBytes: Int64 = 345
    /// Default energy price (SUN per unit) when `getEnergyFee` is absent.
    private static let defaultEnergyPriceSun: Int64 = 100
    /// Fallback energy for a TRC-20 transfer when simulation fails
    /// (USDT-with-penalty class — recipe gotcha #2/#9).
    private static let fallbackTrc20Energy: Int64 = 64_000
    /// feeLimit caps (SUN) — a ceiling, not a charge (recipe gotcha #6).
    private static let nativeFeeLimitSun: Int64 = 1_000_000      // 1 TRX
    private static let trc20FeeLimitSun: Int64 = 150_000_000     // 150 TRX
    /// Transaction validity window after the block timestamp (recipe
    /// gotcha #3) — 10 minutes, mirroring Stabro.
    private static let expirationWindowMs: Int64 = 600_000

    // MARK: - Off-main orchestration (called from the @MainActor view-model)

    /// Estimate the TRON fee in TRX. TRON has no speed tiers — returns a
    /// single `.normal` option. Never throws on an estimate failure;
    /// uses the recipe default so the Send flow always has a number.
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        let from = try ChainKeyProvider.senderAddress(for: chain, container: container)
        let feeTRX = await estimateFeeTRX(
            from: from, toAddress: toAddress, rawAmount: rawAmount,
            isNative: isNative, contract: contract
        )
        return [
            ChainFeeOption(
                speed: .normal,
                feeNative: feeTRX,
                estimatedSeconds: 30,   // ~10 blocks at 3 s; confirms fast
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        ]
    }

    /// Full send: fetch the latest block header (as late as possible so
    /// the ref-block is fresh — recipe gotcha #3/#4), derive the key,
    /// build + sign the TronSigningInput exactly as Stabro, broadcast the
    /// signed-tx object, and return the txid.
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        // 1. Latest block header — fetched immediately before signing so
        //    the ref-block hasn't gone stale (TRON tx expire in ~10 min).
        let block = try await fetchLatestBlock()

        // 2. Signing material (mnemonic → key + sender address), off-main.
        let (key, fromAddress) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // 3. Build the TronSigningInput — mirrors Stabro
        //    `signTronTransaction` (TransactionSigner.swift:410–475).
        var input = TronSigningInput()
        input.privateKey = key.data

        var transaction = TronTransaction()

        if isNative {
            // Native TRX transfer (TransferContract). rawAmount is already
            // in SUN; the proto amount is Int64 SUN.
            var transfer = TronTransferContract()
            transfer.ownerAddress = fromAddress
            transfer.toAddress = toAddress
            guard let amountSun = Int64(rawAmount) else {
                throw .signingFailed("Invalid TRX amount.")
            }
            transfer.amount = amountSun
            transaction.transfer = transfer
        } else {
            // TRC-20 token transfer (TransferTRC20Contract). The proto
            // `amount` is raw big-endian bytes of the smallest-unit amount
            // (built ourselves per the brief — no Stabro ABIEncoder).
            guard let contractAddress = contract, !contractAddress.isEmpty else {
                throw .signingFailed("Missing token contract for TRC-20 send.")
            }
            var trc20 = TronTransferTRC20Contract()
            trc20.contractAddress = contractAddress
            trc20.ownerAddress = fromAddress
            trc20.toAddress = toAddress
            trc20.amount = bigEndianData(fromDecimalString: rawAmount)
            transaction.transferTrc20Contract = trc20
        }

        // Timestamp + expiration window (mirrors Stabro).
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        transaction.timestamp = nowMs
        transaction.expiration = nowMs + expirationWindowMs
        // feeLimit: cap, not a charge. Native uses bandwidth; TRC-20 needs
        // an energy ceiling.
        transaction.feeLimit = isNative ? nativeFeeLimitSun : trc20FeeLimitSun

        // Block header from the freshly-fetched block (the ref-block the
        // node validates the tx against). Stabro routes these via a JSON
        // blob; here we set the fields directly from the parsed block.
        var blockHeader = TronBlockHeader()
        blockHeader.timestamp = block.timestamp
        blockHeader.number = block.number
        blockHeader.version = block.version
        blockHeader.txTrieRoot = Data(hexString: block.txTrieRootHex) ?? Data()
        blockHeader.parentHash = Data(hexString: block.parentHashHex) ?? Data()
        blockHeader.witnessAddress = Data(hexString: block.witnessAddressHex) ?? Data()
        transaction.blockHeader = blockHeader

        input.transaction = transaction

        // 4. Sign.
        let output: TronSigningOutput = AnySigner.sign(input: input, coin: .tron)
        guard !output.json.isEmpty else {
            throw .signingFailed("Signing returned an empty transaction.")
        }
        let signedJSON = output.json
        let txid = output.id.hexString   // hex txid (recipe: output.id)

        // 5. Broadcast — the body is the EXACT signed-tx object the signer
        //    produced (the parsed `output.json`), POSTed to
        //    wallet/broadcasttransaction.
        try await broadcast(signedJSON: signedJSON)

        // The node assigns/echoes the txid; we trust the locally-derived
        // `output.id` (it's the canonical TRON txID hash). Empty guard for
        // safety.
        return ChainSignedTransaction(
            broadcastPayload: signedJSON,
            txHash: txid.isEmpty ? "" : txid
        )
    }

    /// Poll the transaction by id. Native confirms once it's in a block;
    /// TRC-20 confirms only when `ret[0].contractRet == "SUCCESS"`.
    nonisolated static func status(
        chain: SupportedChain, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        let body: [String: Sendable] = ["value": txHash, "visible": true]
        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPost(
                chain: .tron, path: "wallet/gettransactionbyid", body: body
            )
        } catch {
            throw mapRPC(error)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !json.isEmpty else {
            // Empty `{}` / not-found → not yet indexed; still pending.
            return .pending
        }

        // `ret` is an array of contract results. `contractRet` carries the
        // execution outcome for the (single) contract in the tx.
        if let ret = json["ret"] as? [[String: Any]],
           let first = ret.first,
           let contractRet = first["contractRet"] as? String {
            switch contractRet.uppercased() {
            case "SUCCESS":
                return .confirmed(blockNumber: nil)
            case "":
                // Present but empty — node has the tx, execution result not
                // yet finalized. Treat as pending.
                return .pending
            default:
                // REVERT / OUT_OF_ENERGY / BAD_JUMP_DESTINATION / etc.
                return .failed(reason: humanContractRet(contractRet))
            }
        }

        // The tx is known to the node (non-empty body) but has no `ret`
        // result yet — still pending inclusion/execution.
        return .pending
    }

    // MARK: - Block header fetch

    /// Parsed block-header fields needed to populate `TronBlockHeader`.
    private struct LatestBlock: Sendable {
        let timestamp: Int64
        let number: Int64
        let version: Int32
        let txTrieRootHex: String
        let parentHashHex: String
        let witnessAddressHex: String
    }

    /// `POST wallet/getnowblock` → parse `block_header.raw_data`.
    private nonisolated static func fetchLatestBlock() async throws(ChainSendError) -> LatestBlock {
        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPost(
                chain: .tron, path: "wallet/getnowblock", body: [:]
            )
        } catch {
            throw mapRPC(error)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["block_header"] as? [String: Any],
              let raw = header["raw_data"] as? [String: Any] else {
            throw .missingContext("getnowblock")
        }

        let number = int64(raw["number"]) ?? 0
        let timestamp = int64(raw["timestamp"]) ?? 0
        let version = Int32(int64(raw["version"]) ?? 0)
        let txTrieRoot = (raw["txTrieRoot"] as? String) ?? ""
        let parentHash = (raw["parentHash"] as? String) ?? ""
        let witnessAddress = (raw["witness_address"] as? String) ?? ""

        // A header with no number is not a usable ref-block.
        guard number > 0 else { throw .missingContext("getnowblock") }

        return LatestBlock(
            timestamp: timestamp,
            number: number,
            version: version,
            txTrieRootHex: txTrieRoot,
            parentHashHex: parentHash,
            witnessAddressHex: witnessAddress
        )
    }

    // MARK: - Broadcast

    /// POST the signed-tx object to `wallet/broadcasttransaction`. The body
    /// must be the EXACT signed-tx the signer produced, so we POST the raw
    /// `output.json` bytes verbatim (no dict round-trip — that would force
    /// a non-`Sendable` `[String: Any]` cast and risk re-ordering the
    /// signed object). On a `result != true` response, throw
    /// `.broadcastRejected` with the real (hex-decoded) message
    /// (Rule #16 / Rule #26).
    private nonisolated static func broadcast(signedJSON: String) async throws(ChainSendError) {
        guard let body = signedJSON.data(using: .utf8) else {
            throw .signingFailed("Signed transaction is not valid JSON.")
        }

        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPostRaw(
                chain: .tron, path: "wallet/broadcasttransaction",
                body: body, contentType: "application/json"
            )
        } catch {
            throw mapRPC(error)
        }

        let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let result = response?["result"] as? Bool, result == true {
            return
        }
        // Rejected. Decode the reason: `message` (often hex-encoded UTF-8)
        // or `code`.
        let reason = rejectionReason(from: response)
        throw .broadcastRejected(reason)
    }

    private nonisolated static func rejectionReason(from response: [String: Any]?) -> String {
        if let messageHex = response?["message"] as? String, !messageHex.isEmpty {
            if let decoded = decodeHexMessage(messageHex) { return decoded }
            return messageHex
        }
        if let code = response?["code"] as? String, !code.isEmpty {
            return "The network rejected the transaction (\(code))."
        }
        return "The network rejected the transaction. Try again."
    }

    // MARK: - Fee estimation (TRX)

    /// Estimate the TRX fee. Never throws — on any fetch failure returns
    /// the recipe default (native ~0.267 TRX without bandwidth; TRC-20 the
    /// energy fallback × price).
    private nonisolated static func estimateFeeTRX(
        from: String, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?
    ) async -> Decimal {
        let resources = await fetchAccountResources(address: from)

        if isNative {
            // Native: bandwidth. Free if free/staked bandwidth covers 267 B.
            let available = resources?.freeBandwidth ?? 0
            if available >= nativeBandwidthBytes { return 0 }
            // ~0.267 TRX (267 bytes / 1000).
            return Decimal(nativeBandwidthBytes) / 1000
        }

        // TRC-20: simulate energy, compare with free energy, convert
        // deficit × energy price (SUN) → TRX.
        guard let contractAddress = contract, !contractAddress.isEmpty else {
            return 0
        }
        async let energyTask = simulateTRC20Energy(
            from: from, to: toAddress, contractAddress: contractAddress, rawAmount: rawAmount
        )
        async let priceTask = fetchEnergyPriceSun()

        let energyUsed = await energyTask
        let energyPriceSun = await priceTask
        let energyAvailable = resources?.freeEnergy ?? 0
        let energyDeficit = max(energyUsed - energyAvailable, 0)
        if energyDeficit == 0 { return 0 }
        return (Decimal(energyDeficit) * Decimal(energyPriceSun)) / 1_000_000
    }

    private struct AccountResources: Sendable {
        let freeBandwidth: Int64
        let freeEnergy: Int64
    }

    /// `POST wallet/getaccountresource` → free bandwidth + energy.
    /// Returns nil on any failure (caller falls back to a paid estimate).
    private nonisolated static func fetchAccountResources(address: String) async -> AccountResources? {
        let body: [String: Sendable] = ["address": address, "visible": true]
        guard let data = try? await RPCClient.shared.callRESTPost(
            chain: .tron, path: "wallet/getaccountresource", body: body
        ),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        // freeNetLimit/freeNetUsed → remaining free bandwidth.
        let freeNetLimit = int64(json["freeNetLimit"]) ?? 0
        let freeNetUsed = int64(json["freeNetUsed"]) ?? 0
        let netLimit = int64(json["NetLimit"]) ?? 0
        let netUsed = int64(json["NetUsed"]) ?? 0
        let freeBandwidth = max(freeNetLimit - freeNetUsed, 0) + max(netLimit - netUsed, 0)
        // EnergyLimit/EnergyUsed → remaining (staked) energy.
        let energyLimit = int64(json["EnergyLimit"]) ?? 0
        let energyUsed = int64(json["EnergyUsed"]) ?? 0
        let freeEnergy = max(energyLimit - energyUsed, 0)
        return AccountResources(freeBandwidth: freeBandwidth, freeEnergy: freeEnergy)
    }

    /// `POST wallet/getchainparameters` → `getEnergyFee` (SUN per energy).
    /// Defaults to 100 SUN on any failure (recipe gotcha #7).
    private nonisolated static func fetchEnergyPriceSun() async -> Int64 {
        guard let data = try? await RPCClient.shared.callRESTPost(
            chain: .tron, path: "wallet/getchainparameters", body: [:]
        ),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let params = json["chainParameter"] as? [[String: Any]] else {
            return defaultEnergyPriceSun
        }
        if let entry = params.first(where: { ($0["key"] as? String) == "getEnergyFee" }),
           let value = int64(entry["value"]) {
            return value
        }
        return defaultEnergyPriceSun
    }

    /// `POST wallet/triggerconstantcontract` to simulate `transfer` and
    /// read `energy_used` (includes the dynamic penalty for heavy
    /// contracts like USDT — recipe gotcha #2). Falls back to a default on
    /// failure (recipe gotcha #9).
    private nonisolated static func simulateTRC20Energy(
        from: String, to: String, contractAddress: String, rawAmount: String
    ) async -> Int64 {
        // parameter = 32-byte-padded recipient (full 21-byte hex, left-
        // padded to 64) ‖ 32-byte-padded amount.
        let toFullHex = tronAddressToFullHex(to)
        let paddedTo = String(repeating: "0", count: max(0, 64 - toFullHex.count)) + toFullHex
        let amountHex = bigEndianData(fromDecimalString: rawAmount).map { String(format: "%02x", $0) }.joined()
        let paddedAmount = String(repeating: "0", count: max(0, 64 - amountHex.count)) + amountHex

        let body: [String: Sendable] = [
            "owner_address": from,
            "contract_address": contractAddress,
            "function_selector": "transfer(address,uint256)",
            "parameter": paddedTo + paddedAmount,
            "visible": true,
        ]
        guard let data = try? await RPCClient.shared.callRESTPost(
            chain: .tron, path: "wallet/triggerconstantcontract", body: body
        ),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return fallbackTrc20Energy
        }
        let used = int64(json["energy_used"]) ?? 0
        return used > 0 ? used : fallbackTrc20Energy
    }

    // MARK: - Address conversion (Base58check ↔ full hex)

    /// TRON base58check address → full hex (the 21-byte `41`-prefixed
    /// payload as 42 hex chars). Used for the simulation `parameter`.
    /// Uses WalletCore's checksum-validating `Base58.decode` (returns the
    /// 21-byte payload), mirroring Stabro's `tronAddressToFullHex`.
    private nonisolated static func tronAddressToFullHex(_ address: String) -> String {
        // Already full hex (41 + 20 bytes).
        if address.hasPrefix("41"), address.count == 42,
           address.allSatisfy(\.isHexDigit) {
            return address.lowercased()
        }
        // 0x-prefixed 20-byte EVM-style hex → prepend the 41 version byte.
        if address.hasPrefix("0x"), address.count == 42 {
            return "41" + address.dropFirst(2).lowercased()
        }
        // Base58check → 21-byte payload (0x41 + 20).
        if let decoded = WalletCore.Base58.decode(string: address), decoded.count == 21 {
            return decoded.map { String(format: "%02x", $0) }.joined()
        }
        return address
    }

    // MARK: - Hex / numeric helpers

    /// Robust Int64 extraction from a JSON value that may arrive as
    /// `NSNumber`, `Int`, `Int64`, or a decimal string.
    private nonisolated static func int64(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let i = value as? Int { return Int64(i) }
        if let i = value as? Int64 { return i }
        if let s = value as? String { return Int64(s) }
        return nil
    }

    /// Big-endian bytes of an arbitrary-precision decimal integer string
    /// (a token amount can exceed UInt64). Manual base-256 division — no
    /// Double, no overflow. Mirrors `EVMSendService.bigEndianData(fromDecimalString:)`.
    private nonisolated static func bigEndianData(fromDecimalString decimal: String) -> Data {
        var digits = Array(decimal).compactMap { $0.wholeNumberValue }
        guard !digits.isEmpty else { return Data() }
        var bytesLE: [UInt8] = []
        while !(digits.count == 1 && digits[0] == 0) {
            var remainder = 0
            var next: [Int] = []
            for d in digits {
                let cur = remainder * 10 + d
                let q = cur / 256
                remainder = cur % 256
                if !next.isEmpty || q != 0 { next.append(q) }
            }
            bytesLE.append(UInt8(remainder))
            digits = next.isEmpty ? [0] : next
        }
        return Data(bytesLE.reversed())
    }

    /// Decode a (possibly `0x`-prefixed) hex string to its UTF-8 text —
    /// TRON broadcast errors arrive hex-encoded (recipe gotcha #10).
    private nonisolated static func decodeHexMessage(_ hex: String) -> String? {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard clean.count > 2, clean.count % 2 == 0,
              clean.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8),
              !decoded.isEmpty else { return nil }
        return decoded
    }

    /// A human reason for a non-SUCCESS `contractRet`.
    private nonisolated static func humanContractRet(_ ret: String) -> String {
        switch ret.uppercased() {
        case "REVERT":
            return "The token contract rejected the transfer."
        case "OUT_OF_ENERGY":
            return "Not enough energy to complete the transfer."
        case "OUT_OF_TIME":
            return "The transfer timed out on-chain."
        default:
            return "The transaction failed on-chain (\(ret))."
        }
    }

    // MARK: - Error mapping

    /// Fold an `RPCError` into a `ChainSendError`, preserving an honest
    /// reason where the node supplied one.
    private nonisolated static func mapRPC(_ error: RPCError) -> ChainSendError {
        switch error {
        case .noEndpoint, .allEndpointsFailed, .network, .cancelled:
            return .rpcUnavailable
        case .rateLimited:
            return .rpcUnavailable
        case .invalidResponse(let m), .decodingFailed(let m):
            return .missingContext(m)
        case .rpcError(_, let message):
            return .broadcastRejected(message)
        }
    }
}
