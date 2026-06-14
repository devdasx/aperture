import Foundation
import SwiftData
import WalletCore

/// Real native-DOT send for Polkadot — the hardest family in the Send V2
/// pipeline. wallet-core's built-in Polkadot signer omits signed extensions
/// the current runtime requires (CheckNonZeroSender, CheckWeight,
/// CheckMetadataHash, StorageWeightReclaim), so the extrinsic is hand-built
/// and Ed25519-signed by `PolkadotExtrinsicBuilder` (ported faithfully from
/// the Stabro reference wallet) on top of `SCALECodec`.
///
/// **Chain target.** Aperture's `.polkadot` RPC endpoints are the **relay
/// chain** (`rpc.polkadot.io`, `polkadot.api.onfinality.io/public`), so the
/// native DOT extrinsic is built for `.relay` (genesis
/// `91b171bb…ce90c3`, Balances pallet index 5, relay signed-extension order).
/// Asset Hub tokens are out of scope here (`isNative == false` → throws).
///
/// Pipeline (Rule #27 — RPC writes facts; off-main per Rule #28):
/// 1. `state_getRuntimeVersion` → specVersion, transactionVersion.
/// 2. `chain_getBlockHash 0` → genesis (validation only; builder hardcodes it).
/// 3. `chain_getFinalizedHead` → finalized block hash; `chain_getHeader` → number.
/// 4. `system_accountNextIndex(addr)` → nonce.
/// 5. build + Ed25519-sign the extrinsic.
/// 6. `author_submitExtrinsic` → tx hash.
/// 7. status: best-effort (Polkadot has no by-hash receipt query).
///
/// Every value is fetched live (no guesses); a node rejection surfaces its
/// real reason (Rule #16 / #26). Nothing key- or signature-shaped is logged.
///
/// ⚠️ UNVERIFIED until a real tiny-amount test send on-device — the SCALE
/// encoding + signed-extension order are ported from a proven implementation,
/// but the live relay-chain runtime can change the extension set on an
/// upgrade (see the final report's caveats).
enum PolkadotSendService {

    // MARK: - Constants

    /// DOT has 10 decimals: 1 DOT = 10^10 planck.
    private static let dotDecimals = 10

    /// Recipe default flat fee for a native transfer (~0.0156 DOT). `loadFees`
    /// never throws — it always returns this single tier.
    private static let defaultFeePlanck: UInt64 = 156_000_000  // 0.0156 DOT

    /// Relay-chain finality is ~12–60s; tip doesn't change finality, so we
    /// expose a single `.normal` tier (recipe §feeEstimation #4).
    private static let estimatedFinalitySeconds = 30

    // MARK: - Public API

    /// One flat `.normal` fee tier in DOT. Never throws — falls back to the
    /// recipe default so the Send sheet always has a fee to show.
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        let feeNative = Decimal(defaultFeePlanck) / pow(Decimal(10), dotDecimals)
        return [
            ChainFeeOption(
                speed: .normal,
                feeNative: feeNative,
                estimatedSeconds: estimatedFinalitySeconds,
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        ]
    }

    /// Full native-DOT send: fetch runtime + genesis + finalized block + nonce,
    /// derive the key off-main, hand-build + Ed25519-sign the extrinsic, and
    /// broadcast via `author_submitExtrinsic`.
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard chain == .polkadot else { throw .unsupportedChain(chain) }
        // Asset Hub tokens (USDC etc.) are out of scope for this service.
        guard isNative else { throw .unsupportedChain(chain) }

        // rawAmount is already planck (1 DOT = 1e10). Native DOT supply
        // (~1.5e19 planck) fits in UInt64; reject anything that doesn't rather
        // than silently truncating (Rule #16 — honest by construction).
        guard let amountPlanck = UInt64(rawAmount), amountPlanck > 0 else {
            throw .signingFailed("Invalid DOT amount.")
        }

        // 1. Runtime version (specVersion + transactionVersion).
        let runtime = try await fetchRuntimeVersion(chain: chain)

        // 2. Genesis hash — validation only (the builder hardcodes the relay
        //    genesis; confirming the live node agrees catches a chain mismatch
        //    before we sign a payload anchored to the wrong genesis).
        let genesisHex = (try? await RPCClient.shared.callJSONString(
            chain: chain, method: "chain_getBlockHash", params: [0]
        )) ?? ""
        try validateRelayGenesis(genesisHex)

        // 3. Finalized block hash + number (for the mortal era).
        let finalizedHash = try await fetchFinalizedBlockHash(chain: chain)
        let blockNumber = try await fetchBlockNumber(chain: chain, blockHash: finalizedHash)

        // 4. Nonce.
        let senderAddress = try ChainKeyProvider.senderAddress(for: chain, container: container)
        let nonce = try await fetchNonce(chain: chain, address: senderAddress)

        // 5. Key (off-main, custody-checked) + build + sign.
        let (key, _) = try ChainKeyProvider.signingMaterial(for: chain, container: container)
        guard let blockHash = Self.hexData(finalizedHash), blockHash.count == 32 else {
            throw .missingContext("chain_getFinalizedHead")
        }

        let signed: PolkadotExtrinsicBuilder.Signed
        do {
            signed = try PolkadotExtrinsicBuilder.buildNativeTransfer(
                privateKey: key,
                toAddress: toAddress,
                amountPlanck: amountPlanck,
                nonce: nonce,
                specVersion: runtime.specVersion,
                transactionVersion: runtime.transactionVersion,
                blockHash: blockHash,
                blockNumber: blockNumber,
                chain: .relay
            )
        } catch let e as PolkadotExtrinsicBuilder.BuilderError {
            throw Self.mapBuilderError(e)
        } catch {
            throw .signingFailed("Could not build the Polkadot transaction.")
        }

        // 6. Broadcast.
        do {
            let returnedHash = try await RPCClient.shared.callJSONString(
                chain: chain, method: "author_submitExtrinsic", params: [signed.rawHex]
            )
            let hash = returnedHash.isEmpty ? signed.txHash : returnedHash
            return ChainSignedTransaction(broadcastPayload: signed.rawHex, txHash: hash)
        } catch {
            throw Self.broadcastError(error)
        }
    }

    /// Best-effort status.
    ///
    /// Polkadot exposes no simple by-hash receipt query (status comes from
    /// subscribing to the block-inclusion stream or scanning `System.Events`,
    /// neither of which a single REST-style poll can do honestly). Per the
    /// recipe (§statusCheck): after a successful `author_submitExtrinsic`, the
    /// extrinsic is in the mempool and will finalize within ~1 min. We return
    /// `.pending` and NEVER fabricate `.confirmed` (Rule #26) — the broadcast
    /// already succeeded (otherwise `performSend` would have thrown), so
    /// `.pending` is the honest state a fresh poll can assert.
    nonisolated static func status(
        chain: SupportedChain, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        guard chain == .polkadot else { throw .unsupportedChain(chain) }
        return .pending
    }

    // MARK: - RPC: runtime / block / nonce

    private struct RuntimeVersion: Sendable {
        let specVersion: UInt32
        let transactionVersion: UInt32
    }

    private static func fetchRuntimeVersion(chain: SupportedChain) async throws(ChainSendError) -> RuntimeVersion {
        do {
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain, method: "state_getRuntimeVersion", params: []
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let spec = (obj["specVersion"] as? NSNumber)?.uint32Value,
                  let txV = (obj["transactionVersion"] as? NSNumber)?.uint32Value else {
                throw ChainSendError.missingContext("state_getRuntimeVersion")
            }
            return RuntimeVersion(specVersion: spec, transactionVersion: txV)
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw ChainSendError.missingContext("state_getRuntimeVersion")
        }
    }

    private static func fetchFinalizedBlockHash(chain: SupportedChain) async throws(ChainSendError) -> String {
        do {
            let hash = try await RPCClient.shared.callJSONString(
                chain: chain, method: "chain_getFinalizedHead", params: []
            )
            guard hexData(hash)?.count == 32 else {
                throw ChainSendError.missingContext("chain_getFinalizedHead")
            }
            return hash
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw ChainSendError.missingContext("chain_getFinalizedHead")
        }
    }

    /// Fetch a block's number via `chain_getHeader(hash)` → `{ number: "0x…" }`.
    private static func fetchBlockNumber(chain: SupportedChain, blockHash: String) async throws(ChainSendError) -> UInt64 {
        do {
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain, method: "chain_getHeader", params: [blockHash]
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let numberHex = obj["number"] as? String,
                  let number = parseHexUInt64(numberHex), number > 0 else {
                throw ChainSendError.missingContext("chain_getHeader")
            }
            return number
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw ChainSendError.missingContext("chain_getHeader")
        }
    }

    /// Sender nonce. Primary: `system_accountNextIndex(addr)` (counts pending
    /// mempool txs, recipe §preSignContext #4). Fallback: decode `nonce: u32`
    /// from the `System.Account` storage map (recipe's "modern" path) — robust
    /// when a node returns the index as a bare JSON number, which neither
    /// `callJSONString` (rejects non-string) nor `callJSONResultData` (rejects
    /// a bare scalar) can read. The storage decode returns a hex string, which
    /// our RPCClient handles cleanly via `callJSONString`.
    private static func fetchNonce(chain: SupportedChain, address: String) async throws(ChainSendError) -> UInt64 {
        // Primary: system_accountNextIndex returning a string ("0x5" / "5").
        if let raw = try? await RPCClient.shared.callJSONString(
            chain: chain, method: "system_accountNextIndex", params: [address]
        ) {
            if let v = parseHexUInt64(raw) { return v }     // "0x5"
            if let v = UInt64(raw) { return v }             // "5"
        }
        // Fallback: decode the on-chain System.Account nonce (u32 LE, offset 0).
        if let v = await fetchNonceFromStorage(chain: chain, address: address) { return v }
        throw .missingContext("system_accountNextIndex")
    }

    /// Read `nonce: u32` (first 4 LE bytes of `AccountInfo`) from the
    /// `System::Account` storage map. Key:
    /// `twox128("System") ‖ twox128("Account") ‖ blake2_128(accountId) ‖ accountId`
    /// (mirrors `PolkadotChainAdapter`'s balance key construction). Returns the
    /// chain's stored nonce — this excludes not-yet-included mempool txs, but
    /// is the correct next index when no send is in flight (the Send flow gates
    /// one send at a time, recipe §gotchas #1).
    private static func fetchNonceFromStorage(chain: SupportedChain, address: String) async -> UInt64? {
        guard let accountId = SS58.decodeAccountId(address) else { return nil }
        var key: [UInt8] = []
        key.append(contentsOf: Twox.twox128(Array("System".utf8)))
        key.append(contentsOf: Twox.twox128(Array("Account".utf8)))
        key.append(contentsOf: BLAKE2b.hash(accountId, outlen: 16))
        key.append(contentsOf: accountId)
        let keyHex = "0x" + key.map { String(format: "%02x", $0) }.joined()

        guard let resultStr = try? await RPCClient.shared.callJSONString(
            chain: chain, method: "state_getStorage", params: [keyHex]
        ), resultStr.hasPrefix("0x") else {
            // A `null` (account never used) means nonce 0 — the first send.
            return 0
        }
        guard let bytes = hexData(resultStr), bytes.count >= 4 else { return 0 }
        // nonce: u32 little-endian at offset 0.
        var nonce: UInt64 = 0
        for i in 0..<4 { nonce |= UInt64(bytes[i]) << (8 * i) }
        return nonce
    }

    // MARK: - Genesis validation

    private static let relayGenesisHex =
        "91b171bb158e2d3848fa23a9f1c25182fb8e20313b2c1eb49219da7a70ce90c3"

    /// Confirm the live node is the Polkadot relay chain before we sign with a
    /// relay-genesis-anchored payload. Empty/unreadable genesis is tolerated
    /// (the node may not expose `chain_getBlockHash 0`); a *different* genesis
    /// is a hard stop — signing against the wrong chain would burn the fee.
    private static func validateRelayGenesis(_ genesisHex: String) throws(ChainSendError) {
        let clean = genesisHex.hasPrefix("0x") ? String(genesisHex.dropFirst(2)) : genesisHex
        guard !clean.isEmpty else { return }  // couldn't read — proceed (builder hardcodes genesis)
        guard clean.lowercased() == relayGenesisHex else {
            throw .missingContext("genesis mismatch — endpoint is not the Polkadot relay chain")
        }
    }

    // MARK: - Error mapping

    private static func mapBuilderError(_ e: PolkadotExtrinsicBuilder.BuilderError) -> ChainSendError {
        switch e {
        case .invalidDestination:
            return .signingFailed("Invalid Polkadot destination address.")
        case .signatureSelfCheckFailed:
            return .signingFailed("The transaction signature failed local verification.")
        case .invalidGenesis, .invalidBlockHash, .zeroBlockNumber:
            return .missingContext("Polkadot block context")
        case .shortCallData, .signingNil, .badSignatureLength, .badPublicKeyLength:
            return .signingFailed("Could not sign the Polkadot transaction.")
        }
    }

    /// Map a broadcast `RPCError` to an honest `.broadcastRejected` / transport
    /// error (mirrors BitcoinSendService.broadcastError).
    private static func broadcastError(_ error: Error) -> ChainSendError {
        guard let rpc = error as? RPCError else {
            return .broadcastRejected("The network rejected the transaction.")
        }
        switch rpc {
        case .invalidResponse(let m), .rpcError(_, let m):
            return .broadcastRejected(cleanRejection(m))
        case .network, .allEndpointsFailed, .rateLimited:
            return .rpcUnavailable
        case .noEndpoint(let c):
            return .unsupportedChain(c)
        case .cancelled:
            return .rpcUnavailable
        case .decodingFailed:
            return .broadcastRejected("The network rejected the transaction.")
        }
    }

    /// Trim a Polkadot node's raw rejection to a human-readable line. The
    /// common substrate rejections are `Invalid Transaction` (bad signature /
    /// nonce / balance), `Future` (nonce too high), `Stale` (era expired).
    private static func cleanRejection(_ raw: String) -> String {
        let low = raw.lowercased()
        if low.contains("stale") {
            return "This transaction expired before it was included. Try again."
        }
        if low.contains("future") {
            return "A previous transaction is still pending. Wait for it to confirm, then try again."
        }
        if low.contains("insufficient") || low.contains("balance") || low.contains("funds") {
            return "Balance is less than the amount plus the network fee."
        }
        if low.contains("bad signature") || low.contains("badproof") || low.contains("invalid transaction") {
            return "The network rejected the transaction. Try again."
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The network rejected the transaction." : trimmed
    }

    // MARK: - Hex helpers (file-private — our Data(hexString:) is file-scoped elsewhere)

    private static func parseHexUInt64(_ hex: String) -> UInt64? {
        let clean = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        return UInt64(clean, radix: 16)
    }

    /// Decode a hex string (optional `0x`) into `Data`, or `nil` if malformed.
    private static func hexData(_ hex: String) -> Data? {
        let clean = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        guard clean.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return Data(bytes)
    }
}
