import Foundation
import SwiftData
import WalletCore

/// Real Aptos send (native APT + legacy coin-type tokens + pure Fungible
/// Assets). One implementation; the contract shape (`::` coin type vs. a
/// bare `0x…` FA metadata address) differentiates the payload.
///
/// Pipeline: fetch the account `sequence_number` + live `gas_estimate`
/// (Aptos REST) → build the fee tier(s) → sign with wallet-core
/// `AnySigner` (Aptos coin) → POST the BCS-encoded signed transaction to
/// `/transactions` → poll `/transactions/by_hash/{hash}`. All off the main
/// actor (Rule #28). Every sequence/gas value is fetched live (no
/// guesses); a node rejection surfaces its real reason (Rule #16 / #26).
///
/// **Mirrors Stabro faithfully.** The wallet-core usage is a 1:1 port of
/// `TransactionSigner.signAptosTransaction` (lines 663–733): the
/// `AptosSigningInput` field set, the `tokenTransferCoins` /
/// `fungibleAssetTransfer` branch on whether the contract contains `"::"`,
/// the `0x1::aptos_coin::AptosCoin` struct tag for native APT, and the use
/// of `output.encoded` (BCS) for broadcast + `output.json` as the JSON
/// fallback payload. The submit path mirrors `AptosService
/// .broadcastTransaction`: BCS first (`Content-Type`
/// `application/x.aptos.signed_transaction+bcs`, raw `output.encoded` as
/// the body), JSON fallback (`output.json`), response `{"hash": …}`.
///
/// **Aptos is single-gas-price.** The network has no miner-priority
/// auction (it's PoS), so the three tiers are presentational: the live
/// `gas_estimate` scaled by 0.85× / 1.0× / 1.3× so the UI can offer a
/// range. The signer always uses the chosen tier's value; `.normal` is the
/// live estimate, matching Stabro's flat-rate approach.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet test send on-device —
/// the crypto is wallet-core's (the exact bytes match the wallet-core
/// AptosTests vectors); the RPC wiring is exercised by that first real
/// send.
enum AptosSendService {

    // MARK: - Constants (mirrors Stabro AptosTransactionBuilder + signer)

    /// Stabro's `signAptosTransaction` hard-codes `maxGasAmount = 10_000`
    /// (line 673) — generous headroom for a coin/FA transfer. The fee
    /// display uses the same value so the quoted fee is the worst case.
    private static let maxGasAmount: UInt64 = 10_000

    /// Protocol default when `estimate_gas_price` is unreachable
    /// (AptosService line 154; Stabro signer line 674 hard-codes 100).
    private static let defaultGasUnitPrice: UInt64 = 100

    /// Mainnet chain id (Stabro signer line 676).
    private static let mainnetChainID: UInt32 = 1

    /// 10-minute expiry window (Stabro signer line 675).
    private static let expirySeconds: TimeInterval = 600

    // MARK: - Off-main orchestration (called from the @MainActor view-model)

    /// Build the fee tier(s) from the live gas estimate. Never throws on
    /// the network — falls back to the protocol-default gas unit price
    /// when the REST call is unreachable (the recipe's "use defaults"
    /// contract). Only an unsupported chain is a hard error.
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        guard chain == .aptos else { throw .unsupportedChain(chain) }

        let gasUnitPrice = await fetchGasUnitPrice()

        // Aptos has a single network gas price (PoS — no priority
        // auction). Present a range via local multipliers; the signer
        // uses the chosen tier's value (`.normal` == live estimate).
        let tiers: [(ChainFeeOption.Speed, UInt64, Int)] = [
            (.slow, 85, 30), (.normal, 100, 8), (.fast, 130, 4),
        ]
        return tiers.map { (speed, mul, secs) in
            let pricedUnit = max(gasUnitPrice * mul / 100, 1)
            // feeOctas = maxGasAmount × gasUnitPrice; APT/octas → /10^8.
            let feeOctas = Decimal(maxGasAmount) * Decimal(pricedUnit)
            return ChainFeeOption(
                speed: speed,
                feeNative: feeOctas / pow(Decimal(10), 8),
                estimatedSeconds: secs,
                gasLimit: maxGasAmount,        // gas units (reused field)
                maxFeePerGas: nil,             // EVM-only — N/A on Aptos
                maxPriorityFeePerGas: nil,     // EVM-only — N/A on Aptos
                gasPrice: pricedUnit           // gas unit price (octas/unit)
            )
        }
    }

    /// Full send: fetch the sequence number + gas price live, derive the
    /// key off-main, sign, broadcast, and return the broadcast result.
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard chain == .aptos else { throw .unsupportedChain(chain) }

        // Amount must fit a UInt64 (Aptos `amount` field is uint64;
        // Stabro signer line 679 guards the same way).
        guard let transferAmount = UInt64(rawAmount) else {
            throw .signingFailed("Amount exceeds the maximum transferable value.")
        }

        // Sequence number — fetch fresh immediately before signing
        // (recipe gotcha #1: a stale nonce is dropped by the validator).
        let sender = try ChainKeyProvider.senderAddress(for: chain, container: container)
        let sequenceNumber = try await fetchSequenceNumber(address: sender)

        // Live gas unit price for the chosen tier; the signer uses the
        // tier's priced value so the broadcast fee matches the quote.
        let baseGasPrice = await fetchGasUnitPrice()
        let gasUnitPrice: UInt64 = {
            switch speed {
            case .slow:   return max(baseGasPrice * 85 / 100, 1)
            case .normal: return max(baseGasPrice, 1)
            case .fast:   return max(baseGasPrice * 130 / 100, 1)
            }
        }()

        let (key, _) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // --- Build AptosSigningInput (mirrors Stabro lines 670–717) ---
        var input = AptosSigningInput()
        input.sender = sender
        input.sequenceNumber = Int64(sequenceNumber)
        input.maxGasAmount = maxGasAmount
        input.gasUnitPrice = gasUnitPrice
        input.expirationTimestampSecs = UInt64(Date().timeIntervalSince1970 + expirySeconds)
        input.chainID = mainnetChainID
        input.privateKey = key.data

        if !isNative, let contractAddress = contract, !contractAddress.isEmpty {
            if contractAddress.contains("::") {
                // Legacy coin type (0xaddr::module::Name) → transfer_coins
                // with a StructTag (Stabro lines 687–697).
                var transferPayload = AptosTokenTransferCoinsMessage()
                transferPayload.to = toAddress
                transferPayload.amount = transferAmount
                var structTag = AptosStructTag()
                let parts = contractAddress.split(separator: "::", maxSplits: 2)
                guard parts.count == 3 else {
                    throw .signingFailed("Malformed Aptos coin type.")
                }
                structTag.accountAddress = String(parts[0])
                structTag.module = String(parts[1])
                structTag.name = String(parts[2])
                transferPayload.function = structTag
                input.tokenTransferCoins = transferPayload
            } else {
                // Pure Fungible Asset (0x… metadata address) → FA transfer
                // (Stabro lines 699–704).
                var faTransfer = AptosFungibleAssetTransferMessage()
                faTransfer.metadataAddress = contractAddress
                faTransfer.to = toAddress
                faTransfer.amount = transferAmount
                input.fungibleAssetTransfer = faTransfer
            }
        } else {
            // Native APT — 0x1::aptos_coin::AptosCoin via transfer_coins
            // (Stabro lines 707–716).
            var transferPayload = AptosTokenTransferCoinsMessage()
            transferPayload.to = toAddress
            transferPayload.amount = transferAmount
            var structTag = AptosStructTag()
            structTag.accountAddress = "0x1"
            structTag.module = "aptos_coin"
            structTag.name = "AptosCoin"
            transferPayload.function = structTag
            input.tokenTransferCoins = transferPayload
        }

        let output: AptosSigningOutput = AnySigner.sign(input: input, coin: .aptos)
        guard !output.rawTxn.isEmpty, !output.encoded.isEmpty else {
            throw .signingFailed("Signer returned an empty transaction.")
        }

        // --- Broadcast (mirrors AptosService.broadcastTransaction) ---
        // BCS first: raw `output.encoded` bytes with the Aptos BCS
        // content type; JSON fallback: `output.json`.
        let returnedHash = try await broadcast(encoded: output.encoded, json: output.json)

        // Prefer the node's returned hash; fall back to the locally
        // derivable rawTxn hex if the node omitted it (Stabro uses the
        // rawTxn hex as the identifier — line 730; `hexStringWith0x` is a
        // Stabro-only extension, so compose it here from WalletCore's
        // `Data.hexString`).
        let localHash = "0x" + output.rawTxn.hexString
        return ChainSignedTransaction(
            broadcastPayload: output.json,
            txHash: returnedHash.isEmpty ? localHash : returnedHash
        )
    }

    // MARK: - Status

    /// GET `/transactions/by_hash/{hash}` (AptosService.getTransactionStatus).
    /// `success == true` → confirmed (version as the block number);
    /// `success == false` → failed; missing/`pending_transaction`/404 →
    /// pending.
    static func status(chain: SupportedChain, txHash: String) async throws(ChainSendError) -> ChainSendStatus {
        guard chain == .aptos else { throw .unsupportedChain(chain) }
        do {
            let data = try await RPCClient.shared.callREST(
                chain: .aptos, path: "transactions/by_hash/\(txHash)"
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .pending
            }
            // A still-pending tx is returned with `type ==
            // "pending_transaction"` and NO `success` field.
            if let type = obj["type"] as? String, type == "pending_transaction" {
                return .pending
            }
            let version = (obj["version"] as? String).flatMap { UInt64($0) }
            if let success = obj["success"] as? Bool {
                return success
                    ? .confirmed(blockNumber: version)
                    : .failed(reason: vmStatusReason(obj["vm_status"]))
            }
            return .pending
        } catch let e as RPCError {
            // A 404 (not yet in a finalized block) surfaces as an
            // `invalidResponse` string containing "HTTP 404" — treat any
            // not-yet-available transaction as still pending.
            if isNotFound(e) { return .pending }
            throw .rpcUnavailable
        }
    }

    // MARK: - RPC (Aptos REST — routed through our RPCClient)

    /// GET `/accounts/{address}` → `sequence_number` (string → UInt64).
    /// The registered Aptos base URL already ends in `/v1`, so the path
    /// here is relative (no leading slash, no `/v1`).
    private nonisolated static func fetchSequenceNumber(address: String) async throws(ChainSendError) -> UInt64 {
        do {
            let data = try await RPCClient.shared.callREST(
                chain: .aptos, path: "accounts/\(address)"
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let seqString = obj["sequence_number"] as? String,
                  let seq = UInt64(seqString) else {
                throw ChainSendError.missingContext("accounts/sequence_number")
            }
            return seq
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw ChainSendError.missingContext("accounts/sequence_number")
        }
    }

    /// GET `/estimate_gas_price` → `gas_estimate` (octas/unit). Never
    /// throws — the recipe's "use defaults (gasUnitPrice 100)" contract
    /// (AptosService lines 154–164 do the same).
    private nonisolated static func fetchGasUnitPrice() async -> UInt64 {
        guard let data = try? await RPCClient.shared.callREST(
            chain: .aptos, path: "estimate_gas_price"
        ), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return defaultGasUnitPrice
        }
        // The node returns `gas_estimate` as a JSON number.
        if let estimate = obj["gas_estimate"] as? NSNumber, estimate.intValue > 0 {
            return estimate.uint64Value
        }
        return defaultGasUnitPrice
    }

    /// POST the signed transaction to `/transactions`. BCS first (the
    /// raw `output.encoded` bytes with the Aptos BCS content type), JSON
    /// fallback (`output.json`). Returns the response's `hash` field.
    /// Mirrors `AptosService.broadcastTransaction` exactly.
    private nonisolated static func broadcast(encoded: Data, json: String) async throws(ChainSendError) -> String {
        // 1) BCS submission — preferred.
        do {
            let data = try await RPCClient.shared.callRESTPostRaw(
                chain: .aptos,
                path: "transactions",
                body: encoded,
                contentType: "application/x.aptos.signed_transaction+bcs"
            )
            if let hash = hashFromSubmitResponse(data) { return hash }
            // 2xx but no `hash` field — fall through to the JSON path.
        } catch let e as RPCError {
            // A 4xx is a deterministic rejection (bad signature, nonce
            // collision, malformed tx) — surface its real reason rather
            // than retrying the JSON path with the same bad tx. Only fall
            // through to JSON when the endpoint refused the BCS content
            // type / transport failed (the recipe's older-endpoint case).
            if isClientRejection(e) {
                throw .broadcastRejected(broadcastMessage(for: e))
            }
            // else: fall through to JSON fallback below.
        }

        // 2) JSON fallback — `output.json` as the raw UTF-8 body.
        guard let jsonBody = json.data(using: .utf8) else {
            throw .broadcastRejected("The network rejected the transaction. Try again.")
        }
        do {
            let data = try await RPCClient.shared.callRESTPostRaw(
                chain: .aptos,
                path: "transactions",
                body: jsonBody,
                contentType: "application/json"
            )
            guard let hash = hashFromSubmitResponse(data) else {
                throw ChainSendError.broadcastRejected("The network accepted the transaction but returned no hash.")
            }
            return hash
        } catch let e as ChainSendError {
            throw e
        } catch let e as RPCError {
            throw .broadcastRejected(broadcastMessage(for: e))
        } catch {
            throw .broadcastRejected("The network rejected the transaction. Try again.")
        }
    }

    // MARK: - Helpers

    /// Decode `{ "hash": "0x…" }` from a submit response body.
    private static func hashFromSubmitResponse(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = obj["hash"] as? String, !hash.isEmpty else {
            return nil
        }
        return hash
    }

    private static func vmStatusReason(_ raw: Any?) -> String {
        if let status = raw as? String, !status.isEmpty {
            return "The transaction failed on-chain: \(status)"
        }
        return "The transaction failed on-chain."
    }

    /// `true` when the REST error carries an HTTP 404 (transaction not
    /// yet finalized) — surfaced by RPCClient as an `invalidResponse`
    /// string containing "HTTP 404".
    private static func isNotFound(_ error: RPCError) -> Bool {
        "\(error)".contains("404")
    }

    /// `true` when the REST error carries a 4xx the validator returned —
    /// a deterministic rejection (bad signature, nonce collision,
    /// malformed tx). RPCClient folds the server body + status into the
    /// `invalidResponse` message (callRESTPostRaw → dispatchRESTPostRaw).
    private static func isClientRejection(_ error: RPCError) -> Bool {
        let raw = "\(error)"
        return raw.contains("HTTP 400") || raw.contains("HTTP 401")
            || raw.contains("HTTP 403") || raw.contains("HTTP 404")
            || raw.contains("HTTP 411") || raw.contains("HTTP 413")
    }

    /// Map a node rejection to an honest, user-facing reason (Rule #16).
    private static func broadcastMessage(for error: RPCError) -> String {
        let raw = "\(error)".lowercased()
        if raw.contains("sequence_number") || raw.contains("sequence number") {
            return "A transaction with this sequence number was already sent."
        }
        if raw.contains("insufficient") {
            return "Balance is less than the amount plus the network fee."
        }
        if raw.contains("gas") && (raw.contains("price") || raw.contains("low")) {
            return "The fee is too low — pick a faster speed."
        }
        if raw.contains("expired") || raw.contains("expiration") {
            return "The transaction expired before it was processed. Try again."
        }
        if raw.contains("invalid") && raw.contains("signature") {
            return "The transaction signature was rejected."
        }
        return "The network rejected the transaction. Try again."
    }
}
