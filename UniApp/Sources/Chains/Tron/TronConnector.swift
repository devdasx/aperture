import CryptoKit
import Foundation
import OSLog

/// **Tron connector — a fully independent module for `.tron`.**
///
/// Owns Tron's three request shapes end-to-end and dispatches every
/// call through the shared `RPCClient` actor (rotation + rate-limit +
/// circuit-breaking + ConcurrencyGate) against the registered endpoints
/// `RPCRegistry.endpoints(for: .tron)` (TronGrid primary, publicnode
/// fallback). Never a raw `URLSession`.
///
/// Tron is NOT EVM and NOT a JSON-RPC chain like the EVM siblings: it
/// speaks TronGrid's HTTP REST API. Three distinct upstream shapes, all
/// REST, all owned here:
///
/// 1. **Native balance** — `GET /v1/accounts/{addr}`; `data[0].balance`
///    is an unsigned int in SUN (1 TRX = 10^6 SUN). An empty `data[]`
///    array (HTTP 200) OR a 404 = the account is unfunded / not yet
///    on-chain = the normal zero-balance state, not an error.
/// 2. **TRC-20 balances** — `POST /wallet/triggerconstantcontract` with
///    the `balanceOf(address)` selector and a 32-byte left-padded holder
///    address; the read-only result lands in `constant_result[0]` as a
///    32-byte hex word. Per registry token, in parallel.
/// 3. **History** — `GET /v1/accounts/{addr}/transactions` (native
///    `TransferContract`) and `…/transactions/trc20` (TRC-20 transfers),
///    both paged by the opaque `meta.fingerprint` cursor.
///
/// **Ported verbatim-faithful** from `TRONChainAdapter.fetchAccountSummary`
/// (balance), `RealRPCBalanceScanner.fetchTronTokenBalance` +
/// `tronAddressToEVMHex` (token balances), and `TronTransactionAdapter`
/// (history): same endpoints, same SUN/10^6 native math, same hex-`41`→
/// Base58Check address conversion for native-history direction
/// classification, same `fingerprint` pagination contract, same
/// curated-registry-keyed-by-contract symbol/decimals (self-declared
/// `token_info.symbol` is NOT trusted — scam airdrops name themselves
/// "USDT"), same millisecond timestamps, same 404=unfunded handling.
struct TronConnector: ChainConnector {
    let chain: SupportedChain = .tron
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "tron-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native TRX balance + used-address flag via TronGrid's
    /// `GET /v1/accounts/{addr}`. Ported from
    /// `TRONChainAdapter.fetchAccountSummary`.
    ///
    /// `data[0].balance` is an unsigned int in SUN → divided by 10^6.
    /// Defensive numeric decode: `JSONSerialization` may surface the
    /// value as `NSDecimalNumber` (very large), `NSNumber`, `Int`, or a
    /// `String` — each shape is tried rather than assuming one cast. An
    /// empty `data[]` (a not-yet-on-chain account, HTTP 200) and an HTTP
    /// 404 both map to a zero summary — the normal unfunded state, never
    /// a throw.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data: Data
        do {
            data = try await client.callREST(chain: chain, path: "v1/accounts/\(address)")
        } catch {
            // Cancellation propagates verbatim; a 404 for an unfunded
            // account (or a fallback that can't serve the v1 path) is the
            // normal "0 balance" state, not a failure.
            if case .cancelled = error { throw error }
            if RPCError.isHTTPNotFound(error) {
                Self.log.debug("TRON account \(address, privacy: .private) unfunded (404) — treating as 0 balance")
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            throw error
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]],
              let first = arr.first else {
            // `{"data":[],...}` for a not-yet-active account → zero.
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        let sun: Decimal
        if let n = first["balance"] as? NSDecimalNumber {
            sun = n.decimalValue
        } else if let n = first["balance"] as? NSNumber {
            sun = NSDecimalNumber(value: n.int64Value).decimalValue
        } else if let i = first["balance"] as? Int {
            sun = Decimal(i)
        } else if let s = first["balance"] as? String, let dec = Decimal(string: s) {
            sun = dec
        } else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        let trx = sun / Self.sunPerTrx
        return ChainAccountSummary(nativeBalance: trx, isUsed: trx > 0)
    }

    // MARK: - Token balances

    /// TRC-20 token balances via TronGrid's
    /// `POST /wallet/triggerconstantcontract` `balanceOf(address)` read,
    /// one call per curated registry token (+ any `customContracts`),
    /// fanned out in parallel. Ported from
    /// `RealRPCBalanceScanner.fetchTronTokenBalance`.
    ///
    /// Non-throwing per the `ChainConnector` contract: a transport-level
    /// failure on a token degrades to "no row" rather than a fabricated
    /// zero — pricing/persistence stays in the coordinator. Returns ONLY
    /// positive-balance rows (Rule #2 §A.7). `fiatBalance: nil` and
    /// `fiatCurrencyCode: ""` — the coordinator prices rows downstream.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        // Registry tokens first, then user custom contracts (deduped
        // against the registry by exact contract — TRON addresses are
        // case-sensitive base58check, so no lowercasing).
        var specs: [TokenSpec] = TronTokenRegistry.tokens.map {
            TokenSpec(contract: $0.contract, symbol: $0.symbol, name: $0.name, decimals: $0.decimals)
        }
        let known = Set(TronTokenRegistry.tokens.map { $0.contract })
        for contract in customContracts where !known.contains(contract) {
            // Custom contracts ship without registry metadata; the
            // coordinator's custom-token pass owns symbol/name/decimals.
            // The connector still reads their balance so a user-added
            // token surfaces. Decimals default to 6 (TRC-20 stablecoin
            // norm) — re-derived downstream if needed.
            specs.append(TokenSpec(contract: contract, symbol: Self.shortContract(contract), name: contract, decimals: 6))
        }
        guard !specs.isEmpty else { return [] }

        let now = Date()
        // Each `balanceOf` is an independent read; fan out so one slow
        // token doesn't serialize the rest (the RPCClient's rate limiter
        // + ConcurrencyGate still throttle the burst per endpoint).
        let rows = await withTaskGroup(of: TokenBalance?.self) { group -> [TokenBalance] in
            for spec in specs {
                group.addTask {
                    let raw = await Self.fetchTRC20Balance(holder: address, contract: spec.contract, client: self.client) ?? 0
                    let amount = raw / Self.pow10(spec.decimals)
                    guard amount > 0 else { return nil }
                    return TokenBalance(
                        chain: self.chain,
                        address: address,
                        contract: spec.contract,
                        symbol: spec.symbol,
                        name: spec.name,
                        decimals: spec.decimals,
                        amount: amount,
                        fiatBalance: nil,           // pricing stays in the coordinator
                        fiatCurrencyCode: "",       // coordinator stamps the active currency
                        lastUpdated: now
                    )
                }
            }
            var collected: [TokenBalance] = []
            for await row in group { if let row { collected.append(row) } }
            return collected
        }
        return rows
    }

    /// One discovered token's metadata + contract — the connector's
    /// internal work item before a balance lands.
    private struct TokenSpec: Sendable {
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    /// `POST /wallet/triggerconstantcontract` `balanceOf(address)` read.
    /// Ported verbatim from `RealRPCBalanceScanner.fetchTronTokenBalance`:
    /// selector `balanceOf(address)`, 32-byte left-padded holder, result
    /// in `constant_result[0]`. Returns `nil` (not 0) on any transport /
    /// decode failure so the caller drops the row rather than showing a
    /// fabricated zero.
    private static func fetchTRC20Balance(
        holder: String,
        contract: String,
        client: RPCClient
    ) async -> Decimal? {
        let holderHex = tronAddressToEVMHex(holder)
        guard !holderHex.isEmpty else { return nil }
        let paddedHolder = String(repeating: "0", count: 24) + holderHex
        let body: [String: Sendable] = [
            "owner_address":     holder,
            "contract_address":  contract,
            "function_selector": "balanceOf(address)",
            "parameter":         paddedHolder,
            "visible":           true,
        ]
        guard let data = try? await client.callRESTPost(
            chain: .tron,
            path: "wallet/triggerconstantcontract",
            body: body
        ),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["constant_result"] as? [String],
              let hex = results.first else {
            return nil
        }
        return decimalFromHex(hex)
    }

    // MARK: - Transaction history

    /// TronGrid's per-page maximum.
    private static let pageSize = 200

    /// Recent Tron history: native TRX `TransferContract` rows from
    /// `/v1/accounts/{addr}/transactions` and TRC-20 transfer rows from
    /// `…/transactions/trc20`, merged newest-first and capped at `limit`.
    /// Ported from `TronTransactionAdapter.fetch`.
    ///
    /// The two streams fan out in parallel; each pages SEQUENTIALLY
    /// through its own opaque `meta.fingerprint` cursor. `try?` on each
    /// await so one failing endpoint doesn't cancel the other (a
    /// `RPCError.cancelled` mid-page aborts that stream's paging loop;
    /// `try Task.checkCancellation()` after the joins re-surfaces a
    /// cancelled scan instead of a deceptively-empty history).
    /// `customContracts` extends the TRC-20 known-contract gate; native
    /// TRX history is unaffected.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        async let nativeRaw = fetchNativeHistory(address: address, limit: limit)
        async let trc20Raw = fetchTRC20History(address: address, limit: limit, customContracts: customContracts)
        let native = (try? await nativeRaw) ?? []
        let trc20 = (try? await trc20Raw) ?? []
        try Task.checkCancellation()
        return (native + trc20)
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Native TRX `TransferContract` history. Pages the opaque
    /// `meta.fingerprint` cursor (absent when history is exhausted) until
    /// `limit`, an empty page, no fingerprint, or a mid-page failure
    /// (keeps pages already fetched; `RPCError.cancelled` propagates).
    /// Ported from `TronTransactionAdapter.fetchNative`.
    private func fetchNativeHistory(address: String, limit: Int) async throws -> [TransactionEvent] {
        let path = "/v1/accounts/\(address)/transactions"
        let size = min(limit, Self.pageSize)
        var events: [TransactionEvent] = []
        var fingerprint: String?
        while events.count < limit {
            var query: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(size)),
                URLQueryItem(name: "only_confirmed", value: "true"),
            ]
            if let fingerprint {
                query.append(URLQueryItem(name: "fingerprint", value: fingerprint))
            }
            let data: Data
            do {
                data = try await client.callREST(chain: chain, path: path, query: query)
            } catch {
                if case .cancelled = error { throw error }
                if fingerprint == nil { throw error }
                Self.log.warning("TronGrid native page failed — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let txs = root["data"] as? [[String: Any]] else {
                break
            }
            if txs.isEmpty { break }
            appendNativeEvents(from: txs, address: address, limit: limit, into: &events)
            let meta = root["meta"] as? [String: Any]
            guard let next = meta?["fingerprint"] as? String, next != fingerprint else { break }
            fingerprint = next
            if events.count >= limit {
                Self.log.info("TronGrid native history hit the \(limit, privacy: .public)-event cap")
            }
        }
        return events
    }

    /// Parse one TronGrid native page → `TransactionEvent` rows. Ported
    /// from `TronTransactionAdapter.appendNativeEvents`. Only
    /// `TransferContract`-type contracts are kept (TRC-20 comes from the
    /// sibling endpoint; everything else is feed noise).
    private func appendNativeEvents(
        from txs: [[String: Any]],
        address: String,
        limit: Int,
        into events: inout [TransactionEvent]
    ) {
        events.reserveCapacity(min(events.count + txs.count, limit))
        for tx in txs {
            if events.count >= limit { break }
            guard let txID = tx["txID"] as? String,
                  let rawData = tx["raw_data"] as? [String: Any],
                  let contracts = rawData["contract"] as? [[String: Any]],
                  let firstContract = contracts.first,
                  let parameter = firstContract["parameter"] as? [String: Any],
                  let value = parameter["value"] as? [String: Any] else {
                continue
            }
            let contractType = (firstContract["type"] as? String) ?? ""
            guard contractType == "TransferContract" else { continue }
            let from = Self.hexAddressToTron(value["owner_address"] as? String ?? "")
            let to = Self.hexAddressToTron(value["to_address"] as? String ?? "")
            let amountSun = (value["amount"] as? Int64) ?? 0
            let amount = Decimal(amountSun) / Self.sunPerTrx

            let direction: TransactionDirection
            let counterparty: String
            if from == address && to == address {
                direction = .internal
                counterparty = ""
            } else if from == address {
                direction = .outgoing
                counterparty = to
            } else if to == address {
                direction = .incoming
                counterparty = from
            } else {
                continue
            }

            let timestamp = (rawData["timestamp"] as? Int64) ?? ((tx["block_timestamp"] as? Int64) ?? 0)
            // Tron timestamps are milliseconds since epoch.
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
            let blockNumber = (tx["blockNumber"] as? Int64)
            let ret = tx["ret"] as? [[String: Any]] ?? []
            let txStatus = (ret.first?["contractRet"] as? String) ?? "SUCCESS"
            let status: TransactionStatus = txStatus == "SUCCESS" ? .confirmed : .failed

            events.append(TransactionEvent(
                chain: chain,
                address: address,
                txHash: txID,
                direction: direction,
                amount: amount,
                tokenSymbol: "TRX",
                tokenContract: nil,
                blockNumber: blockNumber,
                occurredAt: occurredAt,
                status: status,
                counterparty: counterparty,
                fee: nil
            ))
        }
    }

    /// TRC-20 transfer history. Same `fingerprint` pagination contract as
    /// `fetchNativeHistory`. Ported from `TronTransactionAdapter.fetchTRC20`.
    /// `customContracts` extends the curated registry for the
    /// known-contract gate (un-tracked contracts still surface under the
    /// neutral "TRC20" label, mirroring the existing adapter — the
    /// coordinator owns spam suppression).
    private func fetchTRC20History(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let path = "/v1/accounts/\(address)/transactions/trc20"
        let size = min(limit, Self.pageSize)
        var events: [TransactionEvent] = []
        var fingerprint: String?
        while events.count < limit {
            var query: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(size)),
                URLQueryItem(name: "only_confirmed", value: "true"),
            ]
            if let fingerprint {
                query.append(URLQueryItem(name: "fingerprint", value: fingerprint))
            }
            let data: Data
            do {
                data = try await client.callREST(chain: chain, path: path, query: query)
            } catch {
                if case .cancelled = error { throw error }
                if fingerprint == nil { throw error }
                Self.log.warning("TronGrid TRC-20 page failed — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let txs = root["data"] as? [[String: Any]] else {
                break
            }
            if txs.isEmpty { break }
            appendTRC20Events(from: txs, address: address, limit: limit, into: &events)
            let meta = root["meta"] as? [String: Any]
            guard let next = meta?["fingerprint"] as? String, next != fingerprint else { break }
            fingerprint = next
            if events.count >= limit {
                Self.log.info("TronGrid TRC-20 history hit the \(limit, privacy: .public)-event cap")
            }
        }
        return events
    }

    /// Parse one TronGrid TRC-20 page → `TransactionEvent` rows. Ported
    /// from `TronTransactionAdapter.appendTRC20Events`. The display
    /// symbol/decimals come from the curated registry keyed by CONTRACT
    /// ADDRESS — `token_info.symbol` is self-declared by the contract and
    /// scam airdrops routinely name themselves "USDT"; unknown contracts
    /// get the neutral "TRC20" label. `from`/`to` arrive already in
    /// Base58Check (TronGrid's TRC-20 endpoint emits visible addresses).
    private func appendTRC20Events(
        from txs: [[String: Any]],
        address: String,
        limit: Int,
        into events: inout [TransactionEvent]
    ) {
        for tx in txs {
            if events.count >= limit { break }
            guard let txID = tx["transaction_id"] as? String,
                  let from = tx["from"] as? String,
                  let to = tx["to"] as? String,
                  let valueStr = tx["value"] as? String,
                  let tokenInfo = tx["token_info"] as? [String: Any] else {
                continue
            }
            let contract = tokenInfo["address"] as? String
            let registryEntry = contract.flatMap { c in
                TronTokenRegistry.tokens.first { $0.contract == c }
            }
            let symbol = registryEntry?.symbol ?? "TRC20"
            let decimals = registryEntry?.decimals ?? ((tokenInfo["decimals"] as? Int) ?? 0)
            let raw = Decimal(string: valueStr) ?? 0
            let amount = raw / Self.pow10(decimals)

            let direction: TransactionDirection
            let counterparty: String
            if from == address && to == address {
                direction = .internal
                counterparty = ""
            } else if from == address {
                direction = .outgoing
                counterparty = to
            } else if to == address {
                direction = .incoming
                counterparty = from
            } else {
                continue
            }
            let timestamp = (tx["block_timestamp"] as? Int64) ?? 0
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)

            events.append(TransactionEvent(
                chain: chain,
                address: address,
                txHash: txID,
                direction: direction,
                amount: amount,
                tokenSymbol: symbol,
                tokenContract: contract,
                blockNumber: nil,
                occurredAt: occurredAt,
                status: .confirmed,
                counterparty: counterparty,
                fee: nil
            ))
        }
    }

    // MARK: - Address codecs (ported verbatim)

    /// Tron raw addresses are hex with a `41` prefix; the user-facing
    /// form is Base58Check over the full 21-byte payload:
    /// `base58( payload ‖ first4( sha256( sha256( payload ) ) ) )`.
    /// The conversion must be real — native-history direction
    /// classification compares `from`/`to` against the caller's
    /// Base58Check address, so returning raw hex would drop every native
    /// TRX transaction. Ported from `TronTransactionAdapter.hexAddressToTron`
    /// (verified against TRON reference vectors). Inputs that don't look
    /// like a 21-byte `41`-prefixed hex string are returned unchanged.
    private static func hexAddressToTron(_ hex: String) -> String {
        guard hex.count == 42,
              hex.lowercased().hasPrefix("41"),
              let payload = hexBytes(hex) else {
            return hex
        }
        let firstRound = SHA256.hash(data: Data(payload))
        let secondRound = SHA256.hash(data: Data(firstRound))
        let checksum = Array(secondRound.prefix(4))
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

    /// TRON base58check → 20-byte EVM-style hex (no prefix) for
    /// `balanceOf` calldata. Decoded payload is
    /// `<0x41 prefix><20-byte body><4-byte checksum>`. Ported from
    /// `RealRPCBalanceScanner.tronAddressToEVMHex`. Returns "" on failure.
    private static func tronAddressToEVMHex(_ address: String) -> String {
        guard let bytes = Base58.decodeBytes(address), bytes.count >= 25 else {
            return ""
        }
        let body = bytes[1..<21]
        return body.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Numeric helpers (ported verbatim)

    /// Parse a hex string (with or without `0x` prefix) into a `Decimal`.
    /// Ported from `RealRPCBalanceScanner.decimalFromHex`.
    private static func decimalFromHex(_ hexString: String) -> Decimal? {
        var hex = hexString
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        if hex.isEmpty { return .zero }
        var result = Decimal(0)
        let sixteen = Decimal(16)
        for char in hex {
            guard let digit = char.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(digit)
        }
        return result
    }

    /// 10^n as `Decimal`, clamped. For unknown contracts `n` is the
    /// indexer's copy of attacker-controlled contract metadata — clamp so
    /// a negative value can't trap the range and an absurd one can't spin
    /// the loop. 38 ≈ Decimal's representable capacity. Mirrors the
    /// existing `scale(decimals:)` / `pow10(_:)` helpers.
    private static func pow10(_ n: Int) -> Decimal {
        let clamped = min(max(n, 0), 38)
        var r = Decimal(1)
        for _ in 0..<clamped { r *= 10 }
        return r
    }

    /// 10^6 — TRX's smallest unit is the SUN.
    private static let sunPerTrx: Decimal = {
        var result = Decimal(1)
        for _ in 0..<6 { result *= 10 }
        return result
    }()

    /// Short label for a custom contract with no registry metadata
    /// (`Txxxx…xxxx`). Mirrors `EthereumConnector.shortContract`.
    private static func shortContract(_ contract: String) -> String {
        guard contract.count > 10 else { return contract }
        return "\(contract.prefix(6))…\(contract.suffix(4))"
    }
}
