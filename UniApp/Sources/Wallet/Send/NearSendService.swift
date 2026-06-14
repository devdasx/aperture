import Foundation
import SwiftData
import WalletCore

/// Real NEAR send (native NEAR + NEP-141 fungible token). One
/// implementation; the `isNative` flag selects the action set.
///
/// Pipeline (per `/tmp/recipe-near.md`): derive the signer's ed25519
/// public key → `query` `view_access_key` for the current nonce + a fresh
/// recent `block_hash` (NEAR rejects txs whose block hash is older than
/// ~12h — gotcha #2) → build `NEARSigningInput` with `nonce + 1` and the
/// base58-decoded block hash → sign with wallet-core `AnySigner`
/// (`NEARSigningInput`) → `broadcast_tx_commit` (base64). NEAR's
/// `broadcast_tx_commit` is synchronous-final: a returned hash means the
/// transaction is committed (recipe `broadcast` / `statusCheck`). All off
/// the main actor (Rule #28); the fee always shows even if `gas_price`
/// fails (Rule #16 — honest, never blank), and a node rejection surfaces
/// its real reason (Rule #16 / Rule #26).
///
/// Mirrors Stabro's proven `TransactionSigner.signNearTransaction`
/// (lines 589–661) field-for-field for the wallet-core input — including
/// the `storage_deposit` + `ft_transfer` two-action NEP-141 shape and the
/// little-endian u128 deposit encoding (`nearU128LE`, ported below from
/// Stabro lines 1340–1367) — and Stabro's `NEARService` for the RPC
/// method/param shapes, but every RPC call routes through OUR
/// `RPCClient.shared`.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet test send on-device.
/// The crypto is wallet-core's; the wiring is exercised by that first
/// real send.
enum NearSendService {

    // MARK: - Constants

    /// yoctoNEAR per NEAR (1 NEAR = 10^24 yocto).
    private static let yoctoDecimals = 24

    /// Protocol gas limits (TGas → base gas units, ×10^12). NEAR gas is
    /// protocol-fixed; the user cannot customize it (recipe gotcha #5).
    private static let nativeTransferGas: UInt64 = 25_000_000_000_000      // 25 TGas
    private static let storageDepositGas: UInt64 = 10_000_000_000_000      // 10 TGas
    private static let ftTransferGas: UInt64 = 30_000_000_000_000          // 30 TGas

    /// Total gas budget per transaction (for the fee estimate display).
    private static let nativeTransferTotalGas: Decimal = 25_000_000_000_000
    private static let nep141TransferTotalGas: Decimal = 40_000_000_000_000 // storage_deposit + ft_transfer

    /// Storage deposit attached to `storage_deposit` so the recipient is
    /// registered if it isn't already (NEP-141 requirement). 0.00125 NEAR
    /// in yoctoNEAR — mirrors Stabro.
    private static let storageDepositYocto = "1250000000000000000000"

    /// The 1 yoctoNEAR `ft_transfer` mandates as an attached deposit
    /// (gotcha #3 — never skip it).
    private static let oneYoctoNEAR = "1"

    /// Fallback gas price (yoctoNEAR) when the live `gas_price` fetch
    /// fails. Typical mainnet value (recipe preSign #3).
    private static let fallbackGasPriceYocto: Decimal = 100_000_000

    // MARK: - Off-main orchestration (called from the @MainActor view-model)

    /// One `.normal` fee tier — NEAR has no slow/normal/fast model; gas is
    /// protocol-fixed (recipe `feeEstimation`). The fee always shows even
    /// if the live `gas_price` RPC fails (Rule #16). Never throws.
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        let gasPriceYocto = await liveGasPriceYocto(chain: chain)
        let totalGas = isNative ? nativeTransferTotalGas : nep141TransferTotalGas
        let feeYocto = totalGas * gasPriceYocto
        let feeNative = feeYocto / pow(Decimal(10), yoctoDecimals)
        return [
            ChainFeeOption(
                speed: .normal,
                feeNative: feeNative,
                estimatedSeconds: 3,        // NEAR blocks ~1 s; commit ~2–3 s.
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            ),
        ]
    }

    /// Full send: derive the key + public key, fetch the access-key nonce
    /// and a fresh block hash, build the action set, sign, and broadcast.
    /// Returns the broadcast payload (base64) + the tx hash the node
    /// assigned.
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard chain == .near else { throw .unsupportedChain(chain) }

        // Custody-checked key + the sender (signer) account id.
        let (key, fromAddress) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // NEAR's `view_access_key` query keys on the account's full ed25519
        // public key in `ed25519:<base58-no-check>` form. Derive it from
        // the signing key (no-check base58 — NEAR keys never carry a
        // base58-check checksum).
        let ed25519PublicKey = key.getPublicKeyEd25519().data
        let publicKeyString = "ed25519:" + WalletCore.Base58.encodeNoCheck(data: ed25519PublicKey)

        // Access key → current nonce + a fresh recent block hash. The block
        // hash carried in the access-key result is recent enough for the
        // ~12h freshness window (gotcha #2); fetched immediately before
        // signing, never cached.
        let accessKey = try await fetchAccessKey(
            chain: chain, accountId: fromAddress, publicKey: publicKeyString
        )
        guard let blockHashData = WalletCore.Base58.decodeNoCheck(string: accessKey.blockHash),
              !blockHashData.isEmpty else {
            throw ChainSendError.missingContext("near_block_hash")
        }

        var input = NEARSigningInput()
        input.signerID = fromAddress
        input.nonce = accessKey.nonce + 1            // increment (gotcha #1)
        input.privateKey = key.data
        input.blockHash = blockHashData

        if isNative {
            // Native NEAR transfer — single `Transfer` action whose deposit
            // is the raw yoctoNEAR amount as little-endian u128.
            input.receiverID = toAddress
            var transfer = NEARTransfer()
            transfer.deposit = nearU128LE(rawAmount)
            var action = NEARAction()
            action.transfer = transfer
            input.actions = [action]
        } else {
            // NEP-141 fungible token transfer — two function-call actions
            // targeting the token contract: register the recipient
            // (`storage_deposit`) then move the tokens (`ft_transfer`).
            guard let tokenContract = contract, !tokenContract.isEmpty else {
                throw .signingFailed("Missing token contract for NEP-141 send.")
            }
            input.receiverID = tokenContract

            // Action 1 — storage_deposit({ account_id: <recipient> }),
            // attaching 0.00125 NEAR so an unregistered recipient is
            // registered (idempotent if already registered).
            let storageArgs: [String: Any] = ["account_id": toAddress]
            guard let storageArgsData = try? JSONSerialization.data(withJSONObject: storageArgs) else {
                throw .signingFailed("Could not encode storage_deposit args.")
            }
            var storageCall = NEARFunctionCall()
            storageCall.methodName = "storage_deposit"
            storageCall.args = storageArgsData
            storageCall.gas = storageDepositGas
            storageCall.deposit = nearU128LE(storageDepositYocto)
            var storageAction = NEARAction()
            storageAction.functionCall = storageCall

            // Action 2 — ft_transfer({ receiver_id, amount }). `amount` is a
            // JSON STRING for arbitrary precision (gotcha #7); the 1
            // yoctoNEAR deposit is mandatory (gotcha #3).
            let transferArgs: [String: String] = ["receiver_id": toAddress, "amount": rawAmount]
            guard let transferArgsData = try? JSONSerialization.data(withJSONObject: transferArgs) else {
                throw .signingFailed("Could not encode ft_transfer args.")
            }
            var transferCall = NEARFunctionCall()
            transferCall.methodName = "ft_transfer"
            transferCall.args = transferArgsData
            transferCall.gas = ftTransferGas
            transferCall.deposit = nearU128LE(oneYoctoNEAR)
            var transferAction = NEARAction()
            transferAction.functionCall = transferCall

            input.actions = [storageAction, transferAction]
        }

        let output: NEARSigningOutput = AnySigner.sign(input: input, coin: .near)
        guard !output.signedTransaction.isEmpty else {
            throw .signingFailed("Signer returned an empty transaction.")
        }
        let signedTransaction = output.signedTransaction   // raw Borsh bytes
        let base64Tx = signedTransaction.base64EncodedString()
        let localHash = output.hash.hexString

        // Broadcast — `broadcast_tx_commit` waits for block inclusion and
        // returns the committed tx hash (recipe `broadcast`).
        do {
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain, method: "broadcast_tx_commit", params: [base64Tx]
            )
            let returnedHash = parseBroadcastHash(from: data)
            let txHash = (returnedHash?.isEmpty == false) ? returnedHash! : localHash
            return ChainSignedTransaction(broadcastPayload: base64Tx, txHash: txHash)
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw .broadcastRejected(broadcastMessage(for: error))
        }
    }

    // MARK: - Status

    /// NEAR's `broadcast_tx_commit` already waits for block inclusion and
    /// is final on success — if `performSend` returned a hash, the
    /// transaction is committed (recipe `statusCheck`: "No polling
    /// required"). The status signature carries no sender account id, and
    /// NEAR's `tx` method requires one, so the honest answer here is the
    /// settlement that broadcast already proved.
    static func status(chain: SupportedChain, txHash: String) async throws(ChainSendError) -> ChainSendStatus {
        guard chain == .near else { throw .unsupportedChain(chain) }
        return .confirmed(blockNumber: nil)
    }

    // MARK: - Pre-sign fetches

    private struct NearAccessKey: Sendable {
        let nonce: UInt64
        let blockHash: String
    }

    /// `query` `view_access_key` → `{ nonce, block_hash }`. NEAR's `query`
    /// method requires the JSON-RPC `params` as a named OBJECT, not an
    /// array (gotcha #4) — routed through `callJSONResultData(paramsObject:)`.
    private static func fetchAccessKey(
        chain: SupportedChain, accountId: String, publicKey: String
    ) async throws(ChainSendError) -> NearAccessKey {
        do {
            let params: [String: Sendable] = [
                "request_type": "view_access_key",
                "finality": "final",
                "account_id": accountId,
                "public_key": publicKey,
            ]
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain, method: "query", paramsObject: params
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ChainSendError.missingContext("view_access_key")
            }
            // `nonce` is a JSON number; `block_hash` is base58.
            guard let nonce = (obj["nonce"] as? NSNumber)?.uint64Value,
                  let blockHash = obj["block_hash"] as? String, !blockHash.isEmpty else {
                throw ChainSendError.missingContext("view_access_key")
            }
            return NearAccessKey(nonce: nonce, blockHash: blockHash)
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw ChainSendError.missingContext("view_access_key")
        }
    }

    /// Live `gas_price` (yoctoNEAR) for the latest block. `gas_price`
    /// takes a single positional `null` param. Returns the fallback on any
    /// failure — the fee always shows (Rule #16).
    private static func liveGasPriceYocto(chain: SupportedChain) async -> Decimal {
        guard let data = try? await RPCClient.shared.callJSONResultData(
            chain: chain, method: "gas_price", params: [NSNull()]
        ) else {
            return fallbackGasPriceYocto
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallbackGasPriceYocto
        }
        // `gas_price` is returned as a STRING (yoctoNEAR can exceed UInt64
        // headroom; parse with Decimal — recipe preSign #3).
        if let str = obj["gas_price"] as? String, let value = Decimal(string: str), value > 0 {
            return value
        }
        if let num = obj["gas_price"] as? NSNumber {
            let value = num.decimalValue
            if value > 0 { return value }
        }
        return fallbackGasPriceYocto
    }

    /// Extract the committed tx hash from a `broadcast_tx_commit` result:
    /// `result.transaction.hash` (recipe `broadcast`), falling back to
    /// `result.transaction_outcome.id`.
    private static func parseBroadcastHash(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let transaction = obj["transaction"] as? [String: Any],
           let hash = transaction["hash"] as? String, !hash.isEmpty {
            return hash
        }
        if let outcome = obj["transaction_outcome"] as? [String: Any],
           let id = outcome["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    // MARK: - NEAR u128 encoding (ported from Stabro lines 1340–1367)

    /// Encodes a decimal string as a 16-byte little-endian u128 — the form
    /// wallet-core's NEAR `deposit` field expects. Base-256 long division
    /// of the decimal string into LSB-first bytes; no Double, no overflow.
    private static func nearU128LE(_ decimalString: String) -> Data {
        var result = [UInt8](repeating: 0, count: 16)
        var remaining = decimalString

        var byteIndex = 0
        while remaining != "0" && !remaining.isEmpty && byteIndex < 16 {
            var carry: UInt32 = 0
            var next = ""
            for char in remaining {
                guard let ascii = char.asciiValue, ascii >= 48, ascii <= 57 else { continue }
                let digit = UInt32(ascii - 48) + carry * 10
                carry = digit % 256
                let quotient = digit / 256
                if !next.isEmpty || quotient > 0 {
                    next.append(Character(UnicodeScalar(quotient + 48)!))
                }
            }
            if next.isEmpty { next = "0" }
            result[byteIndex] = UInt8(carry)
            byteIndex += 1
            remaining = next
        }

        return Data(result)
    }

    // MARK: - Error mapping

    private static func broadcastMessage(for error: RPCError) -> String {
        let raw = "\(error)".lowercased()
        if raw.contains("nonce") { return "A transaction with this nonce was already sent. Try again." }
        if raw.contains("notenoughbalance") || raw.contains("insufficient") || raw.contains("not enough") {
            return "Balance is less than the amount plus the network fee."
        }
        if raw.contains("expired") || raw.contains("block") && raw.contains("hash") {
            return "The transaction expired before it landed. Try again."
        }
        if raw.contains("signature") { return "The transaction signature was rejected." }
        if raw.contains("does not exist") || raw.contains("unknownaccount") {
            return "The recipient account doesn't exist on NEAR."
        }
        return "The network rejected the transaction. Try again."
    }
}
