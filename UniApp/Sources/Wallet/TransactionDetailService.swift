import Foundation
import OSLog
import CryptoKit

/// Fetches the FULL live detail of a single transaction for every chain
/// Aperture supports, returning a `Sendable` `TransactionDetail` the
/// Transaction Detail screen renders. Owned by the chain-data domain
/// (Rule #24); reads through the shared, rate-limited `RPCClient`
/// (Rule #27); runs off-main and fires multi-call fetches in parallel
/// (Rule #28).
///
/// **Routing.** `detail(...)` switches on `chain.family` (and the chain
/// itself for the Bitcoin per-provider split) to a per-family fetcher,
/// each reusing the EXACT call path the matching history adapter already
/// uses (live-verified 2026-06-15):
/// - **Bitcoin** (`BTC/LTC` Esplora, `BCH` Haskoin, `DOGE` BlockCypher):
///   detail JSON + raw hex fetched as `async let` in parallel.
/// - **EVM** (all 12): `eth_getTransactionByHash` +
///   `eth_getTransactionReceipt` + `eth_blockNumber` as `async let` in
///   parallel.
/// - **Solana**: a single `getTransaction` (jsonParsed,
///   `maxSupportedTransactionVersion: 0`) — returns every field.
/// - **The 9 others** (XRPL, TRON, TON, NEAR, Aptos, Cosmos/Kava,
///   Polkadot, Stellar, Sui): a `.generic` labeled key-value list.
///
/// **Honesty (Rule #16 / #26).** Returns `nil` on failure — never
/// fabricates. A chain whose detail can't be hydrated falls back to a
/// `.generic` payload built from the values the caller already has. Money
/// math is `Decimal` throughout; the heavy `JSONSerialization` parse runs
/// on a background task and only the small `Sendable` model crosses back.
enum TransactionDetailService {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "tx-detail")
    private static var liveDetailFetchingEnabled: Bool { false }

    /// The ERC-20 `Transfer(address,address,uint256)` topic-0 — identical
    /// across every EVM chain.
    private static let transferTopic =
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

    /// Fetch the full detail of one transaction.
    ///
    /// - Parameters:
    ///   - chain: the chain the tx lives on (from the stored record's
    ///     `address?.chainRaw`).
    ///   - txHash: the on-chain hash / signature / extrinsic id.
    ///   - tokenContract: the token contract/mint when the row is a token
    ///     transfer (`nil` for native) — used to label/scope where helpful.
    ///   - address: the wallet address the row belongs to. REQUIRED by TON
    ///     (no global-hash lookup) and used as the NEAR signer fallback;
    ///     optional/defaulted so native callers that only have the hash
    ///     still work for every other chain.
    ///   - counterparty: the stored counterparty — used as the NEAR
    ///     `sender_account_id` for incoming rows (the signer is the
    ///     counterparty, not the wallet). Optional/defaulted.
    ///   - client: the shared rate-limited client (injectable for tests).
    /// - Returns: the full detail, or `nil` if the live fetch failed.
    static func detail(
        chain: SupportedChain,
        txHash: String,
        tokenContract: String? = nil,
        address: String? = nil,
        counterparty: String? = nil,
        client: RPCClient = .shared
    ) async -> TransactionDetail? {
        guard liveDetailFetchingEnabled else { return nil }

        let hash = txHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return nil }

        switch chain.family {
        case .bitcoin:
            return await bitcoin(chain: chain, txid: hash, client: client)
        case .evm:
            return await evm(chain: chain, hash: hash, client: client)
        case .ed25519 where chain == .solana:
            return await solana(hash: hash, client: client)
        case .ed25519 where chain == .stellar:
            return await stellar(hash: hash, address: address, client: client)
        case .ed25519 where chain == .sui:
            return await sui(hash: hash, client: client)
        case .ripple:
            return await xrpl(hash: hash, address: address, client: client)
        case .tron:
            return await tron(hash: hash, client: client)
        case .ton:
            return await ton(hash: hash, address: address, client: client)
        case .near:
            return await near(hash: hash, address: address, counterparty: counterparty, client: client)
        case .aptos:
            return await aptos(hash: hash, client: client)
        case .cosmos:
            return await cosmos(chain: chain, hash: hash, client: client)
        case .polkadot:
            return await polkadot(idOrHash: hash)
        default:
            return nil
        }
    }

    // MARK: - Bitcoin family

    private static func bitcoin(
        chain: SupportedChain,
        txid: String,
        client: RPCClient
    ) async -> TransactionDetail? {
        switch chain {
        case .bitcoin, .litecoin:
            return await bitcoinEsplora(chain: chain, txid: txid, client: client)
        case .dogecoin:
            return await bitcoinBlockCypher(chain: chain, txid: txid, client: client)
        case .bitcoinCash:
            return await bitcoinHaskoin(chain: chain, txid: txid, client: client)
        default:
            return nil
        }
    }

    /// Esplora (BTC mempool.space, LTC litecoinspace). Detail JSON + raw
    /// hex + tip height fetched in parallel; `vsize = ceil(weight/4)`,
    /// `feeRate = fee/vsize`, `confirmations = tip - blockHeight + 1`.
    private static func bitcoinEsplora(
        chain: SupportedChain,
        txid: String,
        client: RPCClient
    ) async -> TransactionDetail? {
        async let detailData = try? client.callREST(chain: chain, path: "tx/\(txid)")
        async let hexData = try? client.callREST(chain: chain, path: "tx/\(txid)/hex")
        async let tipData = try? client.callREST(chain: chain, path: "blocks/tip/height")

        guard let data = await detailData,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let hex = (await hexData)
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let tipString = (await tipData)
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let tip = tipString.flatMap { Int64($0) }

        let size = intValue(obj["size"]) ?? 0
        let weight = intValue(obj["weight"]) ?? (size * 4)
        let vsize = weight > 0 ? Int(ceil(Double(weight) / 4.0)) : size
        let version = intValue(obj["version"]) ?? 0
        let locktime = intValue(obj["locktime"]) ?? 0
        let feeSats = int64Value(obj["fee"])

        let statusObj = obj["status"] as? [String: Any] ?? [:]
        let confirmed = statusObj["confirmed"] as? Bool ?? false
        let blockHeight = int64Value(statusObj["block_height"])
        let blockTime = int64Value(statusObj["block_time"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        var inputs: [BitcoinTxIO] = []
        for vin in obj["vin"] as? [[String: Any]] ?? [] {
            if vin["is_coinbase"] as? Bool == true {
                inputs.append(BitcoinTxIO(
                    outpoint: nil, address: nil,
                    value: int64Value((vin["prevout"] as? [String: Any])?["value"]) ?? 0,
                    scriptType: nil, isCoinbase: true
                ))
                continue
            }
            let prev = vin["prevout"] as? [String: Any] ?? [:]
            let prevTxid = vin["txid"] as? String
            let prevVout = intValue(vin["vout"])
            let outpoint = (prevTxid != nil && prevVout != nil) ? "\(prevTxid!):\(prevVout!)" : nil
            inputs.append(BitcoinTxIO(
                outpoint: outpoint,
                address: prev["scriptpubkey_address"] as? String,
                value: int64Value(prev["value"]) ?? 0,
                scriptType: prev["scriptpubkey_type"] as? String
            ))
        }

        var outputs: [BitcoinTxIO] = []
        for vout in obj["vout"] as? [[String: Any]] ?? [] {
            outputs.append(BitcoinTxIO(
                outpoint: nil,
                address: vout["scriptpubkey_address"] as? String,
                value: int64Value(vout["value"]) ?? 0,
                scriptType: vout["scriptpubkey_type"] as? String
            ))
        }

        let feeRate = bitcoinFeeRate(feeSats: feeSats, vsize: vsize)
        let confirmations = computeConfirmations(tip: tip, blockHeight: blockHeight)
        let payload = BitcoinTxDetail(
            size: size, vsize: vsize, weight: weight, version: version,
            locktime: locktime, feeRate: feeRate, feeSats: feeSats,
            inputs: inputs, outputs: outputs, hex: hex
        )
        return TransactionDetail(
            hash: txid, chain: chain,
            status: confirmed ? .confirmed : .pending,
            blockNumber: blockHeight, blockTime: blockTime,
            confirmations: confirmations,
            feeNative: feeSats.map { Decimal($0) / satsPerCoin },
            feeTicker: chain.ticker,
            explorerURL: TransactionExplorer.url(for: txid, chain: chain),
            payload: .bitcoin(payload)
        )
    }

    /// Haskoin (BCH). Single detail object + wrapped raw hex + best-block
    /// tip in parallel. BCH is non-segwit: `vsize = size`, `weight` direct.
    private static func bitcoinHaskoin(
        chain: SupportedChain,
        txid: String,
        client: RPCClient
    ) async -> TransactionDetail? {
        async let detailData = try? client.callREST(chain: chain, path: "bch/transaction/\(txid)")
        async let rawData = try? client.callREST(chain: chain, path: "bch/transaction/\(txid)/raw")
        async let tipData = try? client.callREST(chain: chain, path: "bch/block/best", query: [URLQueryItem(name: "notx", value: "true")])

        guard let data = await detailData,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let rawResult = await rawData
        let tipResult = await tipData
        let hex: String? = rawResult
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["result"] as? String
        let tip: Int64? = tipResult
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .flatMap { int64Value($0["height"]) }

        let size = intValue(obj["size"]) ?? 0
        let weight = intValue(obj["weight"]) ?? (size * 4)
        let vsize = size
        let version = intValue(obj["version"]) ?? 0
        let locktime = intValue(obj["locktime"]) ?? 0
        let feeSats = int64Value(obj["fee"])
        let blockObj = obj["block"] as? [String: Any] ?? [:]
        // Haskoin reports `block.height == -1` for an unconfirmed (mempool)
        // tx. Treat only a positive height as confirmed (finding #3, mirrors
        // the BlockCypher `> 0` guard).
        let blockHeight = int64Value(blockObj["height"]).flatMap { $0 > 0 ? $0 : nil }
        let confirmed = blockHeight != nil
        let blockTime = int64Value(obj["time"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        var inputs: [BitcoinTxIO] = []
        for input in obj["inputs"] as? [[String: Any]] ?? [] {
            if input["coinbase"] as? Bool == true {
                inputs.append(BitcoinTxIO(outpoint: nil, address: nil, value: int64Value(input["value"]) ?? 0, scriptType: nil, isCoinbase: true))
                continue
            }
            let prevTxid = input["txid"] as? String
            let prevOut = intValue(input["output"])
            let outpoint = (prevTxid != nil && prevOut != nil) ? "\(prevTxid!):\(prevOut!)" : nil
            inputs.append(BitcoinTxIO(
                outpoint: outpoint,
                address: input["address"] as? String,
                value: int64Value(input["value"]) ?? 0,
                scriptType: nil
            ))
        }
        var outputs: [BitcoinTxIO] = []
        for output in obj["outputs"] as? [[String: Any]] ?? [] {
            outputs.append(BitcoinTxIO(
                outpoint: nil,
                address: output["address"] as? String,
                value: int64Value(output["value"]) ?? 0,
                scriptType: nil
            ))
        }

        let payload = BitcoinTxDetail(
            size: size, vsize: vsize, weight: weight, version: version,
            locktime: locktime, feeRate: bitcoinFeeRate(feeSats: feeSats, vsize: vsize),
            feeSats: feeSats, inputs: inputs, outputs: outputs, hex: hex
        )
        return TransactionDetail(
            hash: txid, chain: chain,
            status: confirmed ? .confirmed : .pending,
            blockNumber: blockHeight, blockTime: blockTime,
            confirmations: computeConfirmations(tip: tip, blockHeight: blockHeight),
            feeNative: feeSats.map { Decimal($0) / satsPerCoin },
            feeTicker: chain.ticker,
            explorerURL: TransactionExplorer.url(for: txid, chain: chain),
            payload: .bitcoin(payload)
        )
    }

    /// BlockCypher (DOGE). One call returns everything incl. inline hex +
    /// inline `confirmations`. DOGE is non-segwit: `vsize = size`,
    /// `weight = size*4`. `?limit=50` so big in/out arrays aren't truncated.
    private static func bitcoinBlockCypher(
        chain: SupportedChain,
        txid: String,
        client: RPCClient
    ) async -> TransactionDetail? {
        guard let data = try? await client.callREST(
            chain: chain,
            path: "txs/\(txid)",
            query: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "includeHex", value: "true"),
            ]
        ), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let size = intValue(obj["size"]) ?? 0
        let vsize = size
        let weight = size * 4
        let version = intValue(obj["ver"]) ?? 0
        let locktime = intValue(obj["lock_time"]) ?? 0 // omitted when 0
        let feeSats = int64Value(obj["fees"])
        let blockHeight = int64Value(obj["block_height"]).flatMap { $0 > 0 ? $0 : nil }
        // BlockCypher reports `confirmations: 0` for an unconfirmed tx;
        // surface it only when positive, else `nil` (finding #13 — a stored
        // "0" reads as "zero confirmations" rather than "unknown").
        let inlineConfirmations = int64Value(obj["confirmations"])
        let confirmations = (inlineConfirmations ?? 0) > 0 ? inlineConfirmations : nil
        let confirmed = (inlineConfirmations ?? 0) > 0 || blockHeight != nil
        // The `confirmed` timestamp is RFC-3339; BlockCypher emits fractional
        // seconds (e.g. `...T12:00:00.123Z`). Try the fractional formatter
        // first, then plain ISO-8601 (finding #10).
        let blockTime = (obj["confirmed"] as? String)
            .flatMap { isoFractional.date(from: $0) ?? iso8601.date(from: $0) }
        let hex = obj["hex"] as? String

        var inputs: [BitcoinTxIO] = []
        for input in obj["inputs"] as? [[String: Any]] ?? [] {
            let prevHash = input["prev_hash"] as? String
            let outIndex = intValue(input["output_index"])
            let outpoint = (prevHash != nil && outIndex != nil) ? "\(prevHash!):\(outIndex!)" : nil
            inputs.append(BitcoinTxIO(
                outpoint: outpoint,
                address: (input["addresses"] as? [String])?.first,
                value: int64Value(input["output_value"]) ?? 0,
                scriptType: input["script_type"] as? String
            ))
        }
        var outputs: [BitcoinTxIO] = []
        for output in obj["outputs"] as? [[String: Any]] ?? [] {
            outputs.append(BitcoinTxIO(
                outpoint: nil,
                address: (output["addresses"] as? [String])?.first,
                value: int64Value(output["value"]) ?? 0,
                scriptType: output["script_type"] as? String
            ))
        }

        let payload = BitcoinTxDetail(
            size: size, vsize: vsize, weight: weight, version: version,
            locktime: locktime, feeRate: bitcoinFeeRate(feeSats: feeSats, vsize: vsize),
            feeSats: feeSats, inputs: inputs, outputs: outputs, hex: hex
        )
        return TransactionDetail(
            hash: txid, chain: chain,
            status: confirmed ? .confirmed : .pending,
            blockNumber: blockHeight, blockTime: blockTime,
            confirmations: confirmations,
            feeNative: feeSats.map { Decimal($0) / satsPerCoin },
            feeTicker: chain.ticker,
            explorerURL: TransactionExplorer.url(for: txid, chain: chain),
            payload: .bitcoin(payload)
        )
    }

    private static func bitcoinFeeRate(feeSats: Int64?, vsize: Int) -> Decimal? {
        guard let feeSats, vsize > 0 else { return nil }
        return Decimal(feeSats) / Decimal(vsize)
    }

    // MARK: - EVM family

    /// `eth_getTransactionByHash` + `eth_getTransactionReceipt` +
    /// `eth_blockNumber`, all in parallel. Fee = gasUsed ×
    /// effectiveGasPrice; confirmations = latest − blockNumber + 1; ERC-20
    /// Transfer logs decoded by topic0.
    private static func evm(
        chain: SupportedChain,
        hash: String,
        client: RPCClient
    ) async -> TransactionDetail? {
        async let txData = try? client.callJSONResultData(chain: chain, method: "eth_getTransactionByHash", params: [hash])
        async let receiptData = try? client.callJSONResultData(chain: chain, method: "eth_getTransactionReceipt", params: [hash])
        async let latestHex = try? client.callJSONString(chain: chain, method: "eth_blockNumber", params: [])

        guard let txD = await txData,
              let tx = (try? JSONSerialization.jsonObject(with: txD)) as? [String: Any] else {
            return nil
        }
        let receipt = (await receiptData)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let latest = (await latestHex).flatMap { hexToInt64($0) }

        let from = (tx["from"] as? String) ?? ""
        let to = tx["to"] as? String
        let valueWei = hexToDecimal(tx["value"] as? String) ?? .zero
        let nonce = hexToInt64(tx["nonce"] as? String) ?? 0
        let type = (tx["type"] as? String).flatMap { hexToInt64($0) }.map { Int($0) }
        let gasLimit = hexToDecimal(tx["gas"] as? String)
        let gasPrice = hexToDecimal(tx["gasPrice"] as? String)
        let maxFee = hexToDecimal(tx["maxFeePerGas"] as? String)
        let maxPriority = hexToDecimal(tx["maxPriorityFeePerGas"] as? String)
        let input = (tx["input"] as? String) ?? "0x"
        let txIndex = hexToInt64(tx["transactionIndex"] as? String)

        // Block number — prefer the receipt's (authoritative once mined),
        // else the tx's.
        let blockNumber = hexToInt64((receipt?["blockNumber"] as? String) ?? (tx["blockNumber"] as? String))

        // Status: receipt present → its `status`; receipt absent → pending.
        let status: TransactionStatus
        if let statusHex = receipt?["status"] as? String {
            status = hexToInt64(statusHex) == 0 ? .failed : .confirmed
        } else {
            status = .pending
        }

        let gasUsed = hexToDecimal(receipt?["gasUsed"] as? String)
        let cumulativeGasUsed = hexToDecimal(receipt?["cumulativeGasUsed"] as? String)
        let effectiveGasPrice = hexToDecimal(receipt?["effectiveGasPrice"] as? String)
        let contractAddress = receipt?["contractAddress"] as? String

        // Total fee = gasUsed × perGas. Post-London the authoritative
        // multiplicand is the receipt's effectiveGasPrice; some chains /
        // pre-London / archive responses omit it — fall back to the tx's
        // submitted gasPrice so the fee still resolves (finding #7).
        let perGas = effectiveGasPrice ?? gasPrice
        let totalFeeWei: Decimal? = {
            guard let gasUsed, let perGas else { return nil }
            return gasUsed * perGas
        }()

        // Decode ERC-20 Transfer logs from the receipt. Resolve each token's
        // decimals + symbol from the curated registry by (chain, contract)
        // so the view can show a human amount; unknown contracts stay raw.
        let registry = Dictionary(
            EVMTokenRegistry.tokens(for: chain).map {
                ($0.contract.lowercased(), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var transfers: [ERC20Transfer] = []
        for logEntry in receipt?["logs"] as? [[String: Any]] ?? [] {
            guard let topics = logEntry["topics"] as? [String],
                  topics.count >= 3,
                  topics[0].lowercased() == transferTopic else { continue }
            let token = (logEntry["address"] as? String) ?? ""
            let value = hexToDecimal(logEntry["data"] as? String) ?? .zero
            let entry = registry[token.lowercased()]
            transfers.append(ERC20Transfer(
                token: token,
                from: unpadTopic(topics[1]),
                to: unpadTopic(topics[2]),
                valueRaw: value,
                logIndex: hexToInt64(logEntry["logIndex"] as? String),
                decimals: entry?.decimals,
                symbol: entry?.symbol
            ))
        }

        // Timestamp: publicnode's tx.blockTimestamp when present, else nil
        // (the UI uses the stored row's occurredAt for first paint).
        let blockTime = (tx["blockTimestamp"] as? String)
            .flatMap { hexToInt64($0) }
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }

        let confirmations = computeConfirmations(tip: latest, blockHeight: blockNumber)
        let scale = Self.scale(decimals: chain.nativeDecimals)
        let payload = EVMTxDetail(
            from: from, to: to, valueWei: valueWei, nonce: nonce, type: type,
            gasLimit: gasLimit, gasUsed: gasUsed, cumulativeGasUsed: cumulativeGasUsed,
            gasPrice: gasPrice, effectiveGasPrice: effectiveGasPrice,
            maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPriority,
            totalFeeWei: totalFeeWei, transactionIndex: txIndex, input: input,
            contractAddress: contractAddress, erc20Transfers: transfers
        )
        return TransactionDetail(
            hash: hash, chain: chain, status: status,
            blockNumber: blockNumber, blockTime: blockTime,
            confirmations: confirmations,
            feeNative: totalFeeWei.map { $0 / scale },
            feeTicker: chain.ticker,
            explorerURL: TransactionExplorer.url(for: hash, chain: chain),
            payload: .evm(payload)
        )
    }

    // MARK: - Solana

    /// Single `getTransaction` (jsonParsed, maxSupportedTransactionVersion:0
    /// — MANDATORY for v0 txs). Returns slot/fee/CU/blockhash/err/
    /// instructions/logs/balance-deltas.
    private static func solana(hash: String, client: RPCClient) async -> TransactionDetail? {
        let options: [String: Sendable] = [
            "encoding": "jsonParsed",
            "maxSupportedTransactionVersion": 0,
        ]
        guard let data = try? await client.callJSONResultData(
            chain: .solana, method: "getTransaction", params: [hash, options]
        ), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let slot = int64Value(obj["slot"]) ?? 0
        let blockTime = int64Value(obj["blockTime"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let meta = obj["meta"] as? [String: Any] ?? [:]
        let feeLamports = int64Value(meta["fee"]) ?? 0
        let computeUnits = int64Value(meta["computeUnitsConsumed"])
        let err = meta["err"]
        let failed = err != nil && !(err is NSNull)
        let errString: String? = failed ? compactJSONString(err) : nil
        let logMessages = (meta["logMessages"] as? [String]) ?? []

        let transaction = obj["transaction"] as? [String: Any] ?? [:]
        let message = transaction["message"] as? [String: Any] ?? [:]
        let recentBlockhash = message["recentBlockhash"] as? String

        // Instruction summaries (parsed → human row; raw → program id).
        var instructionSummaries: [String] = []
        for ins in message["instructions"] as? [[String: Any]] ?? [] {
            instructionSummaries.append(solanaInstructionSummary(ins))
        }

        // Net balance changes: native SOL deltas (preBalances/postBalances
        // aligned to accountKeys) + SPL deltas (owner-keyed per-mint). For a
        // v0 tx the static `message.accountKeys` are followed by the address-
        // lookup-table accounts in the order `meta.loadedAddresses.writable`
        // then `.readonly` — appended here so the balance-delta indices line
        // up with real pubkeys instead of "#N" (finding #9).
        var accountKeys = solanaAccountPubkeys(message["accountKeys"])
        if let loaded = meta["loadedAddresses"] as? [String: Any] {
            accountKeys += solanaAccountPubkeys(loaded["writable"])
            accountKeys += solanaAccountPubkeys(loaded["readonly"])
        }
        let netChanges = solanaNetChanges(meta: meta, accountKeys: accountKeys)

        let payload = SolanaTxDetail(
            slot: slot, feeLamports: feeLamports, computeUnitsConsumed: computeUnits,
            recentBlockhash: recentBlockhash, errString: errString,
            instructions: instructionSummaries, logMessages: logMessages,
            netChanges: netChanges
        )
        return TransactionDetail(
            hash: hash, chain: .solana,
            status: failed ? .failed : .confirmed,
            blockNumber: slot, blockTime: blockTime,
            confirmations: nil, // Solana confirmation depth isn't a tip-delta
            feeNative: feeLamports > 0 ? Decimal(feeLamports) / lamportsPerSol : nil,
            feeTicker: "SOL",
            explorerURL: TransactionExplorer.url(for: hash, chain: .solana),
            payload: .solana(payload)
        )
    }

    private static func solanaInstructionSummary(_ ins: [String: Any]) -> String {
        if let parsed = ins["parsed"] as? [String: Any] {
            let program = (ins["program"] as? String) ?? "program"
            let type = (parsed["type"] as? String) ?? "instruction"
            if let info = parsed["info"] as? [String: Any] {
                if let lamports = int64Value(info["lamports"]) {
                    // Route through WalletFormatting so the SOL amount shares
                    // the app-wide display cap + locale (finding #14) instead
                    // of a raw `Decimal` interpolation.
                    let sol = WalletFormatting.native(Decimal(lamports) / lamportsPerSol, decimals: 9)
                    return "\(program).\(type) — \(sol) SOL"
                }
                if let tokenAmount = info["tokenAmount"] as? [String: Any],
                   let ui = tokenAmount["uiAmountString"] as? String {
                    return "\(program).\(type) — \(ui)"
                }
                if let amount = info["amount"] as? String {
                    return "\(program).\(type) — \(amount)"
                }
            }
            return "\(program).\(type)"
        }
        let programId = (ins["programId"] as? String) ?? "unknown"
        return "Program \(shortKey(programId))"
    }

    private static func solanaAccountPubkeys(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { item in
            if let s = item as? String { return s }            // legacy form
            if let d = item as? [String: Any] { return d["pubkey"] as? String } // jsonParsed form
            return nil
        }
    }

    private static func solanaNetChanges(meta: [String: Any], accountKeys: [String]) -> [SolanaBalanceChange] {
        var changes: [SolanaBalanceChange] = []

        // Native SOL: postBalances[i] - preBalances[i].
        if let pre = (meta["preBalances"] as? [Any])?.map({ int64Value($0) ?? 0 }),
           let post = (meta["postBalances"] as? [Any])?.map({ int64Value($0) ?? 0 }),
           pre.count == post.count {
            for i in 0..<pre.count where pre[i] != post[i] {
                // Subtract in `Decimal` space — `post[i] - pre[i]` as `Int64`
                // can overflow/trap on a whale account near `Int64.max`
                // lamports (finding #8).
                let delta = (Decimal(post[i]) - Decimal(pre[i])) / lamportsPerSol
                let account = i < accountKeys.count ? accountKeys[i] : "#\(i)"
                changes.append(SolanaBalanceChange(account: account, symbol: "SOL", amount: delta))
            }
        }

        // SPL: per (owner, mint) post-minus-pre, scaled by decimals.
        let preTokens = solanaTokenBalances(meta["preTokenBalances"])
        let postTokens = solanaTokenBalances(meta["postTokenBalances"])
        var keys = Set<TokenOwnerKey>()
        preTokens.keys.forEach { keys.insert($0) }
        postTokens.keys.forEach { keys.insert($0) }
        for key in keys {
            let before = preTokens[key]
            let after = postTokens[key]
            let decimals = after?.decimals ?? before?.decimals ?? 0
            let scale = Self.scale(decimals: decimals)
            let beforeAmt = before?.raw ?? .zero
            let afterAmt = after?.raw ?? .zero
            let delta = (afterAmt - beforeAmt) / scale
            guard delta != .zero else { continue }
            changes.append(SolanaBalanceChange(
                account: key.owner,
                symbol: shortKey(key.mint),
                amount: delta
            ))
        }
        return changes
    }

    private struct TokenOwnerKey: Hashable { let owner: String; let mint: String }
    private struct TokenAmount { let raw: Decimal; let decimals: Int }

    private static func solanaTokenBalances(_ raw: Any?) -> [TokenOwnerKey: TokenAmount] {
        var out: [TokenOwnerKey: TokenAmount] = [:]
        for entry in raw as? [[String: Any]] ?? [] {
            guard let owner = entry["owner"] as? String,
                  let mint = entry["mint"] as? String,
                  let ui = entry["uiTokenAmount"] as? [String: Any],
                  let amountStr = ui["amount"] as? String,
                  let amount = Decimal(string: amountStr) else { continue }
            let decimals = intValue(ui["decimals"]) ?? 0
            let key = TokenOwnerKey(owner: owner, mint: mint)
            if let existing = out[key] {
                out[key] = TokenAmount(raw: existing.raw + amount, decimals: decimals)
            } else {
                out[key] = TokenAmount(raw: amount, decimals: decimals)
            }
        }
        return out
    }

    // MARK: - XRPL (.generic)

    private static func xrpl(hash: String, address: String?, client: RPCClient) async -> TransactionDetail? {
        let txParams: [String: Sendable] = ["transaction": hash, "binary": false]
        guard let data = try? await client.callJSONResultData(
            chain: .ripple, method: "tx",
            params: [txParams],
            validatesIDEcho: false
        ), let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        // Public rippled returns tx fields at the top level of `result`;
        // api_version:2 nests them under `tx_json`. Read both.
        let tx = (result["tx_json"] as? [String: Any]) ?? result
        let meta = (result["meta"] as? [String: Any]) ?? (result["metaData"] as? [String: Any]) ?? [:]

        let txResult = (meta["TransactionResult"] as? String) ?? "tesSUCCESS"
        let validated = result["validated"] as? Bool ?? true
        let status: TransactionStatus = validated
            ? (txResult == "tesSUCCESS" ? .confirmed : .failed)
            : .pending
        let ledgerIndex = int64Value(result["ledger_index"]) ?? int64Value(result["inLedger"])
        // Ripple epoch → Unix: +946684800.
        let blockTime = int64Value(result["date"]).map {
            Date(timeIntervalSince1970: TimeInterval($0 + 946684800))
        }
        let feeDrops = (tx["Fee"] as? String).flatMap { Decimal(string: $0) }
        let feeNative = feeDrops.map { $0 / scale(decimals: SupportedChain.ripple.nativeDecimals) }

        var fields: [DetailField] = []
        appendIf(&fields, "Type", tx["TransactionType"] as? String)
        appendIf(&fields, "From", tx["Account"] as? String)
        appendIf(&fields, "To", tx["Destination"] as? String)
        appendIf(&fields, "Result", txResult)
        if let amount = xrplAmountString(meta["delivered_amount"] ?? tx["Amount"]) {
            fields.append(DetailField("Amount", amount))
        }
        appendIf(&fields, "Sequence", int64Value(tx["Sequence"]).map(String.init))
        appendIf(&fields, "Destination tag", int64Value(tx["DestinationTag"]).map(String.init))
        appendIf(&fields, "Source tag", int64Value(tx["SourceTag"]).map(String.init))
        appendIf(&fields, "Flags", int64Value(tx["Flags"]).map(String.init))
        appendIf(&fields, "Ledger", ledgerIndex.map(String.init))
        if let feeDrops { fields.append(DetailField("Fee", "\(feeDrops) drops")) }
        appendIf(&fields, "CTID", result["ctid"] as? String)

        return TransactionDetail(
            hash: hash, chain: .ripple, status: status,
            blockNumber: ledgerIndex, blockTime: blockTime, confirmations: nil,
            feeNative: feeNative, feeTicker: "XRP",
            explorerURL: TransactionExplorer.url(for: hash, chain: .ripple),
            payload: .generic(fields)
        )
    }

    private static func xrplAmountString(_ raw: Any?) -> String? {
        if let drops = raw as? String, drops != "unavailable", let d = Decimal(string: drops) {
            return "\(d / scale(decimals: 6)) XRP"
        }
        if let issued = raw as? [String: Any],
           let value = issued["value"] as? String,
           let currency = issued["currency"] as? String {
            return "\(value) \(currency)"
        }
        return nil
    }

    // MARK: - TRON (.generic)

    /// Two POSTs: `gettransactionbyid` (the tx) + `gettransactioninfobyid`
    /// (the receipt/fee/energy) in parallel.
    private static func tron(hash: String, client: RPCClient) async -> TransactionDetail? {
        async let txData = try? client.callRESTPost(chain: .tron, path: "/wallet/gettransactionbyid", body: ["value": hash])
        async let infoData = try? client.callRESTPost(chain: .tron, path: "/wallet/gettransactioninfobyid", body: ["value": hash])

        let tx = (await txData).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let info = (await infoData).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        guard tx != nil || info != nil else { return nil }
        let tx0 = tx ?? [:]
        let info0 = info ?? [:]

        // contractRet from the tx (SUCCESS/REVERT); result from the receipt.
        let contractRet = ((tx0["ret"] as? [[String: Any]])?.first?["contractRet"] as? String)
        let receiptResult = (info0["receipt"] as? [String: Any])?["result"] as? String
        let topResult = info0["result"] as? String
        let success = (contractRet == "SUCCESS" || contractRet == nil)
            && (receiptResult == nil || receiptResult == "SUCCESS")
            && (topResult == nil)
        let blockNumber = int64Value(info0["blockNumber"])
        let blockTime = int64Value(info0["blockTimeStamp"]).map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }
        let feeSun = int64Value(info0["fee"])
        let feeNative = feeSun.map { Decimal($0) / scale(decimals: 6) }

        // Decode the first TransferContract leg's owner/to/amount.
        let firstContract = (tx0["raw_data"] as? [String: Any])?["contract"] as? [[String: Any]]
        let paramValue = (firstContract?.first?["parameter"] as? [String: Any])?["value"] as? [String: Any]

        var fields: [DetailField] = []
        appendIf(&fields, "Status", contractRet ?? receiptResult)
        if let owner = paramValue?["owner_address"] as? String {
            fields.append(DetailField("From", tronAddress(owner)))
        }
        if let to = paramValue?["to_address"] as? String {
            fields.append(DetailField("To", tronAddress(to)))
        }
        appendIf(&fields, "Amount (sun)", int64Value(paramValue?["amount"]).map(String.init))
        if let contractAddr = paramValue?["contract_address"] as? String {
            fields.append(DetailField("Contract", tronAddress(contractAddr)))
        }
        appendIf(&fields, "Block", blockNumber.map(String.init))
        if let feeSun { fields.append(DetailField("Fee (sun)", String(feeSun))) }
        if let receipt = info0["receipt"] as? [String: Any] {
            appendIf(&fields, "Energy used", int64Value(receipt["energy_usage_total"]).map(String.init))
            appendIf(&fields, "Energy fee", int64Value(receipt["energy_fee"]).map(String.init))
            appendIf(&fields, "Net usage", int64Value(receipt["net_usage"]).map(String.init))
            appendIf(&fields, "Net fee", int64Value(receipt["net_fee"]).map(String.init))
        }

        return TransactionDetail(
            hash: hash, chain: .tron,
            status: success ? .confirmed : .failed,
            blockNumber: blockNumber, blockTime: blockTime, confirmations: nil,
            feeNative: feeNative, feeTicker: "TRX",
            explorerURL: TransactionExplorer.url(for: hash, chain: .tron),
            payload: .generic(fields)
        )
    }

    // MARK: - TON (.generic)

    /// TON has NO global-hash lookup, and toncenter v2 `/getTransactions`
    /// 422s when given a `hash` filter WITHOUT the matching `lt` cursor
    /// (live-verified 2026-06-16) — and the detail caller doesn't have the
    /// `lt`. So page the account's recent transactions by `address` ALONE
    /// and match `transaction_id.hash` client-side. The `address` parameter
    /// is REQUIRED; without it we honestly cannot hydrate. The stored txHash
    /// may carry an Aperture `#out{i}` batch suffix — strip it. If the tx is
    /// not within the recent window, return `nil` honestly (the screen keeps
    /// the stored summary + explorer link).
    private static func ton(hash: String, address: String?, client: RPCClient) async -> TransactionDetail? {
        guard let address, !address.isEmpty else { return nil }
        let cleanHash = hash.components(separatedBy: "#").first ?? hash
        guard let data = try? await client.callREST(
            chain: .ton, path: "/getTransactions",
            query: [
                URLQueryItem(name: "address", value: address),
                URLQueryItem(name: "limit", value: "16"),
            ]
        ), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let txs = root["result"] as? [[String: Any]] else {
            return nil
        }
        // Match the tx whose transaction_id.hash equals our hash. No fuzzy
        // fallback — an unmatched hash means the tx is outside the window;
        // returning `nil` is honest (never hydrate from the wrong tx).
        guard let tx = txs.first(where: {
            ($0["transaction_id"] as? [String: Any])?["hash"] as? String == cleanHash
        }) else { return nil }

        let utime = int64Value(tx["utime"])
        let blockTime = utime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let feeNano = (tx["fee"] as? String).flatMap { Int64($0) } ?? int64Value(tx["fee"])
        let feeNative = feeNano.map { Decimal($0) / scale(decimals: 9) }
        let status = tonStatus(tx)

        var fields: [DetailField] = []
        if let lt = (tx["transaction_id"] as? [String: Any])?["lt"] as? String {
            fields.append(DetailField("Logical time", lt))
        }
        if let feeNano { fields.append(DetailField("Fee (nano)", String(feeNano))) }
        appendIf(&fields, "Storage fee", tonNanoString(tx["storage_fee"]))
        appendIf(&fields, "Other fee", tonNanoString(tx["other_fee"]))
        if let inMsg = tx["in_msg"] as? [String: Any] {
            appendIf(&fields, "From", inMsg["source"] as? String)
            appendIf(&fields, "In value (nano)", tonNanoString(inMsg["value"]))
            appendIf(&fields, "Comment", (inMsg["message"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        if let outMsgs = tx["out_msgs"] as? [[String: Any]], let first = outMsgs.first {
            appendIf(&fields, "To", first["destination"] as? String)
            appendIf(&fields, "Out value (nano)", tonNanoString(first["value"]))
        }

        return TransactionDetail(
            hash: hash, chain: .ton, status: status,
            blockNumber: nil, blockTime: blockTime, confirmations: nil,
            feeNative: feeNative, feeTicker: "TON",
            explorerURL: TransactionExplorer.url(for: cleanHash, chain: .ton),
            payload: .generic(fields)
        )
    }

    /// Derive a TON tx status from its execution phases when the provider
    /// exposes them. toncenter v2's `ext.transaction` may carry the phases
    /// under `description.compute_ph` / `description.action` (full-history
    /// nodes / some deployments) OR the flattened `compute` / `action`
    /// (per the v2 OpenAPI schema). A non-zero compute `exit_code` or an
    /// `action.success == false` is a FAILED tx; a bounced inbound message
    /// is also a failure signal. When NO phase field is present — the case on
    /// toncenter.com mainnet, live-verified 2026-06-16 — a transaction that
    /// landed in the account's history is a committed (`.confirmed`) tx, so
    /// that's the honest default (finding #6).
    private static func tonStatus(_ tx: [String: Any]) -> TransactionStatus {
        let description = tx["description"] as? [String: Any]
        let compute = (description?["compute_ph"] as? [String: Any])
            ?? (tx["compute"] as? [String: Any])
        let action = (description?["action"] as? [String: Any])
            ?? (tx["action"] as? [String: Any])

        if let compute, let exitCode = int64Value(compute["exit_code"]), exitCode != 0 {
            return .failed
        }
        if let action, let success = action["success"] as? Bool, success == false {
            return .failed
        }
        if let inMsg = tx["in_msg"] as? [String: Any], inMsg["bounced"] as? Bool == true {
            return .failed
        }
        return .confirmed
    }

    private static func tonNanoString(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        if let n = int64Value(raw) { return String(n) }
        return nil
    }

    // MARK: - NEAR (.generic)

    /// `EXPERIMENTAL_tx_status` (named params). `sender_account_id` is used
    /// by the RPC to route the lookup to the shard holding the tx and must
    /// name an account INVOLVED in the tx. The wallet `address` is always
    /// involved (signer for an outgoing row, receiver for an incoming one),
    /// so it's tried FIRST; on a nil result we retry with the stored
    /// `counterparty` (the other involved account). Two tries are robust for
    /// both directions and NEAR is low-volume (finding #4 — live-verified
    /// 2026-06-16 that an uninvolved hint can miss while either involved
    /// account resolves).
    private static func near(
        hash: String, address: String?, counterparty: String?, client: RPCClient
    ) async -> TransactionDetail? {
        var candidates: [String] = []
        for value in [address, counterparty] {
            guard let value, !value.isEmpty, !candidates.contains(value) else { continue }
            candidates.append(value)
        }
        guard !candidates.isEmpty else { return nil }

        var result: [String: Any]?
        for candidate in candidates {
            if let data = try? await client.callJSONResultData(
                chain: .near, method: "EXPERIMENTAL_tx_status",
                paramsObject: ["tx_hash": hash, "sender_account_id": candidate, "wait_until": "FINAL"]
            ), let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                result = parsed
                break
            }
        }
        guard let result else { return nil }
        let transaction = result["transaction"] as? [String: Any] ?? [:]
        let outcome = (result["transaction_outcome"] as? [String: Any])?["outcome"] as? [String: Any] ?? [:]
        let tokensBurnt = (outcome["tokens_burnt"] as? String).flatMap { Decimal(string: $0) }
        let feeNative = tokensBurnt.map { $0 / scale(decimals: SupportedChain.near.nativeDecimals) }

        // status: top-level result.status has SuccessValue or Failure.
        let statusObj = result["status"]
        let failed = (statusObj as? [String: Any])?["Failure"] != nil
        let finalStatus = result["final_execution_status"] as? String
        let confirmed = !failed

        var fields: [DetailField] = []
        appendIf(&fields, "Signer", transaction["signer_id"] as? String)
        appendIf(&fields, "Receiver", transaction["receiver_id"] as? String)
        appendIf(&fields, "Nonce", int64Value(transaction["nonce"]).map(String.init))
        // Transfer action deposit (yoctoNEAR) when present. Route through
        // WalletFormatting for the app-wide display cap + locale (finding #14).
        if let actions = transaction["actions"] as? [Any],
           let deposit = nearTransferDeposit(actions) {
            let near = WalletFormatting.native(deposit / scale(decimals: 24), decimals: 24)
            fields.append(DetailField("Deposit", "\(near) NEAR"))
        }
        appendIf(&fields, "Gas burnt", int64Value(outcome["gas_burnt"]).map(String.init))
        if let tokensBurnt { fields.append(DetailField("Tokens burnt (yocto)", "\(tokensBurnt)")) }
        appendIf(&fields, "Final status", finalStatus)

        return TransactionDetail(
            hash: hash, chain: .near,
            status: confirmed ? .confirmed : .failed,
            blockNumber: nil, blockTime: nil, confirmations: nil,
            feeNative: feeNative, feeTicker: "NEAR",
            explorerURL: TransactionExplorer.url(for: hash, chain: .near),
            payload: .generic(fields)
        )
    }

    private static func nearTransferDeposit(_ actions: [Any]) -> Decimal? {
        for action in actions {
            guard let dict = action as? [String: Any],
                  let transfer = dict["Transfer"] as? [String: Any],
                  let deposit = transfer["deposit"] as? String,
                  let value = Decimal(string: deposit) else { continue }
            return value
        }
        return nil
    }

    // MARK: - Aptos (.generic)

    /// Fullnode REST `GET transactions/by_hash/{hash}` (base already ends
    /// /v1, so NO leading /v1). fee = gas_used × gas_unit_price.
    private static func aptos(hash: String, client: RPCClient) async -> TransactionDetail? {
        guard let data = try? await client.callREST(chain: .aptos, path: "transactions/by_hash/\(hash)"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let gasUsed = int64Value(obj["gas_used"]) ?? 0
        let gasUnitPrice = int64Value(obj["gas_unit_price"]) ?? 0
        let feeOcta = gasUsed * gasUnitPrice
        let feeNative = feeOcta > 0 ? Decimal(feeOcta) / scale(decimals: 8) : nil
        let success = obj["success"] as? Bool ?? true
        let version = int64Value(obj["version"])
        // timestamp is MICROSECONDS.
        let blockTime = int64Value(obj["timestamp"]).map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000)
        }

        var fields: [DetailField] = []
        appendIf(&fields, "VM status", obj["vm_status"] as? String)
        appendIf(&fields, "Sender", obj["sender"] as? String)
        // `sequence_number` is a display-only string field; Aptos returns it
        // as a JSON string and it can be `UInt64.max` (18446744073709551615),
        // which overflows `Int64` and would be dropped. Read it verbatim
        // (finding #12).
        appendIf(&fields, "Sequence", aptosStringField(obj["sequence_number"]))
        appendIf(&fields, "Version", version.map(String.init))
        appendIf(&fields, "Gas used", gasUsed > 0 ? String(gasUsed) : nil)
        appendIf(&fields, "Gas unit price", gasUnitPrice > 0 ? String(gasUnitPrice) : nil)
        appendIf(&fields, "Max gas", int64Value(obj["max_gas_amount"]).map(String.init))
        if let payload = obj["payload"] as? [String: Any] {
            appendIf(&fields, "Function", payload["function"] as? String)
        }

        return TransactionDetail(
            hash: hash, chain: .aptos,
            status: success ? .confirmed : .failed,
            blockNumber: version, blockTime: blockTime, confirmations: nil,
            feeNative: feeNative, feeTicker: "APT",
            explorerURL: TransactionExplorer.url(for: hash, chain: .aptos),
            payload: .generic(fields)
        )
    }

    /// Read a JSON value verbatim as a display string WITHOUT round-tripping
    /// through `Int64` — preserves full-precision `u64` values that overflow
    /// `Int64` (e.g. Aptos `sequence_number == UInt64.max`). Aptos returns
    /// `u64` as JSON strings; an `NSNumber` is also handled for safety.
    private static func aptosStringField(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - Cosmos / Kava (.generic)

    /// Cosmos SDK gRPC-gateway `GET /cosmos/tx/v1beta1/txs/{HASH}` (hash
    /// UPPERCASE hex). code 0 = success.
    private static func cosmos(chain: SupportedChain, hash: String, client: RPCClient) async -> TransactionDetail? {
        let upper = hash.uppercased().replacingOccurrences(of: "0X", with: "")
        guard let data = try? await client.callREST(chain: chain, path: "/cosmos/tx/v1beta1/txs/\(upper)"),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let txResponse = root["tx_response"] as? [String: Any] ?? [:]
        let tx = root["tx"] as? [String: Any] ?? [:]
        let code = intValue(txResponse["code"]) ?? 0
        let height = int64Value(txResponse["height"])
        let blockTime = (txResponse["timestamp"] as? String).flatMap { isoFractional.date(from: $0) ?? iso8601.date(from: $0) }

        // fee: auth_info.fee.amount[0] (denom, amount).
        let authInfo = tx["auth_info"] as? [String: Any] ?? [:]
        let feeObj = authInfo["fee"] as? [String: Any] ?? [:]
        let feeEntry = (feeObj["amount"] as? [[String: Any]])?.first
        let feeAmount = (feeEntry?["amount"] as? String).flatMap { Decimal(string: $0) }
        let feeDenom = feeEntry?["denom"] as? String
        // Scale by the FEE DENOM's decimals, NOT chain.nativeDecimals:
        // ethermint (EVM) txs on Kava pay the fee in `akava` (18 decimals),
        // while native Cosmos txs pay in the micro-denom `ukava` (6). Using
        // the chain's 6 for an `akava` fee over-states it 1e12× — live-
        // verified 2026-06-16: 590070631410000 akava is 0.00059 KAVA, not
        // 590,070,631 KAVA (finding #2). The raw "Fee" string below keeps the
        // amount + denom verbatim regardless.
        let feeNative = feeAmount.map { $0 / scale(decimals: cosmosDenomDecimals(feeDenom)) }

        var fields: [DetailField] = []
        appendIf(&fields, "Code", String(code))
        appendIf(&fields, "Height", height.map(String.init))
        if let messages = tx["body"] as? [String: Any],
           let msgs = messages["messages"] as? [[String: Any]],
           let firstType = msgs.first?["@type"] as? String {
            fields.append(DetailField("Message", firstType))
        }
        if let memo = (tx["body"] as? [String: Any])?["memo"] as? String, !memo.isEmpty {
            fields.append(DetailField("Memo", memo))
        }
        appendIf(&fields, "Gas used", int64Value(txResponse["gas_used"]).map(String.init))
        appendIf(&fields, "Gas wanted", int64Value(txResponse["gas_wanted"]).map(String.init))
        if let feeAmount, let feeDenom { fields.append(DetailField("Fee", "\(feeAmount) \(feeDenom)")) }
        appendIf(&fields, "Gas limit", int64Value(feeObj["gas_limit"]).map(String.init))

        return TransactionDetail(
            hash: hash, chain: chain,
            status: code == 0 ? .confirmed : .failed,
            blockNumber: height, blockTime: blockTime, confirmations: nil,
            feeNative: feeNative, feeTicker: chain.ticker,
            explorerURL: TransactionExplorer.url(for: hash, chain: chain),
            payload: .generic(fields)
        )
    }

    /// Decimals for a Cosmos fee denom. The SDK convention is a single-letter
    /// SI prefix on the base denom: `a` = atto (1e-18, ethermint/EVM gas
    /// denoms like `akava`), `u` = micro (1e-6, the standard Cosmos staking
    /// denom like `ukava`), `n` = nano (1e-9), `p` = pico (1e-12). Defaults to
    /// 6 (the micro-denom Cosmos default) when the prefix isn't recognized.
    private static func cosmosDenomDecimals(_ denom: String?) -> Int {
        guard let denom, let first = denom.first else { return 6 }
        switch first {
        case "a": return 18 // atto — akava and other ethermint gas denoms
        case "p": return 12 // pico
        case "n": return 9  // nano
        case "u": return 6  // micro — ukava and standard Cosmos denoms
        default:  return 6
        }
    }

    // MARK: - Polkadot (.generic)

    /// Keyless Statescan (Subscan hard-requires a key). The stored txHash
    /// is the `{blockHeight}-{extrinsicIndex}` id; the host is not in
    /// `RPCRegistry`, so we hit it directly (same pattern as the history
    /// adapter). Accepts either the `{height}-{index}` id or the 0x hash.
    private static func polkadot(idOrHash: String) async -> TransactionDetail? {
        let base = "https://polkadot-api.statescan.io/extrinsics/"
        guard let url = URL(string: base + idOrHash) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let indexer = obj["indexer"] as? [String: Any] ?? [:]
        let blockHeight = int64Value(indexer["blockHeight"])
        let blockTime = int64Value(indexer["blockTime"]).map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }
        let isSuccess = obj["isSuccess"] as? Bool ?? true

        var fields: [DetailField] = []
        appendIf(&fields, "Pallet", obj["section"] as? String)
        appendIf(&fields, "Method", obj["method"] as? String)
        appendIf(&fields, "Signer", obj["signer"] as? String)
        appendIf(&fields, "Block", blockHeight.map(String.init))
        appendIf(&fields, "Extrinsic index", int64Value(indexer["extrinsicIndex"]).map(String.init))
        appendIf(&fields, "Events", int64Value(obj["eventsCount"]).map(String.init))
        appendIf(&fields, "Signed", (obj["isSigned"] as? Bool).map { $0 ? "Yes" : "No" })
        appendIf(&fields, "Hash", obj["hash"] as? String)

        return TransactionDetail(
            hash: idOrHash, chain: .polkadot,
            status: isSuccess ? .confirmed : .failed,
            blockNumber: blockHeight, blockTime: blockTime, confirmations: nil,
            feeNative: nil, feeTicker: "DOT", // Statescan keyless omits fee
            explorerURL: TransactionExplorer.url(for: idOrHash, chain: .polkadot),
            payload: .generic(fields)
        )
    }

    // MARK: - Stellar (.generic)

    /// Horizon `GET /transactions/{hash}` (fee/memo/sequence) +
    /// `/transactions/{hash}/operations` (amount/asset) in parallel.
    private static func stellar(hash: String, address: String?, client: RPCClient) async -> TransactionDetail? {
        async let txData = try? client.callREST(chain: .stellar, path: "/transactions/\(hash)")
        async let opsData = try? client.callREST(chain: .stellar, path: "/transactions/\(hash)/operations")

        guard let data = await txData,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let feeStroops = (obj["fee_charged"] as? String).flatMap { Int64($0) } ?? int64Value(obj["fee_charged"])
        let feeNative = feeStroops.map { Decimal($0) / scale(decimals: 7) }
        let ledger = int64Value(obj["ledger"])
        let successful = obj["successful"] as? Bool ?? true
        let blockTime = (obj["created_at"] as? String).flatMap { iso8601.date(from: $0) ?? isoFractional.date(from: $0) }

        var fields: [DetailField] = []
        appendIf(&fields, "Source", obj["source_account"] as? String)
        appendIf(&fields, "Sequence", obj["source_account_sequence"] as? String)
        appendIf(&fields, "Ledger", ledger.map(String.init))
        appendIf(&fields, "Operations", int64Value(obj["operation_count"]).map(String.init))
        let memoType = obj["memo_type"] as? String
        if let memoType, memoType != "none" {
            appendIf(&fields, "Memo (\(memoType))", obj["memo"] as? String)
        }
        if let feeStroops { fields.append(DetailField("Fee (stroops)", String(feeStroops))) }

        // Per-operation amount/asset from the operations sub-resource.
        if let d = await opsData,
           let opsRoot = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let ops = (opsRoot["_embedded"] as? [String: Any])?["records"] as? [[String: Any]],
           let first = ops.first {
            appendIf(&fields, "Operation", first["type"] as? String)
            if let amount = first["amount"] as? String {
                let asset = (first["asset_type"] as? String) == "native" ? "XLM" : (first["asset_code"] as? String ?? "asset")
                fields.append(DetailField("Op amount", "\(amount) \(asset)"))
            }
            appendIf(&fields, "Op from", first["from"] as? String)
            appendIf(&fields, "Op to", first["to"] as? String)
        }

        return TransactionDetail(
            hash: hash, chain: .stellar,
            status: successful ? .confirmed : .failed,
            blockNumber: ledger, blockTime: blockTime, confirmations: nil,
            feeNative: feeNative, feeTicker: "XLM",
            explorerURL: TransactionExplorer.url(for: hash, chain: .stellar),
            payload: .generic(fields)
        )
    }

    // MARK: - Sui (.generic)

    /// `sui_getTransactionBlock` with effects/events/balanceChanges. Net
    /// fee = computationCost + storageCost − storageRebate.
    private static func sui(hash: String, client: RPCClient) async -> TransactionDetail? {
        let options: [String: Sendable] = [
            "showInput": true, "showEffects": true,
            "showEvents": true, "showBalanceChanges": true,
        ]
        guard let data = try? await client.callJSONResultData(
            chain: .sui, method: "sui_getTransactionBlock", params: [hash, options]
        ), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let effects = obj["effects"] as? [String: Any] ?? [:]
        let statusStr = (effects["status"] as? [String: Any])?["status"] as? String
        let success = statusStr == "success"
        let timestampMs = int64Value(obj["timestampMs"])
        let blockTime = timestampMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let checkpoint = int64Value(obj["checkpoint"])

        // Net fee in MIST (9 decimals).
        let gas = effects["gasUsed"] as? [String: Any] ?? [:]
        let computation = (gas["computationCost"] as? String).flatMap { Int64($0) } ?? 0
        let storage = (gas["storageCost"] as? String).flatMap { Int64($0) } ?? 0
        let rebate = (gas["storageRebate"] as? String).flatMap { Int64($0) } ?? 0
        // A storage rebate can exceed (computation + storage) — the user gets
        // MIST back net. A negative "fee" would read as nonsense, so floor at
        // 0 (finding #11). The per-component costs/rebate are still shown raw
        // in the fields below.
        let netFeeMist = max(0, computation + storage - rebate)
        let feeNative = Decimal(netFeeMist) / scale(decimals: 9)

        var fields: [DetailField] = []
        appendIf(&fields, "Status", statusStr)
        if let error = (effects["status"] as? [String: Any])?["error"] as? String {
            fields.append(DetailField("Error", error))
        }
        let txData = (obj["transaction"] as? [String: Any])?["data"] as? [String: Any]
        appendIf(&fields, "Sender", txData?["sender"] as? String)
        appendIf(&fields, "Executed epoch", int64Value(effects["executedEpoch"]).map(String.init))
        appendIf(&fields, "Checkpoint", checkpoint.map(String.init))
        fields.append(DetailField("Computation cost", String(computation)))
        fields.append(DetailField("Storage cost", String(storage)))
        fields.append(DetailField("Storage rebate", String(rebate)))
        // First balance change amount/coin.
        if let bc = obj["balanceChanges"] as? [[String: Any]], let first = bc.first,
           let coinType = first["coinType"] as? String, let amount = first["amount"] as? String {
            let symbol = coinType == "0x2::sui::SUI" ? "SUI" : shortKey(coinType)
            fields.append(DetailField("Balance change", "\(amount) \(symbol)"))
        }

        return TransactionDetail(
            hash: hash, chain: .sui,
            status: success ? .confirmed : .failed,
            blockNumber: checkpoint, blockTime: blockTime, confirmations: nil,
            feeNative: feeNative, feeTicker: "SUI",
            explorerURL: TransactionExplorer.url(for: hash, chain: .sui),
            payload: .generic(fields)
        )
    }

    // MARK: - Shared helpers

    private static func computeConfirmations(tip: Int64?, blockHeight: Int64?) -> Int64? {
        guard let tip, let blockHeight, blockHeight > 0, tip >= blockHeight else { return nil }
        return tip - blockHeight + 1
    }

    private static func appendIf(_ fields: inout [DetailField], _ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        fields.append(DetailField(label, value))
    }

    /// 41-prefixed hex TRON address → Base58Check. Returns the input
    /// unchanged when it doesn't look like a 21-byte `41` hex string.
    private static func tronAddress(_ hex: String) -> String {
        guard hex.count == 42, hex.lowercased().hasPrefix("41"),
              let payload = hexBytes(hex) else { return hex }
        let first = SHA256.hash(data: Data(payload))
        let second = SHA256.hash(data: Data(first))
        let checksum = Array(second.prefix(4))
        return Base58.encode(Data(payload + checksum))
    }

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
            result.append(byte)
            i = next
        }
        return result
    }

    /// Last 40 hex chars of a 32-byte topic = the 20-byte EVM address.
    private static func unpadTopic(_ topic: String) -> String {
        let stripped = topic.hasPrefix("0x") ? String(topic.dropFirst(2)) : topic
        if stripped.count >= 40 { return "0x" + String(stripped.suffix(40)) }
        return topic
    }

    private static func shortKey(_ key: String) -> String {
        guard key.count > 12 else { return key }
        return String(key.prefix(6)) + "…" + String(key.suffix(4))
    }

    /// Parse a hex quantity (`"0x..."`) into `Int64`. `nil` on overflow /
    /// malformed input.
    private static func hexToInt64(_ hexString: String?) -> Int64? {
        guard let hexString else { return nil }
        let hex = hexString.hasPrefix("0x") || hexString.hasPrefix("0X")
            ? String(hexString.dropFirst(2)) : hexString
        if hex.isEmpty { return 0 }
        return Int64(hex, radix: 16)
    }

    /// Parse a hex quantity into a full-precision `Decimal` (uint256-safe).
    private static func hexToDecimal(_ hexString: String?) -> Decimal? {
        guard var hex = hexString else { return nil }
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        if hex.isEmpty { return .zero }
        var result = Decimal(0)
        let sixteen = Decimal(16)
        for ch in hex {
            guard let digit = ch.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(digit)
        }
        return result
    }

    /// `Int` from JSON `NSNumber` / numeric string.
    private static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    /// `Int64` from JSON `NSNumber` / numeric string.
    private static func int64Value(_ raw: Any?) -> Int64? {
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String { return Int64(s) }
        return nil
    }

    /// Serialize a JSON value (e.g. Solana `meta.err`) to a compact string.
    private static func compactJSONString(_ raw: Any?) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let s = raw as? String { return s }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let s = String(data: data, encoding: .utf8) else {
            return String(describing: raw)
        }
        return s
    }

    private static func scale(decimals: Int) -> Decimal {
        let clamped = max(0, min(decimals, 38))
        var result = Decimal(1)
        for _ in 0..<clamped { result *= 10 }
        return result
    }

    /// 10^8 — the Bitcoin family's sats-per-coin (BTC/LTC/BCH/DOGE all 8).
    private static let satsPerCoin: Decimal = {
        var result = Decimal(1)
        for _ in 0..<8 { result *= 10 }
        return result
    }()

    /// 10^9 — Solana lamports per SOL.
    private static let lamportsPerSol: Decimal = {
        var result = Decimal(1)
        for _ in 0..<9 { result *= 10 }
        return result
    }()

    /// ISO-8601 without fractional seconds (Stellar `created_at`,
    /// BlockCypher `confirmed`). `ISO8601DateFormatter` is documented
    /// thread-safe, so the `nonisolated(unsafe)` opt-out is sound.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    /// ISO-8601 WITH fractional seconds (Cosmos `tx_response.timestamp`).
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
