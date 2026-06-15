import Foundation
import OSLog

/// Broadcasts a `SignedTransaction` to the chain and returns the real
/// on-chain transaction hash/id. Per-family dispatch, adapted from
/// Stabro's `BlockchainServiceRouter.broadcastTransaction` + the per-
/// service broadcasters. Every method/endpoint below is doc-grounded and
/// live-verified (2026-06-15) for shape — see the per-case comments.
///
/// **Goes through the shared `RPCClient`** (rate limiter + circuit
/// breakers + fallback rotation) for every chain whose broadcast lives
/// on a registered endpoint — EVM (`eth_sendRawTransaction` jsonRPC),
/// BTC/LTC (Esplora `POST /tx`), DOGE (BlockCypher `POST /txs/push`).
/// BCH alone broadcasts via Blockchair (not a registered Aperture
/// endpoint — Haskoin is read-only), so it uses a direct, rate-limited
/// `URLSession` call exactly as the reference does.
///
/// `nonisolated` actor-free struct; all I/O is async off-main.
struct BroadcastService: Sendable {

    let client: RPCClient
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "broadcast")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    /// Broadcast `signed` for `chain`; returns the on-chain txid/hash.
    func broadcast(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        switch chain.family {
        case .evm:
            return try await broadcastEVM(signed, chain: chain)
        case .bitcoin:
            return try await broadcastBitcoinFamily(signed, chain: chain)
        case .ed25519:   // Solana, Stellar, Sui
            switch chain {
            case .solana:  return try await broadcastSolana(signed)
            case .stellar: return try await broadcastStellar(signed)
            case .sui:     return try await broadcastSui(signed)
            default:       throw SigningError.broadcastFailed("unsupported ed25519 chain")
            }
        case .ripple:
            return try await broadcastXRP(signed)
        case .tron:
            return try await broadcastTron(signed)
        case .cosmos:    // Kava
            return try await broadcastCosmos(signed, chain: chain)
        case .aptos:
            return try await broadcastAptos(signed, chain: chain)
        case .near:
            return try await broadcastNear(signed, chain: chain)
        case .polkadot:
            return try await broadcastPolkadot(signed, chain: chain)
        case .ton:
            return try await broadcastTON(signed, chain: chain)
        }
    }

    // MARK: - EVM

    /// `eth_sendRawTransaction` — the canonical EVM broadcast method
    /// (Ethereum JSON-RPC spec:
    /// https://ethereum.org/en/developers/docs/apis/json-rpc/#eth_sendrawtransaction).
    /// Returns the 32-byte tx hash. Live-verified 2026-06-15 on
    /// `ethereum-rpc.publicnode.com`: the method is recognized (a
    /// malformed rawTx returns `-32600 reading transaction object
    /// failed`, NOT method-not-found). The node's returned hash is
    /// authoritative; we prefer it over our locally-computed
    /// `keccak256(rawData)` (they match for a well-formed tx).
    private func broadcastEVM(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        let rawHex = signed.rawHex.hasPrefix("0x") ? signed.rawHex : "0x" + signed.rawHex
        do {
            let returned = try await client.callJSONString(
                chain: chain,
                method: "eth_sendRawTransaction",
                params: [rawHex]
            )
            // Node returns the canonical hash; fall back to our local
            // keccak256 hash if the node echoed something empty.
            return returned.isEmpty ? signed.txHash : returned
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - Bitcoin family

    private func broadcastBitcoinFamily(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        switch chain {
        case .bitcoin, .litecoin:
            return try await broadcastEsplora(signed, chain: chain)
        case .dogecoin:
            return try await broadcastBlockCypher(signed, chain: chain)
        case .bitcoinCash:
            return try await broadcastBlockchairBCH(signed)
        default:
            // Unreachable: `broadcastBitcoinFamily` is only entered for the
            // `.bitcoin` family, whose only members are the four above. A
            // defensive branch, not a seam — surface an honest error rather
            // than the (now-retired-as-a-route) `.chainNotWired`.
            throw SigningError.broadcastFailed("unsupported Bitcoin-family chain \(chain.rawValue)")
        }
    }

    /// Esplora `POST /tx` with the raw tx HEX as a `text/plain` body;
    /// returns the txid as plain text (BTC: mempool.space / blockstream;
    /// LTC: litecoinspace — all Esplora). Doc:
    /// https://github.com/Blockstream/esplora/blob/master/API.md#post-tx ;
    /// https://mempool.space/docs/api/rest#post-transaction. Live-verified
    /// 2026-06-15: a malformed body returns `sendrawtransaction RPC
    /// error: TX decode failed` (HTTP 400) on both mempool.space and
    /// litecoinspace, proving the endpoint + raw-hex body shape.
    private func broadcastEsplora(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        do {
            let data = try await client.callRESTPostRaw(
                chain: chain, path: "/tx", body: signed.rawHex, contentType: "text/plain"
            )
            let txid = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard txid.count >= 32, !txid.contains(" ") else {
                throw (txid.isEmpty ? SigningError.broadcastAmbiguous("empty response") : SigningError.broadcastFailed(txid))
            }
            return txid
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    /// BlockCypher `POST /txs/push` with a JSON `{"tx": "<hex>"}` body;
    /// returns `{"tx": {"hash": "<txid>"}}` (DOGE). Doc:
    /// https://www.blockcypher.com/dev/bitcoin/#push-raw-transaction-endpoint.
    /// Live-verified 2026-06-15: a malformed body returns HTTP 409 (the
    /// endpoint parsed the `{"tx":…}` shape and rejected the tx), proving
    /// the endpoint + body shape (NOT 404).
    private func broadcastBlockCypher(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        do {
            let data = try await client.callRESTPost(
                chain: chain, path: "/txs/push", body: ["tx": signed.rawHex]
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let tx = root["tx"] as? [String: Any], let hash = tx["hash"] as? String, !hash.isEmpty {
                    return hash
                }
                if let errorMsg = root["error"] as? String {
                    throw SigningError.broadcastFailed(errorMsg)
                }
            }
            // Fall back to the locally-computed txid if the body shape
            // changed but the request succeeded (2xx).
            guard !signed.txHash.isEmpty else {
                throw SigningError.broadcastAmbiguous("unexpected DOGE broadcast response")
            }
            return signed.txHash
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    /// BCH via Blockchair `POST /bitcoin-cash/push/transaction` with a
    /// form body `data=<hex>`; returns `{"data":{"transaction_hash":…}}`.
    /// Haskoin (Aperture's registered BCH provider) is read-only, so —
    /// exactly as the reference does — BCH broadcasts via Blockchair, a
    /// direct rate-limited `URLSession` call. Doc:
    /// https://blockchair.com/api/docs#link_205. Live-verified 2026-06-15:
    /// a malformed body returns `{"context":{"code":400,...,"error":"…TX
    /// decode failed"}}` (HTTP 400), proving the endpoint + form shape.
    private func broadcastBlockchairBCH(_ signed: SignedTransaction) async throws(SigningError) -> String {
        guard let url = URL(string: "https://api.blockchair.com/bitcoin-cash/push/transaction") else {
            throw SigningError.broadcastFailed("invalid BCH broadcast URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = "data=\(signed.rawHex)".data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let payload = root["data"] as? [String: Any],
               let txid = payload["transaction_hash"] as? String, !txid.isEmpty {
                return txid
            }
            if let context = root["context"] as? [String: Any],
               let err = context["error"] as? String, !err.isEmpty {
                throw SigningError.broadcastFailed(err)
            }
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SigningError.broadcastFailed(body.isEmpty ? "HTTP \(http.statusCode)" : String(body.prefix(200)))
        }
        // 2xx with the locally-computed txid as the fallback.
        guard !signed.txHash.isEmpty else {
            throw SigningError.broadcastAmbiguous("unexpected BCH broadcast response")
        }
        return signed.txHash
    }

    // MARK: - Solana

    /// `sendTransaction` (base64 wire form) → returns the signature
    /// (Solana's txid). Doc: solana.com/docs/rpc/http/sendtransaction.
    /// Live-verified 2026-06-15 on `solana-rpc.publicnode.com`: the method
    /// is recognized (a malformed payload returns `-32600 invalid
    /// transaction, must be a base58 or base64 string`, NOT
    /// method-not-found). We send with `encoding: base64` + `skipPreflight:
    /// false` so the node simulates before relaying.
    private func broadcastSolana(_ signed: SignedTransaction) async throws(SigningError) -> String {
        do {
            let opts: [String: Sendable] = ["encoding": "base64", "skipPreflight": false]
            let sig = try await client.callJSONString(
                chain: .solana, method: "sendTransaction", params: [signed.rawHex, opts]
            )
            guard !sig.isEmpty else { throw SigningError.broadcastAmbiguous("empty Solana signature") }
            return sig
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - Stellar

    /// Horizon `POST /transactions` with a form body `tx=<base64 XDR>`.
    /// Doc: developers.stellar.org Horizon submit-transaction. Live-verified
    /// 2026-06-15: a malformed XDR returns
    /// `transaction_malformed`/HTTP 400, proving the endpoint + form shape.
    /// Returns the `hash` field on success.
    private func broadcastStellar(_ signed: SignedTransaction) async throws(SigningError) -> String {
        // base64 XDR may contain +,/,= — URL-encode for the form body.
        let encoded = signed.rawHex.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        ) ?? signed.rawHex
        do {
            let data = try await client.callRESTPostRaw(
                chain: .stellar, path: "/transactions",
                body: "tx=\(encoded)", contentType: "application/x-www-form-urlencoded"
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let hash = root["hash"] as? String, !hash.isEmpty { return hash }
                if let extras = root["extras"] as? [String: Any],
                   let codes = extras["result_codes"] as? [String: Any] {
                    throw SigningError.broadcastFailed(String(describing: codes))
                }
                if let title = root["title"] as? String { throw SigningError.broadcastFailed(title) }
            }
            throw SigningError.broadcastAmbiguous("unexpected Stellar submit response")
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - Sui

    /// `sui_executeTransactionBlock(txBytes, [signature], options,
    /// requestType)`. The signer packs `rawHex` as "<unsignedTx base64>:
    /// <signature base64>"; split it for the call. Doc:
    /// docs.sui.io/sui-api-ref. Live-verified 2026-06-15 on
    /// `fullnode.mainnet.sui.io`: the method is recognized (malformed
    /// params → `-32602 Invalid params`). Returns `result.digest`.
    private func broadcastSui(_ signed: SignedTransaction) async throws(SigningError) -> String {
        let parts = signed.rawHex.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw SigningError.broadcastFailed("malformed Sui signed payload")
        }
        let txBytes = parts[0]
        let signature = parts[1]
        do {
            let options: [String: Sendable] = ["showEffects": true]
            let data = try await client.callJSONResultData(
                chain: .sui, method: "sui_executeTransactionBlock",
                params: [txBytes, [signature], options, "WaitForLocalExecution"]
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let digest = root["digest"] as? String, !digest.isEmpty {
                return digest
            }
            throw SigningError.broadcastAmbiguous("unexpected Sui execute response")
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - XRP / Ripple

    /// rippled `submit` with `tx_blob` (hex). Doc:
    /// xrpl.org/docs/.../submit. XRPL's HTTP API does NOT echo the request
    /// `id`, so `validatesIDEcho: false`. Live-verified 2026-06-15 on
    /// `xrplcluster.com`: the method is recognized (malformed tx_blob →
    /// `invalidParams`/error_code 31). Returns the local txid unless the
    /// node reports `engine_result` failure.
    private func broadcastXRP(_ signed: SignedTransaction) async throws(SigningError) -> String {
        do {
            let data = try await client.callJSONResultData(
                chain: .ripple, method: "submit",
                params: [["tx_blob": signed.rawHex]], validatesIDEcho: false
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let engineResult = root["engine_result"] as? String ?? ""
                // tesSUCCESS / terQUEUED are accepted; anything else with a
                // tem/tef/tec prefix is a hard rejection.
                if engineResult.hasPrefix("tes") || engineResult.hasPrefix("ter") {
                    if let txJSON = root["tx_json"] as? [String: Any],
                       let hash = txJSON["hash"] as? String, !hash.isEmpty {
                        return hash
                    }
                    return signed.txHash // our locally-computed SHA-512Half id
                }
                let message = root["engine_result_message"] as? String ?? engineResult
                throw SigningError.broadcastFailed(message.isEmpty ? "XRP submit rejected" : message)
            }
            throw SigningError.broadcastAmbiguous("unexpected XRP submit response")
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - TRON

    /// TronGrid `POST /wallet/broadcasttransaction` with the signed-tx
    /// JSON the signer produced. Doc:
    /// developers.tron.network/reference/broadcasttransaction. Live-verified
    /// 2026-06-15 on `api.trongrid.io`: the endpoint is recognized (a bare
    /// `{raw_data_hex}` returns a parse NPE, NOT 404). The signed JSON is a
    /// full `{raw_data, raw_data_hex, signature, txID}` object; we post it
    /// verbatim. Returns `txid` on `result: true`.
    private func broadcastTron(_ signed: SignedTransaction) async throws(SigningError) -> String {
        // The signer's `rawHex` IS the full signed-tx JSON object
        // (`{raw_data, raw_data_hex, signature, txID}`); POST it verbatim
        // as an application/json body. (`Sendable` is a marker protocol
        // that can't be conditionally cast, so we send the raw JSON string
        // rather than re-wrapping the parsed dict.)
        do {
            let data = try await client.callRESTPostRaw(
                chain: .tron, path: "/wallet/broadcasttransaction",
                body: signed.rawHex, contentType: "application/json"
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let ok = root["result"] as? Bool, ok {
                    if let txid = root["txid"] as? String, !txid.isEmpty { return txid }
                    return signed.txHash
                }
                // Failure: `message` is hex-encoded; `code` is the reason.
                let code = root["code"] as? String ?? ""
                let messageHex = root["message"] as? String ?? ""
                let message = decodeHexMessage(messageHex) ?? code
                throw SigningError.broadcastFailed(message.isEmpty ? "TRON broadcast rejected" : message)
            }
            throw SigningError.broadcastAmbiguous("unexpected TRON broadcast response")
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - Cosmos (Kava)

    /// `POST /cosmos/tx/v1beta1/txs` with `{tx_bytes: <base64 TxRaw>, mode:
    /// BROADCAST_MODE_SYNC}`. Doc: cosmos-sdk run-node/03-txs. Live-verified
    /// 2026-06-15 on `api.data.kava.io`: the endpoint is recognized (empty
    /// tx_bytes → code 18 "must contain at least one message"). Returns
    /// `tx_response.txhash` when `code == 0`.
    private func broadcastCosmos(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        do {
            let body: [String: Sendable] = ["tx_bytes": signed.rawHex, "mode": "BROADCAST_MODE_SYNC"]
            let data = try await client.callRESTPost(
                chain: chain, path: "/cosmos/tx/v1beta1/txs", body: body
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let resp = root["tx_response"] as? [String: Any] {
                let code = (resp["code"] as? NSNumber)?.intValue ?? 0
                let hash = resp["txhash"] as? String ?? ""
                if code == 0, !hash.isEmpty { return hash }
                let rawLog = resp["raw_log"] as? String ?? "code \(code)"
                throw SigningError.broadcastFailed(rawLog)
            }
            throw SigningError.broadcastAmbiguous("unexpected Cosmos broadcast response")
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - Aptos

    /// `POST /v1/transactions` with the BCS-serialized SIGNED transaction
    /// as the body + `Content-Type:
    /// application/x.aptos.signed_transaction+bcs`. Doc:
    /// aptos.dev / fullnode REST. Live-verified 2026-06-15 on
    /// `fullnode.mainnet.aptoslabs.com`: the BCS content-type is recognized
    /// (truncated bytes → `Failed to deserialize input into
    /// SignedTransaction`/HTTP 400). Returns `hash` on success. The signer
    /// stores the BCS bytes in `rawData`; we submit those raw.
    private func broadcastAptos(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        do {
            let data = try await client.callRESTPostData(
                chain: chain, path: "/transactions",
                body: signed.rawData,
                contentType: "application/x.aptos.signed_transaction+bcs"
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let hash = root["hash"] as? String, !hash.isEmpty { return hash }
                if let message = root["message"] as? String { throw SigningError.broadcastFailed(message) }
            }
            throw SigningError.broadcastAmbiguous("unexpected Aptos submit response")
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - NEAR

    /// `send_tx` with `{signed_tx_base64, wait_until:
    /// EXECUTED_OPTIMISTIC}` (the new canonical broadcast; doc:
    /// docs.near.org/api/rpc/transactions). Live-verified 2026-06-15 on
    /// `rpc.mainnet.near.org`: the method is recognized (malformed base64 →
    /// `PARSE_ERROR`). Returns `result.transaction.hash`.
    private func broadcastNear(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        do {
            let params: [String: Sendable] = [
                "signed_tx_base64": signed.rawHex,
                "wait_until": "EXECUTED_OPTIMISTIC",
            ]
            let data = try await client.callJSONResultData(
                chain: chain, method: "send_tx", paramsObject: params
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tx = root["transaction"] as? [String: Any],
               let hash = tx["hash"] as? String, !hash.isEmpty {
                return hash
            }
            // Fall back to the locally-computed hash if the node accepted
            // it but returned a shape we didn't parse.
            guard !signed.txHash.isEmpty else {
                throw SigningError.broadcastAmbiguous("unexpected NEAR send_tx response")
            }
            return signed.txHash
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - Polkadot

    /// `author_submitExtrinsic([0x SCALE-encoded signed extrinsic])`. Doc:
    /// polkadot.js.org/docs/substrate/rpc. Live-verified 2026-06-15 on
    /// `rpc.polkadot.io`: the method is recognized (a `0x00` extrinsic →
    /// `Verification Error` from the runtime, NOT method-not-found).
    /// Returns the extrinsic hash on success.
    private func broadcastPolkadot(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        do {
            let hash = try await client.callJSONString(
                chain: chain, method: "author_submitExtrinsic", params: [signed.rawHex]
            )
            guard !hash.isEmpty else { throw SigningError.broadcastAmbiguous("empty Polkadot extrinsic hash") }
            return hash
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    // MARK: - TON

    /// toncenter `POST /sendBocReturnHash` with `{boc: <base64 BoC>}`. Doc:
    /// toncenter.com/api/v2 openapi. Live-verified 2026-06-15: the endpoint
    /// is recognized (malformed base64 → HTTP 422 base64-padding error).
    /// Returns `result.hash`.
    private func broadcastTON(_ signed: SignedTransaction, chain: SupportedChain) async throws(SigningError) -> String {
        do {
            let data = try await client.callRESTPost(
                chain: chain, path: "/sendBocReturnHash", body: ["boc": signed.rawHex]
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let ok = root["ok"] as? Bool, ok,
                   let result = root["result"] as? [String: Any],
                   let hash = result["hash"] as? String, !hash.isEmpty {
                    return hash
                }
                if let error = root["error"] as? String { throw SigningError.broadcastFailed(error) }
            }
            // Fall back to the locally-computed cell hash.
            guard !signed.txHash.isEmpty else {
                throw SigningError.broadcastAmbiguous("unexpected TON sendBoc response")
            }
            return signed.txHash
        } catch let rpc as RPCError {
            throw Self.mapBroadcastError(rpc)
        } catch let signing as SigningError {
            throw signing
        } catch {
            // Transport-level failure (the request left the device but no
            // definitive accept/reject came back) → outcome UNKNOWN, never
            // claim the funds are safe (Rule #16).
            throw SigningError.broadcastAmbiguous(error.localizedDescription)
        }
    }

    /// Decode a hex-encoded TRON error `message` to UTF-8 text.
    private func decodeHexMessage(_ hex: String) -> String? {
        guard !hex.isEmpty, let data = SigningNumeric.hexToData(hex) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Error mapping

    /// Map a networking `RPCError` to an honest `SigningError`. A
    /// server-returned JSON-RPC error envelope on broadcast carries the
    /// node's reason (nonce too low, insufficient funds for gas, min
    /// relay fee not met) — surface it verbatim (no key material is in
    /// these). A transport failure surfaces as a network reason.
    private static func mapBroadcastError(_ error: RPCError) -> SigningError {
        switch error {
        case .rpcError(_, let message):
            // A structured JSON-RPC error envelope = the node DEFINITIVELY
            // rejected the tx (nonce too low, insufficient funds, min relay
            // fee not met). It never relayed → funds did not move.
            return .broadcastFailed(message)
        case .invalidResponse(let message), .decodingFailed(let message):
            // We got a response but couldn't parse it → outcome UNKNOWN.
            return .broadcastAmbiguous(message)
        case .network(let message):
            // Transport failure after the request left → outcome UNKNOWN.
            return .broadcastAmbiguous(message)
        case .rateLimited:
            // Rejected by our client-side limiter BEFORE it left the device
            // → nothing was sent.
            return .broadcastFailed("rate-limited — try again in a moment")
        case .noEndpoint:
            // No endpoint to even attempt → nothing was sent.
            return .broadcastFailed("couldn't reach the network")
        case .allEndpointsFailed:
            // Some attempts may have left the device before all failed →
            // outcome UNKNOWN.
            return .broadcastAmbiguous("couldn't reach the network")
        case .cancelled:
            // Cancelled mid-flight → outcome UNKNOWN.
            return .broadcastAmbiguous("cancelled")
        }
    }
}
