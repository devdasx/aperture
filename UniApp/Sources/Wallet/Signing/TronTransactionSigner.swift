import Foundation
import WalletCore

/// Builds + signs TRON transactions (native TRX `TransferContract` +
/// TRC-20 `TransferTRC20Contract`, optional memo, fee_limit) from
/// `SendDraft` + just-in-time data, adapted from Stabro's proven
/// `signTronTransaction` onto Aperture's contracts.
///
/// **wallet-core SigningInput (Tron.proto, WalletCore 4.6.13 — field
/// names verified against the pinned `arm64.swiftinterface` + the
/// upstream `TronTests.swift` fixture):**
/// `transaction = TronTransaction{contractOneof, timestamp, expiration,
/// blockHeader, feeLimit, memo}`, `privateKey`. The contract oneof:
/// - `.transfer(TronTransferContract{ownerAddress, toAddress, amount Int64 SUN})`
///   for native TRX.
/// - `.transferTrc20Contract(TronTransferTRC20Contract{contractAddress,
///   ownerAddress, toAddress, amount Data (uint256 big-endian)})` for TRC-20.
///
/// `blockHeader` (`TronBlockHeader{timestamp, number, version, txTrieRoot,
/// parentHash, witnessAddress}`) is the latest block ref — wallet-core
/// derives `ref_block_bytes`/`ref_block_hash` from it. The JIT layer
/// fetches `/wallet/getnowblock` and encodes the header as JSON which the
/// signer parses (matches the reference's `blockReference` channel).
///
/// **Fee model (matrix §G9, doc-grounded — resource-model):** TRON burns
/// bandwidth (bytes) + energy (contract calls); `fee_limit` (SUN) caps
/// the energy burn for a TRC-20 call. `FeeChoice.tronFeeLimitSun` resolves
/// it; a native TRX transfer needs no fee_limit (bandwidth only). A
/// non-empty memo costs +1 TRX (getMemoFee) — surfaced by compose.
///
/// Output: `output.json` is the signed-tx JSON the broadcaster posts to
/// `/wallet/broadcasttransaction`; `output.id` is the txID (computed
/// locally as sha256(raw_data)).
enum TronTransactionSigner {

    /// Default native-transfer fee-limit cap (SUN) when none resolved —
    /// bandwidth-only sends don't strictly need it, but a small cap is
    /// harmless. Token sends MUST carry a real energy-derived fee_limit.
    private static let defaultNativeFeeLimit: Int64 = 1_000_000        // 1 TRX
    private static let defaultTokenFeeLimit: Int64 = 100_000_000       // 100 TRX (USDT-safe ceiling)
    private static let maxFeeLimit: Int64 = 15_000_000_000             // 15,000 TRX (getMaxFeeLimit)

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .tron else {
            throw SigningError.malformedDraft("TRON signer used for \(draft.chain.rawValue)")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let blockJSON = jit.tronBlockHeaderJSON, !blockJSON.isEmpty else {
            throw SigningError.justInTimeRefreshFailed("TRON block reference not refreshed")
        }

        var transaction = TronTransaction()

        if draft.isTokenSend {
            guard let contract = draft.tokenContract, !contract.isEmpty else {
                throw SigningError.malformedDraft("TRC-20 send missing contract")
            }
            guard let amountData = SigningAmount.bigEndianMinimal(display: recipient.amount, decimals: draft.effectiveDecimals) else {
                throw SigningError.malformedDraft("invalid TRC-20 amount")
            }
            let trc20 = TronTransferTRC20Contract.with {
                $0.contractAddress = contract
                $0.ownerAddress = draft.fromAddress
                $0.toAddress = recipient.address
                $0.amount = amountData
            }
            transaction.contractOneof = .transferTrc20Contract(trc20)
            transaction.feeLimit = resolveFeeLimit(draft: draft, isToken: true)
        } else {
            guard let sun = SigningAmount.int64(display: recipient.amount, decimals: draft.chain.nativeDecimals) else {
                throw SigningError.malformedDraft("invalid TRX amount")
            }
            let transfer = TronTransferContract.with {
                $0.ownerAddress = draft.fromAddress
                $0.toAddress = recipient.address
                $0.amount = sun
            }
            transaction.contractOneof = .transfer(transfer)
            transaction.feeLimit = resolveFeeLimit(draft: draft, isToken: false)
        }

        // Memo (matrix §G9: +1 TRX network burn when present; compose warns).
        if let memo = tronMemo(from: draft.memo), !memo.isEmpty {
            transaction.memo = memo
        }

        // Timestamps + a short expiration window (now+60s) so a stuck tx
        // expires deterministically rather than lingering (matrix §G9).
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        transaction.timestamp = nowMillis
        transaction.expiration = nowMillis + 60_000

        guard let header = parseBlockHeader(blockJSON) else {
            throw SigningError.justInTimeRefreshFailed("TRON block header could not be parsed")
        }
        transaction.blockHeader = header

        var input = TronSigningInput()
        input.transaction = transaction
        input.privateKey = privateKey.data

        let output: TronSigningOutput = AnySigner.sign(input: input, coin: .tron)
        guard output.error == .ok, !output.json.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "TRON: empty AnySigner output" : output.errorMessage)
        }

        return SignedTransaction(
            rawData: Data(output.json.utf8),
            rawHex: output.json,           // signed-tx JSON for /wallet/broadcasttransaction
            txHash: output.id.hexString    // local sha256(raw_data) txID
        )
    }

    // MARK: - Helpers

    private static func resolveFeeLimit(draft: SendDraft, isToken: Bool) -> Int64 {
        let fallback = isToken ? defaultTokenFeeLimit : defaultNativeFeeLimit
        let raw = draft.fee.tronFeeLimitSun.flatMap { SigningAmount.int64($0) } ?? fallback
        return min(max(raw, 0), maxFeeLimit)
    }

    private static func tronMemo(from memo: SendMemoValue) -> String? {
        switch memo {
        case .text(let s): return s
        default:           return nil
        }
    }

    /// Parse the JIT block-header JSON (the channel the executor encodes
    /// `/wallet/getnowblock`'s `block_header.raw_data` into) into a
    /// `TronBlockHeader`. Hex fields decode to `Data`; numeric fields to
    /// `Int64`/`Int32`. Mirrors the reference's `blockReference` decode.
    private static func parseBlockHeader(_ json: String) -> TronBlockHeader? {
        guard let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var header = TronBlockHeader()
        header.timestamp = int64(dict["timestamp"]) ?? 0
        header.number = int64(dict["number"]) ?? 0
        header.version = Int32(truncatingIfNeeded: int64(dict["version"]) ?? 0)
        if let trie = dict["txTrieRoot"] as? String, let d = hex(trie) { header.txTrieRoot = d }
        if let parent = dict["parentHash"] as? String, let d = hex(parent) { header.parentHash = d }
        if let witness = dict["witnessAddress"] as? String, let d = hex(witness) { header.witnessAddress = d }
        // A header with no block number is unusable.
        guard header.number > 0 else { return nil }
        return header
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }

    private static func hex(_ s: String) -> Data? {
        SigningNumeric.hexToData(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s)
    }
}
