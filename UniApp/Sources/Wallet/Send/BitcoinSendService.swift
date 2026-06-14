import Foundation
import SwiftData
import WalletCore

/// Real UTXO send for the four Bitcoin-family chains Aperture supports:
/// **Bitcoin (BTC), Bitcoin Cash (BCH), Litecoin (LTC), Dogecoin (DOGE).**
/// One implementation; the per-chain provider (Esplora / BlockCypher /
/// Haskoin) and the per-address script variant differentiate.
///
/// Pipeline (mirrors `EVMSendService`'s shape, adapted to the UTXO model):
/// fetch the sender's UTXO set + the network fee-rate (REST) → estimate
/// three sat/vByte fee tiers → build a wallet-core `BitcoinSigningInput`
/// (`AnySigner.plan` then `AnySigner.sign`) → broadcast the raw hex via the
/// chain's submit endpoint → poll status. All off the main actor (Rule #28);
/// every fee/UTXO value is fetched live (no guesses where an API exists),
/// and a node rejection surfaces its real reason (Rule #16 / Rule #26).
///
/// **wallet-core usage** is mirrored verbatim from the proven Stabro
/// `TransactionSigner.signBitcoinTransaction` single-key path
/// (`BitcoinSigningInput` with `hashType` / `amount` / `byteFee` /
/// `toAddress` / `changeAddress` / `coinType` / `useMaxAmount` /
/// `privateKey` / per-UTXO `BitcoinUnspentTransaction` with `outPoint` +
/// `script` + `variant`, `AnySigner.plan` → `input.plan` →
/// `AnySigner.sign`). Our `ChainKeyProvider` supplies the single derived
/// (key, address) — so we fetch UTXOs for that one address and spend with
/// one key, exactly the single-key Stabro path.
///
/// **Custody.** The signing key is derived inside `performSend` via
/// `ChainKeyProvider.signingMaterial`, used by the synchronous `sign`, and
/// drops at function exit; nothing key- or signature-shaped is ever logged.
///
/// ⚠️ UNVERIFIED until a real tiny-amount test send on-device — the crypto
/// is wallet-core's and the RPC shapes were validated live, but the full
/// wiring is exercised by that first real mainnet send.
enum BitcoinSendService {

    // MARK: - Tunables

    /// Conservative per-input vByte estimate (legacy/SegWit mix) used both
    /// for the displayed fee and as the auto-adjust guard inside signing —
    /// matches Stabro's `request.bitcoinUTXOs.count * 68 + 31*2 + 10`.
    private static let vBytesPerInput: Int = 68
    private static let vBytesPerOutput: Int = 31
    private static let vBytesOverhead: Int = 10
    /// Two outputs: recipient + change.
    private static let outputCount: Int = 2

    /// Conservative default sat/vByte when the chain has no fee API
    /// reachable (per recipe §feeEstimation). DOGE's 100k is the protocol
    /// minimum, NOT a choice; BCH is a very cheap network.
    private static func defaultSatPerVByte(for chain: SupportedChain) -> Int {
        switch chain {
        case .dogecoin:    return 100_000   // DOGE protocol minimum
        case .bitcoinCash: return 2         // very cheap network
        case .litecoin:    return 10        // ~0.00014 LTC
        default:           return 10        // BTC fallback only
        }
    }

    /// Rough confirmation seconds per tier (the UI's "~N min" line).
    private static func estimatedSeconds(for chain: SupportedChain, speed: ChainFeeOption.Speed) -> Int {
        // DOGE has ~1-minute blocks, LTC ~2.5-minute, BTC ~10-minute. Use
        // per-chain bases scaled by tier so the UI is honest.
        let base: Int
        switch chain {
        case .dogecoin:    base = 60
        case .litecoin:    base = 150
        case .bitcoinCash: base = 600
        default:           base = 600       // BTC
        }
        switch speed {
        case .slow:   return base * 6
        case .normal: return base * 2
        case .fast:   return base
        }
    }

    // MARK: - Off-main orchestration (called from the @MainActor view-model)

    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        guard Self.coinType(for: chain) != nil else { throw .unsupportedChain(chain) }
        // UTXO chains have no token sends — there is nothing to fee-estimate
        // for a non-native asset.
        guard isNative else { throw .unsupportedChain(chain) }

        let from = try ChainKeyProvider.senderAddress(for: chain, container: container)
        let baseRate = await fetchSatPerVByte(chain: chain)
        // Estimate vBytes from the live UTXO count when reachable, else a
        // single-input default; never throw here — fees degrade gracefully.
        let utxoCount = (try? await fetchUTXOs(chain: chain, address: from).count) ?? 1
        let vBytes = estimateVBytes(inputCount: max(utxoCount, 1))

        // Three tiers off the base rate (recipe §feeEstimation: 0.85× /
        // 1.0× / 1.3×). DOGE/BCH defaults are protocol minimums, so the
        // slow tier never drops below the base for those chains.
        let tiers: [(ChainFeeOption.Speed, Double)] = [
            (.slow,   0.85),
            (.normal, 1.0),
            (.fast,   1.3),
        ]
        let minRate = defaultSatPerVByte(for: chain)
        return tiers.map { (speed, mul) in
            var rate = Int((Double(baseRate) * mul).rounded())
            if rate < minRate { rate = minRate }
            if rate < 1 { rate = 1 }
            let totalSat = UInt64(rate) &* UInt64(vBytes)
            return ChainFeeOption(
                speed: speed,
                feeNative: satToNative(totalSat),
                estimatedSeconds: estimatedSeconds(for: chain, speed: speed),
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        }
    }

    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard Self.coinType(for: chain) != nil else { throw .unsupportedChain(chain) }
        guard isNative else { throw .unsupportedChain(chain) }

        let (key, from) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // The chosen tier's sat/vByte — recompute the SAME way loadFees did
        // so the signed fee matches what the user saw.
        let baseRate = await fetchSatPerVByte(chain: chain)
        let mul: Double = speed == .slow ? 0.85 : (speed == .fast ? 1.3 : 1.0)
        var satPerVByte = Int((Double(baseRate) * mul).rounded())
        let minRate = defaultSatPerVByte(for: chain)
        if satPerVByte < minRate { satPerVByte = minRate }
        if satPerVByte < 1 { satPerVByte = 1 }

        let utxos = try await fetchUTXOs(chain: chain, address: from)
        guard !utxos.isEmpty else {
            throw .missingContext("No spendable coins were found for this address.")
        }

        // Sign synchronously (the derived key never crosses an `await`),
        // then broadcast off-main. The two Sendable strings (rawHex,
        // localTxID) are all that cross the await boundary.
        let signed = try sign(
            chain: chain, key: key, fromAddress: from, toAddress: toAddress,
            rawAmount: rawAmount, satPerVByte: satPerVByte, utxos: utxos
        )

        // Broadcast the raw hex per chain; prefer the node-returned txid.
        let networkTxID = try await broadcast(chain: chain, rawHex: signed.rawHex)
        let finalHash = networkTxID.isEmpty ? signed.localTxID : networkTxID
        return ChainSignedTransaction(broadcastPayload: signed.rawHex, txHash: finalHash)
    }

    // MARK: - Sign (mirrors Stabro signBitcoinTransaction, single-key)

    /// The signed transaction bytes + locally-derived txid. Both are
    /// `Sendable`, so they cross the broadcast `await` cleanly while the
    /// wallet-core `PrivateKey` / `BitcoinSigningInput` stay confined to
    /// this synchronous call.
    private struct SignedBytes: Sendable { let rawHex: String; let localTxID: String }

    private nonisolated static func sign(
        chain: SupportedChain,
        key: PrivateKey,
        fromAddress: String,
        toAddress: String,
        rawAmount: String,
        satPerVByte: Int,
        utxos: [UTXO]
    ) throws(ChainSendError) -> SignedBytes {
        guard let coin = Self.coinType(for: chain) else { throw .unsupportedChain(chain) }

        var satoshiAmount = Int64(rawAmount) ?? 0
        guard satoshiAmount > 0 else { throw .signingFailed("Invalid amount.") }
        let satPerByte = Int64(satPerVByte)
        guard satPerByte > 0 else { throw .feeUnavailable }

        // Auto-adjust + useMaxAmount, exactly as Stabro: if amount + fee
        // exceeds the spendable total, reduce the amount to fit; if the
        // user is sending nearly everything, let wallet-core sweep with
        // useMaxAmount.
        let totalUTXOValue = utxos.reduce(Int64(0)) { $0 + Int64($1.value) }
        let estimatedVBytes = Int64(utxos.count) * Int64(vBytesPerInput)
            + Int64(vBytesPerOutput) * Int64(outputCount) + Int64(vBytesOverhead)
        let estimatedFee = satPerByte * estimatedVBytes

        if satoshiAmount + estimatedFee > totalUTXOValue {
            let adjusted = totalUTXOValue - estimatedFee
            if adjusted > 0 { satoshiAmount = adjusted }
        }
        let useMax = satoshiAmount + estimatedFee >= totalUTXOValue

        var input = BitcoinSigningInput()
        input.hashType = BitcoinScript.hashTypeForCoin(coinType: coin)
        input.amount = satoshiAmount
        input.byteFee = satPerByte
        input.toAddress = toAddress
        input.changeAddress = fromAddress
        input.coinType = coin.rawValue
        input.useMaxAmount = useMax
        input.privateKey = [key.data]

        for utxo in utxos {
            var outPoint = BitcoinOutPoint()
            // The previous-tx hash is byte-reversed for the outpoint (Stabro
            // line 1259). `Data(hexString:)` is wallet-core's own decoder.
            if let txidData = Data(hexString: utxo.txid) {
                outPoint.hash = Data(txidData.reversed())
            }
            outPoint.index = utxo.vout

            var unspent = BitcoinUnspentTransaction()
            unspent.outPoint = outPoint
            unspent.amount = Int64(utxo.value)

            let script = BitcoinScript.lockScriptForAddress(address: utxo.address, coin: coin)
            unspent.script = script.data

            // Per-address script variant + redeem-script registration —
            // verbatim from Stabro lines 1271–1292.
            let addr = utxo.address
            if addr.hasPrefix("bc1q") || addr.hasPrefix("ltc1q") {
                // Native SegWit (P2WPKH) — BTC, LTC
                unspent.variant = .p2Wpkh
                if let scriptHash = script.matchPayToWitnessPublicKeyHash() {
                    input.scripts[scriptHash.hexString] = BitcoinScript.buildPayToPublicKeyHash(hash: scriptHash).data
                }
            } else if addr.hasPrefix("bc1p") {
                // Taproot (P2TR) — BTC
                unspent.variant = .p2Trkeypath
            } else if addr.hasPrefix("3") || addr.hasPrefix("M") {
                // P2SH-P2WPKH — BTC (3...), LTC (M...)
                unspent.variant = .p2Wpkh
                if let scriptHash = script.matchPayToScriptHash() {
                    input.scripts[scriptHash.hexString] = BitcoinScript.buildPayToPublicKeyHash(hash: scriptHash).data
                }
            } else {
                // Legacy P2PKH — BTC (1...), LTC (L...), DOGE (D...), BCH (q.../legacy)
                unspent.variant = .p2Pkh
            }

            input.utxo.append(unspent)
        }

        // Run the planner first for proper fee/change calculation (Stabro
        // line 1297), then sign.
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: coin)
        input.plan = plan

        let output: BitcoinSigningOutput = AnySigner.sign(input: input, coin: coin)

        guard output.error == .ok else {
            throw Self.mapSigningError(output.error)
        }
        guard !output.encoded.isEmpty else {
            throw .signingFailed("Signer returned an empty transaction.")
        }

        return SignedBytes(rawHex: output.encoded.hexString, localTxID: output.transactionID)
    }

    /// Maps wallet-core's `Common_Proto_SigningError` to an honest
    /// `ChainSendError` (Stabro lines 1305–1322 mapping, our error type).
    private nonisolated static func mapSigningError(_ error: WalletCore.CommonSigningError) -> ChainSendError {
        switch error {
        case .errorNotEnoughUtxos, .errorLowBalance:
            return .broadcastRejected("Balance is less than the amount plus the network fee.")
        case .errorMissingInputUtxos:
            return .signingFailed("Missing UTXO data.")
        case .errorInvalidUtxo, .errorInvalidUtxoAmount:
            return .signingFailed("A spendable coin was in an unexpected format.")
        case .errorMissingPrivateKey, .errorInvalidPrivateKey:
            return .walletCannotSign
        case .errorInvalidAddress:
            return .signingFailed("The recipient address isn't valid for this network.")
        case .errorWrongFee:
            return .feeUnavailable
        case .errorDustAmountRequested:
            return .broadcastRejected("The amount is below the network's dust threshold.")
        default:
            return .signingFailed("Signing failed (code \(error.rawValue)).")
        }
    }

    // MARK: - Status

    nonisolated static func status(
        chain: SupportedChain, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        switch chain {
        case .bitcoin, .litecoin:
            return try await esploraStatus(chain: chain, txid: txHash)
        case .dogecoin:
            return try await blockCypherStatus(chain: chain, txid: txHash)
        case .bitcoinCash:
            return try await haskoinStatus(txid: txHash)
        default:
            throw .unsupportedChain(chain)
        }
    }

    // MARK: - UTXO fetch (per chain)

    /// A single spendable output, normalized across the three provider
    /// shapes (Esplora / BlockCypher / Haskoin).
    private struct UTXO: Sendable {
        let txid: String
        let vout: UInt32
        let value: UInt64
        /// The owning address — always the queried sender (single-address
        /// path), which `BitcoinScript.lockScriptForAddress` needs.
        let address: String
    }

    private nonisolated static func fetchUTXOs(
        chain: SupportedChain, address: String
    ) async throws(ChainSendError) -> [UTXO] {
        switch chain {
        case .bitcoin, .litecoin:
            return try await esploraUTXOs(chain: chain, address: address)
        case .dogecoin:
            return try await blockCypherUTXOs(chain: chain, address: address)
        case .bitcoinCash:
            return try await haskoinUTXOs(address: address)
        default:
            throw .unsupportedChain(chain)
        }
    }

    // Esplora `GET /address/{addr}/utxo` (BTC, LTC). Registered base
    // already includes `/api`, so the path is `/address/{addr}/utxo`.
    private nonisolated static func esploraUTXOs(
        chain: SupportedChain, address: String
    ) async throws(ChainSendError) -> [UTXO] {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(chain: chain, path: "/address/\(address)/utxo")
        } catch { throw mapRPC(error) }

        struct EsploraUTXO: Decodable { let txid: String; let vout: Int; let value: UInt64 }
        guard let rows = try? JSONDecoder().decode([EsploraUTXO].self, from: data) else {
            throw .missingContext("Couldn't read the coin list.")
        }
        return rows.map { UTXO(txid: $0.txid, vout: UInt32($0.vout), value: $0.value, address: address) }
    }

    // BlockCypher `GET /addrs/{addr}?unspentOnly=true&...` (DOGE). The
    // registered base is `…/v1/doge/main`, so the path is `/addrs/{addr}`.
    // `includeScript=true` returns each output's lock script; `confirmations`
    // is present per txref.
    private nonisolated static func blockCypherUTXOs(
        chain: SupportedChain, address: String
    ) async throws(ChainSendError) -> [UTXO] {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(
                chain: chain,
                path: "/addrs/\(address)",
                query: [
                    URLQueryItem(name: "unspentOnly", value: "true"),
                    URLQueryItem(name: "limit", value: "2000"),
                    URLQueryItem(name: "includeScript", value: "true"),
                ]
            )
        } catch { throw mapRPC(error) }

        struct BCAddr: Decodable {
            let txrefs: [BCTxRef]?
            struct BCTxRef: Decodable {
                let tx_hash: String
                let tx_output_n: Int
                let value: UInt64
                let spent: Bool?
            }
        }
        guard let decoded = try? JSONDecoder().decode(BCAddr.self, from: data) else {
            throw .missingContext("Couldn't read the coin list.")
        }
        let refs = (decoded.txrefs ?? []).filter { ($0.spent ?? false) == false && $0.tx_output_n >= 0 }
        return refs.map {
            UTXO(txid: $0.tx_hash, vout: UInt32($0.tx_output_n), value: $0.value, address: address)
        }
    }

    // Haskoin `GET /bch/address/{addr}/unspent` (BCH). Registered base is
    // `https://api.haskoin.com`, so the path is `/bch/address/{addr}/unspent`.
    private nonisolated static func haskoinUTXOs(
        address: String
    ) async throws(ChainSendError) -> [UTXO] {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(
                chain: .bitcoinCash, path: "/bch/address/\(address)/unspent"
            )
        } catch { throw mapRPC(error) }

        struct HaskoinUTXO: Decodable {
            let txid: String
            let index: Int
            let value: UInt64
            let address: String?
        }
        guard let rows = try? JSONDecoder().decode([HaskoinUTXO].self, from: data) else {
            throw .missingContext("Couldn't read the coin list.")
        }
        // Haskoin returns the CashAddr form (`bitcoincash:q…`). Use the
        // returned address when present so `lockScriptForAddress` sees the
        // exact owning form; fall back to the queried address.
        return rows.map {
            UTXO(txid: $0.txid, vout: UInt32($0.index), value: $0.value, address: $0.address ?? address)
        }
    }

    // MARK: - Fee-rate fetch (per chain)

    /// The base sat/vByte for `chain`. BTC uses Esplora `/fee-estimates`
    /// (block-target → sat/vB Double); LTC uses litecoinspace's
    /// mempool-style `/v1/fees/recommended`; DOGE/BCH have no live API, so
    /// the recipe default is the base. Never throws — degrades to the
    /// conservative default so a fee can always be shown.
    private nonisolated static func fetchSatPerVByte(chain: SupportedChain) async -> Int {
        switch chain {
        case .bitcoin:
            if let r = try? await esploraFeeRate(chain: chain) { return r }
            return defaultSatPerVByte(for: chain)
        case .litecoin:
            if let r = try? await litecoinFeeRate() { return r }
            return defaultSatPerVByte(for: chain)
        default:
            // DOGE / BCH — protocol minimum / network-cheap default.
            return defaultSatPerVByte(for: chain)
        }
    }

    // Esplora `GET /fee-estimates` → {"1":1.15,"6":0.56,...} (block target
    // → sat/vB). Pick the ~6-block ("normal") target; ceil to ≥1.
    private nonisolated static func esploraFeeRate(chain: SupportedChain) async throws(ChainSendError) -> Int {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(chain: chain, path: "/fee-estimates")
        } catch { throw mapRPC(error) }
        guard let map = try? JSONDecoder().decode([String: Double].self, from: data) else {
            throw .feeUnavailable
        }
        let target = map["6"] ?? map["3"] ?? map["1"] ?? Double(defaultSatPerVByte(for: chain))
        return max(1, Int(target.rounded(.up)))
    }

    // litecoinspace `GET /v1/fees/recommended` → mempool-style object. The
    // registered base is `…/api`, so the path is `/v1/fees/recommended`.
    private nonisolated static func litecoinFeeRate() async throws(ChainSendError) -> Int {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(chain: .litecoin, path: "/v1/fees/recommended")
        } catch { throw mapRPC(error) }
        struct Recommended: Decodable { let hourFee: Int?; let halfHourFee: Int?; let minimumFee: Int? }
        guard let r = try? JSONDecoder().decode(Recommended.self, from: data) else {
            throw .feeUnavailable
        }
        let rate = max(r.hourFee ?? 0, r.minimumFee ?? 0)
        return max(1, rate)
    }

    // MARK: - Broadcast (per chain)

    private nonisolated static func broadcast(
        chain: SupportedChain, rawHex: String
    ) async throws(ChainSendError) -> String {
        switch chain {
        case .bitcoin, .litecoin:
            return try await esploraBroadcast(chain: chain, rawHex: rawHex)
        case .dogecoin:
            return try await blockCypherBroadcast(chain: chain, rawHex: rawHex)
        case .bitcoinCash:
            return try await haskoinBroadcast(rawHex: rawHex)
        default:
            throw .unsupportedChain(chain)
        }
    }

    // Esplora `POST /tx` with raw hex `text/plain`; returns the txid as
    // plain text (BTC, LTC). `callRESTPostRaw` folds the server's rejection
    // text into the thrown error on a non-2xx.
    private nonisolated static func esploraBroadcast(
        chain: SupportedChain, rawHex: String
    ) async throws(ChainSendError) -> String {
        guard let body = rawHex.data(using: .utf8) else {
            throw .signingFailed("Could not encode the transaction.")
        }
        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPostRaw(
                chain: chain, path: "/tx", body: body, contentType: "text/plain"
            )
        } catch { throw broadcastError(error) }
        let txid = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard txid.count >= 60 else {
            throw .broadcastRejected(txid.isEmpty ? "The network rejected the transaction." : txid)
        }
        return txid
    }

    // BlockCypher `POST /txs/push` with JSON `{"tx":"<hex>"}`; success
    // returns a TXSkeleton whose `tx.hash` is the txid, error returns
    // `{"error":"…"}` (DOGE).
    private nonisolated static func blockCypherBroadcast(
        chain: SupportedChain, rawHex: String
    ) async throws(ChainSendError) -> String {
        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPost(
                chain: chain, path: "/txs/push", body: ["tx": rawHex]
            )
        } catch { throw broadcastError(error) }

        struct PushResult: Decodable {
            let tx: TX?
            let error: String?
            let errors: [BCError]?
            struct TX: Decodable { let hash: String? }
            struct BCError: Decodable { let error: String? }
        }
        if let decoded = try? JSONDecoder().decode(PushResult.self, from: data) {
            if let hash = decoded.tx?.hash, !hash.isEmpty { return hash }
            if let err = decoded.error, !err.isEmpty { throw .broadcastRejected(err) }
            if let first = decoded.errors?.first?.error, !first.isEmpty { throw .broadcastRejected(first) }
        }
        let body = String(decoding: data.prefix(240), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw .broadcastRejected(body.isEmpty ? "The network rejected the transaction." : body)
    }

    // Haskoin `POST /bch/transactions` with raw hex `text/plain`; success
    // returns the stored tx object (`{"txid":"…"}`), error returns
    // `{"error":…,"message":…}` (BCH).
    private nonisolated static func haskoinBroadcast(
        rawHex: String
    ) async throws(ChainSendError) -> String {
        guard let body = rawHex.data(using: .utf8) else {
            throw .signingFailed("Could not encode the transaction.")
        }
        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPostRaw(
                chain: .bitcoinCash, path: "/bch/transactions", body: body, contentType: "text/plain"
            )
        } catch { throw broadcastError(error) }

        struct HaskoinPush: Decodable { let txid: String?; let error: String?; let message: String? }
        if let decoded = try? JSONDecoder().decode(HaskoinPush.self, from: data) {
            if let txid = decoded.txid, !txid.isEmpty { return txid }
            if let msg = decoded.message ?? decoded.error, !msg.isEmpty { throw .broadcastRejected(msg) }
        }
        let body2 = String(decoding: data.prefix(240), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw .broadcastRejected(body2.isEmpty ? "The network rejected the transaction." : body2)
    }

    // MARK: - Status (per chain)

    // Esplora `GET /tx/{txid}` → status.confirmed / block_height (BTC, LTC).
    private nonisolated static func esploraStatus(
        chain: SupportedChain, txid: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(chain: chain, path: "/tx/\(txid)")
        } catch {
            if case RPCError.invalidResponse(let m) = error, m.contains("404") { return .pending }
            throw mapRPC(error)
        }
        struct EsploraTx: Decodable {
            let status: Status?
            struct Status: Decodable { let confirmed: Bool?; let block_height: UInt64? }
        }
        guard let tx = try? JSONDecoder().decode(EsploraTx.self, from: data) else { return .pending }
        if tx.status?.confirmed == true {
            return .confirmed(blockNumber: tx.status?.block_height)
        }
        return .pending
    }

    // BlockCypher `GET /txs/{hash}` → confirmations / block_height (DOGE).
    private nonisolated static func blockCypherStatus(
        chain: SupportedChain, txid: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(chain: chain, path: "/txs/\(txid)")
        } catch {
            if case RPCError.invalidResponse(let m) = error, m.contains("404") { return .pending }
            throw mapRPC(error)
        }
        struct BCTx: Decodable { let confirmations: Int?; let block_height: Int? }
        guard let tx = try? JSONDecoder().decode(BCTx.self, from: data) else { return .pending }
        let confs = tx.confirmations ?? 0
        if confs > 0 {
            let height = tx.block_height.flatMap { $0 > 0 ? UInt64($0) : nil }
            return .confirmed(blockNumber: height)
        }
        return .pending
    }

    // Haskoin `GET /bch/transaction/{txid}` → `block` present = confirmed
    // (BCH).
    private nonisolated static func haskoinStatus(
        txid: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(chain: .bitcoinCash, path: "/bch/transaction/\(txid)")
        } catch {
            if case RPCError.invalidResponse(let m) = error, m.contains("404") { return .pending }
            throw mapRPC(error)
        }
        struct HaskoinTx: Decodable {
            let block: Block?
            let error: String?
            struct Block: Decodable { let height: Int? }
        }
        guard let tx = try? JSONDecoder().decode(HaskoinTx.self, from: data) else { return .pending }
        if let height = tx.block?.height, height > 0 {
            return .confirmed(blockNumber: UInt64(height))
        }
        return .pending
    }

    // MARK: - Helpers

    /// Whether `chain` is one of the four UTXO chains this service owns, and
    /// the wallet-core `CoinType` to drive signing.
    private nonisolated static func coinType(for chain: SupportedChain) -> CoinType? {
        switch chain {
        case .bitcoin:     return .bitcoin
        case .bitcoinCash: return .bitcoinCash
        case .litecoin:    return .litecoin
        case .dogecoin:    return .dogecoin
        default:           return nil
        }
    }

    private nonisolated static func estimateVBytes(inputCount: Int) -> Int {
        inputCount * vBytesPerInput + vBytesPerOutput * outputCount + vBytesOverhead
    }

    /// satoshis → native units (BTC/LTC/DOGE/BCH all use 8 decimals).
    private nonisolated static func satToNative(_ sats: UInt64) -> Decimal {
        Decimal(sats) / pow(Decimal(10), 8)
    }

    /// Map a networking-layer `RPCError` to a `ChainSendError` for the
    /// read paths (UTXO / fee / status).
    private nonisolated static func mapRPC(_ error: Error) -> ChainSendError {
        guard let rpc = error as? RPCError else { return .rpcUnavailable }
        switch rpc {
        case .noEndpoint(let c): return .unsupportedChain(c)
        case .cancelled:         return .rpcUnavailable
        case .network, .rateLimited, .allEndpointsFailed:
            return .rpcUnavailable
        case .invalidResponse, .decodingFailed, .rpcError:
            return .missingContext("The network returned an unexpected response.")
        }
    }

    /// Map a broadcast `RPCError` to an honest `.broadcastRejected` — the
    /// server's rejection text is already folded into `.invalidResponse`
    /// by `callRESTPostRaw` (Rule #16 / Rule #26).
    private nonisolated static func broadcastError(_ error: Error) -> ChainSendError {
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

    /// Trim the provider's raw rejection to a human-readable line.
    private nonisolated static func cleanRejection(_ raw: String) -> String {
        let low = raw.lowercased()
        if low.contains("insufficient") || low.contains("not enough") {
            return "Balance is less than the amount plus the network fee."
        }
        if low.contains("dust") {
            return "The amount is below the network's dust threshold."
        }
        if low.contains("fee") && (low.contains("low") || low.contains("min")) {
            return "The fee is too low — pick a faster speed."
        }
        if low.contains("already") && low.contains("spent") || low.contains("double") {
            return "These coins were already spent. Refresh and try again."
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The network rejected the transaction." : trimmed
    }
}
