import Foundation
import OSLog

/// **Alchemy Portfolio + Transfers client (2026-06-17, user direction).**
///
/// For the EVM chains Alchemy covers (probed live: Ethereum, Arbitrum,
/// Base, Optimism, Scroll, zkSync, Polygon, BNB, Avalanche, Celo), this
/// replaces the per-chain Infura/Multicall3/`eth_getLogs` plumbing:
///
/// - **Balances** — `POST …/data/v1/<key>/assets/tokens/by-address`
///   returns the address's native coin + every ERC-20 in ONE call
///   (`tokenBalance` hex, decimals, symbol). Cached briefly per
///   `(network,address)` so a chain's native-balance read and its
///   token-balance read share a single network round-trip.
/// - **History** — `alchemy_getAssetTransfers` over the per-network RPC
///   (`https://<network>.g.alchemy.com/v2/<key>`), one call per direction
///   (sent + received), merged. `value` arrives decimal-adjusted; raw
///   contract value + decimals are used where present for exactness.
///
/// A dedicated `URLSession` (not the shared `RPCClient`, which is keyed to
/// the registry's per-chain endpoints). Typed `RPCError` so connectors map
/// failures exactly as they do for JSON-RPC. There is intentionally NO
/// fallback to the old connectors for Alchemy chains — Alchemy is the sole
/// source (user direction); a failure degrades honestly (empty/throw).
actor AlchemyService {
    static let shared = AlchemyService()

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "alchemy")
    private static let restBase = "https://api.g.alchemy.com/data/v1"

    private let session: URLSession

    /// Short cache so `fetchNativeBalance` + `fetchTokenBalances` for the
    /// same `(network,address)` collapse to ONE `tokens/by-address` call.
    private struct CachedTokens { let expires: Date; let tokens: [Token] }
    private var tokenCache: [String: CachedTokens] = [:]
    private let cacheTTL: TimeInterval = 8

    /// Prefetch entries live longer than a single-network read so the ONE
    /// batched call (warmed at refresh start) serves EVERY per-chain read in
    /// that refresh's concurrent balance scan — comfortably longer than one
    /// refresh's balance phase, but shorter than the 30 s auto-refresh
    /// interval, so a FAILED prefetch on a later refresh can't serve
    /// cross-refresh stale data (the prior entries have expired; the per-chain
    /// reads then miss and fetch individually, preserving the honest-degrade
    /// contract). Every refresh re-prefetches, overwriting these.
    static let prefetchCacheTTL: TimeInterval = 20

    /// Bounded pagination — a pathological wallet (or a misbehaving upstream)
    /// must never loop unbounded following `pageKey`.
    static let maxPages = 20

    init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 25
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Value types

    /// One row from `tokens/by-address`. Native = `contract == nil`.
    struct Token: Sendable {
        let contract: String?      // nil for the native coin
        let rawBalanceHex: String  // "0x…" raw base-unit integer
        let symbol: String?
        let name: String?
        let decimals: Int?
        var isNative: Bool { contract == nil }
    }

    /// One `getAssetTransfers` entry, normalized.
    struct Transfer: Sendable {
        let hash: String
        let uniqueId: String
        let from: String
        let to: String
        let amount: Decimal        // already divided by decimals
        let asset: String?         // symbol
        let category: String       // "external" / "erc20" / "internal" / …
        let contract: String?      // nil for native
        let blockNumber: Int64?
        let timestamp: Date?
    }

    // MARK: - Balances (tokens/by-address, cached)

    func tokens(network: String, address: String) async throws(RPCError) -> [Token] {
        let key = Secrets.alchemyAPIKey
        guard !key.isEmpty else { throw .invalidResponse("Alchemy key not configured") }

        let cacheKey = "\(network)|\(address.lowercased())"
        if let cached = tokenCache[cacheKey], cached.expires > Date() {
            return cached.tokens
        }

        guard let url = URL(string: "\(Self.restBase)/\(key)/assets/tokens/by-address") else {
            throw .invalidResponse("bad Alchemy tokens URL")
        }

        // **Pagination (B1 fix, 2026-06-18).** Follow `data.pageKey` until it's
        // absent so a wallet whose holdings span more than one page loads ALL
        // of them — the old code read page 1 and silently dropped the overflow.
        // Bounded by `maxPages` so a misbehaving upstream can't loop forever.
        var all: [Token] = []
        var pageKey: String?
        var pages = 0
        repeat {
            var body: [String: Any] = [
                "addresses": [["address": address, "networks": [network]]],
                "withMetadata": true,
                "withPrices": false,
                "includeNativeTokens": true,
                "includeErc20Tokens": true,
            ]
            if let pk = pageKey { body["pageKey"] = pk }
            let data = try await postJSON(url: url, body: body, network: network)
            do {
                all.append(contentsOf: try Self.parseTokens(data))
            } catch {
                logRawTokenBodyOnce(data)   // 2A — make the real Data-API error visible
                throw error
            }
            pageKey = Self.restPageKey(from: data)
            pages += 1
        } while pageKey != nil && pages < Self.maxPages

        tokenCache[cacheKey] = CachedTokens(expires: Date().addingTimeInterval(cacheTTL), tokens: all)
        return all
    }

    /// **ONE batched Portfolio call for many networks/addresses (Task 1 — the
    /// headline speedup, B3 fix).** The Portfolio API accepts ARRAYS of both
    /// `addresses` and per-address `networks`, so a 10-chain wallet's balances
    /// come back in ONE request instead of one POST per chain. The grouped
    /// response is written into `tokenCache`, so the per-chain
    /// `AlchemyConnector` reads that run immediately after (each calling
    /// `tokens(network:address:)`) hit the warm cache with zero extra I/O.
    ///
    /// **Honest degrade.** On any failure this returns WITHOUT warming the
    /// cache, so the per-chain reads miss and each fetches individually —
    /// exactly the pre-batch behavior. Fast path when it works, graceful
    /// fallback when it doesn't. The `ChainConnector` abstraction is untouched.
    func prefetchBalances(networks: [String], addresses: [String]) async {
        let key = Secrets.alchemyAPIKey
        guard !key.isEmpty, !networks.isEmpty, !addresses.isEmpty,
              let url = URL(string: "\(Self.restBase)/\(key)/assets/tokens/by-address") else { return }

        let addressEntries = addresses.map { ["address": $0, "networks": networks] }
        var grouped: [String: [Token]] = [:]
        var pageKey: String?
        var pages = 0
        repeat {
            var body: [String: Any] = [
                "addresses": addressEntries,
                "withMetadata": true,
                "withPrices": false,
                "includeNativeTokens": true,
                "includeErc20Tokens": true,
            ]
            if let pk = pageKey { body["pageKey"] = pk }
            guard let data = try? await postJSON(url: url, body: body, network: "batch") else {
                return  // transport failure — leave the cache cold; per-chain falls back
            }
            let pageGroups: [String: [Token]]
            do {
                pageGroups = try Self.groupBatchedRows(data)
            } catch {
                // 2A — the batched Data-API call errored (or had no `data.tokens`).
                // Log the real body once and leave the cache COLD so each
                // per-chain `tokens(...)` runs and surfaces / falls back on its
                // own, instead of poisoning all slices with `[]` (2B).
                logRawTokenBodyOnce(data)
                return
            }
            for (k, v) in pageGroups {
                grouped[k, default: []].append(contentsOf: v)
            }
            pageKey = Self.restPageKey(from: data)
            pages += 1
        } while pageKey != nil && pages < Self.maxPages

        // **BUG 2B fix.** Warm the cache ONLY for slices the verified-good
        // batched response actually returned. The old code cached `[]` for
        // EVERY requested (network,address) via `grouped[ck] ?? []` — so any
        // failed/empty batch poisoned all 10 chains with an empty cache, and the
        // per-chain `tokens(...)` then returned that `[]` before making a call →
        // uniform "native row absent" with no retry. An absent slice is now left
        // cold so its per-chain read runs. A chain the wallet truly holds
        // nothing on still appears here (Alchemy returns its native `0x0` row),
        // so it is legitimately cached.
        let expires = Date().addingTimeInterval(Self.prefetchCacheTTL)
        for (ck, tokens) in grouped {
            tokenCache[ck] = CachedTokens(expires: expires, tokens: tokens)
        }
    }

    /// **BUG 2A — one-shot raw-body log.** Prints the raw `tokens/by-address`
    /// response (first 2 KB) ONCE per process so the real Data-API shape / error
    /// is visible in Xcode, without spamming it 10× (once per chain).
    private var didLogRawTokenBody = false
    private func logRawTokenBodyOnce(_ data: Data) {
        guard !didLogRawTokenBody else { return }
        didLogRawTokenBody = true
        let body = String(data: data.prefix(2000), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        Self.log.error("tokens/by-address raw body (first 2KB): \(body, privacy: .public)")
    }

    /// **BUG 2D — native-only `eth_getBalance` fallback.** Reads the native coin
    /// balance (raw wei) via Alchemy's per-network JSON-RPC product — the SAME
    /// endpoint `getAssetTransfers` uses (confirmed working) — so a Portfolio
    /// Data-API outage degrades gracefully to real native balances instead of
    /// wiping them. The caller divides by 10^decimals. A genuinely-unfunded
    /// address returns 0 (an honest zero).
    func nativeBalanceWei(network: String, address: String) async throws(RPCError) -> Decimal {
        let key = Secrets.alchemyAPIKey
        guard !key.isEmpty else { throw .invalidResponse("Alchemy key not configured") }
        guard let url = URL(string: "https://\(network).g.alchemy.com/v2/\(key)") else {
            throw .invalidResponse("bad Alchemy RPC URL")
        }
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "eth_getBalance",
            "params": [address, "latest"],
        ]
        let data = try await postJSON(url: url, body: body, network: network)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .invalidResponse("unparseable eth_getBalance body")
        }
        if let err = root["error"] as? [String: Any] {
            if (err["code"] as? Int) == 429 { throw .rateLimited(retryAfter: Date().addingTimeInterval(2)) }
            throw .invalidResponse("eth_getBalance error: \((err["message"] as? String) ?? "unknown")")
        }
        guard let hex = root["result"] as? String, let wei = Self.decimalFromHex(hex) else {
            throw .invalidResponse("eth_getBalance: no result for \(network)")
        }
        return wei
    }

    /// Map one `tokens/by-address` row to a `Token`. Shared by the
    /// single-network parse and the batched group so both parse identically.
    /// Native coin = `tokenAddress: null` → `contract == nil`.
    static func tokenFromRow(_ row: [String: Any]) -> Token? {
        guard let rawHex = row["tokenBalance"] as? String else { return nil }
        // **BUG 2C.** Native = JSON `null`, OR a native-sentinel address some
        // providers return instead of null (`0x0…0` / `0xeee…eee`). Treat both
        // as native so `isNative` (contract == nil) is true and the native row
        // is never mis-parsed as a normal token (which would make
        // `fetchNativeBalance` report "native row absent" on a funded wallet).
        let rawContract = row["tokenAddress"] as? String
        let contract: String? = {
            guard let c = rawContract, !isNativeSentinel(c) else { return nil }
            return c
        }()
        let meta = row["tokenMetadata"] as? [String: Any]
        return Token(
            contract: contract,
            rawBalanceHex: rawHex,
            symbol: meta?["symbol"] as? String,
            name: meta?["name"] as? String,
            decimals: meta?["decimals"] as? Int
        )
    }

    private static func isNativeSentinel(_ address: String) -> Bool {
        let a = address.lowercased()
        return a == "0x0000000000000000000000000000000000000000"
            || a == "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    }

    /// **BUG 2A — mirror the transfers "H1" behavior on the Data API path.**
    /// Detects an Alchemy `tokens/by-address` error envelope (returned at HTTP
    /// 200) so a not-enabled product / auth error / shape change throws the REAL
    /// message instead of collapsing into a bare "native row absent". Returns
    /// `nil` when the body is a normal success.
    private static func tokenResponseError(_ root: [String: Any]) -> RPCError? {
        if let err = root["error"] as? [String: Any] {
            if (err["code"] as? Int) == 429 { return .rateLimited(retryAfter: Date().addingTimeInterval(2)) }
            return .invalidResponse("tokens/by-address error: \((err["message"] as? String) ?? "unknown")")
        }
        if let errString = root["error"] as? String {
            return .invalidResponse("tokens/by-address error: \(errString)")
        }
        // Some error shapes carry a top-level message with no `data` object.
        if root["data"] == nil, let message = root["message"] as? String {
            return .invalidResponse("tokens/by-address: \(message)")
        }
        return nil
    }

    /// Parse the single-network `tokens/by-address` response. THROWS the real
    /// error (2A) instead of returning `[]` on an error envelope or a missing
    /// `data.tokens` — the caller logs the raw body once and surfaces it.
    static func parseTokens(_ data: Data) throws(RPCError) -> [Token] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .invalidResponse("unparseable tokens/by-address body")
        }
        if let err = tokenResponseError(root) { throw err }
        guard let dataObj = root["data"] as? [String: Any],
              let rows = dataObj["tokens"] as? [[String: Any]] else {
            throw .invalidResponse("tokens/by-address: response had no `data.tokens`")
        }
        return rows.compactMap(tokenFromRow)
    }

    /// Group a batched response's rows by `"network|address"` (address
    /// lowercased — the `tokenCache` key shape). THROWS the real error (2A) on
    /// an error envelope / missing `data.tokens` so `prefetchBalances` can leave
    /// the cache cold rather than poison every slice with `[]`.
    static func groupBatchedRows(_ data: Data) throws(RPCError) -> [String: [Token]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .invalidResponse("unparseable tokens/by-address body")
        }
        if let err = tokenResponseError(root) { throw err }
        guard let dataObj = root["data"] as? [String: Any],
              let rows = dataObj["tokens"] as? [[String: Any]] else {
            throw .invalidResponse("tokens/by-address: response had no `data.tokens`")
        }
        var grouped: [String: [Token]] = [:]
        for row in rows {
            guard let net = row["network"] as? String,
                  let addr = row["address"] as? String,
                  let token = tokenFromRow(row) else { continue }
            grouped["\(net)|\(addr.lowercased())", default: []].append(token)
        }
        return grouped
    }

    /// The REST continuation key (`data.pageKey`), or `nil` when absent/empty
    /// (no more pages remain).
    static func restPageKey(from data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let pk = dataObj["pageKey"] as? String, !pk.isEmpty else { return nil }
        return pk
    }

    // MARK: - History (getAssetTransfers, sent + received)

    /// Alchemy supports the `internal` transfer category ONLY on Ethereum and
    /// Polygon (BUG 1) — single source of truth for that constraint.
    static func supportsInternalCategory(_ network: String) -> Bool {
        network == "eth-mainnet" || network == "polygon-mainnet"
    }

    func assetTransfers(chain: SupportedChain, network: String, address: String, maxCount: Int) async throws(RPCError) -> [Transfer] {
        let key = Secrets.alchemyAPIKey
        guard !key.isEmpty else { throw .invalidResponse("Alchemy key not configured") }
        guard let url = URL(string: "https://\(network).g.alchemy.com/v2/\(key)") else {
            throw .invalidResponse("bad Alchemy RPC URL")
        }
        let cap = "0x" + String(max(1, min(maxCount, 1000)), radix: 16)

        // Two directions in parallel — sent (fromAddress) + received (toAddress).
        async let sent = transfers(url: url, network: network, addressKey: "fromAddress", address: address, cap: cap)
        async let received = transfers(url: url, network: network, addressKey: "toAddress", address: address, cap: cap)

        // Either direction may legitimately be empty; only a double transport
        // failure is a real error. Thread the REAL chain into the error so the
        // log names the chain that actually failed (was hard-coded `.ethereum`,
        // which is why Celo logged `…SupportedChain.ethereum`).
        let sentResult = try? await sent
        let recvResult = try? await received
        guard sentResult != nil || recvResult != nil else {
            throw .allEndpointsFailed(chain)
        }
        var merged: [String: Transfer] = [:]
        for t in (sentResult ?? []) + (recvResult ?? []) { merged[t.uniqueId] = t }
        return merged.values.sorted {
            ($0.blockNumber ?? 0) > ($1.blockNumber ?? 0)
        }
    }

    private func transfers(
        url: URL, network: String, addressKey: String, address: String, cap: String
    ) async throws(RPCError) -> [Transfer] {
        // **BUG 1 fix (2026-06-18).** Alchemy supports the `internal` transfer
        // category ONLY on Ethereum and Polygon; including it on any other
        // Alchemy chain makes `alchemy_getAssetTransfers` reject the WHOLE
        // request with `-32602` ("The 'internal' category is only supported for
        // ETH and MATIC."), which `parseTransfers` correctly throws on — so
        // BOTH directions failed and history broke on the other 8 EVM chains.
        // `internal` = contract-initiated native moves (exchange withdrawals,
        // bridge payouts, DEX native-out), which only matter on ETH/Polygon
        // anyway. NFTs (`erc721`/`erc1155`) stay excluded — fungibles view only.
        let categories: [String] = Self.supportsInternalCategory(network)
            ? ["external", "internal", "erc20"]
            : ["external", "erc20"]
        let params: [String: Any] = [
            addressKey: address,
            "category": categories,
            "maxCount": cap,
            "order": "desc",
            "withMetadata": true,
            "excludeZeroValue": true,
        ]
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "alchemy_getAssetTransfers", "params": [params]]
        let data = try await postJSON(url: url, body: body, network: network)
        return try Self.parseTransfers(data)
    }

    static func parseTransfers(_ data: Data) throws(RPCError) -> [Transfer] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .invalidResponse("unparseable getAssetTransfers body")
        }
        // **H1 fix — JSON-RPC errors arrive at HTTP 200 with an `error` object.**
        // The old parser keyed off `result` only, so an error body silently
        // returned `[]` and surfaced as "no transactions" with zero signal.
        // Detect it and THROW so the coordinator can tell "errored" from
        // "no history" (and so a real error isn't buried as an empty list).
        if let err = root["error"] as? [String: Any] {
            if (err["code"] as? Int) == 429 {
                throw .rateLimited(retryAfter: Date().addingTimeInterval(2))
            }
            throw .invalidResponse("getAssetTransfers error: \((err["message"] as? String) ?? "unknown")")
        }
        guard let result = root["result"] as? [String: Any],
              let rows = result["transfers"] as? [[String: Any]] else { return [] }
        var out: [Transfer] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let hash = row["hash"] as? String,
                  let from = row["from"] as? String else { continue }
            let to = (row["to"] as? String) ?? ""
            let category = (row["category"] as? String) ?? "external"
            let raw = row["rawContract"] as? [String: Any]
            let contract = raw?["address"] as? String   // null for native
            // Prefer the EXACT raw value / decimals. Fall back to the
            // already-adjusted `value` number ONLY via `NSNumber.decimalValue`
            // — never `Decimal(Double)` (H3: money never routes through Double).
            // JSONSerialization yields every JSON number as `NSNumber`, so this
            // single branch covers what the old Double + NSNumber branches did.
            var amount = Decimal(0)
            if let rawValueHex = raw?["value"] as? String,
               let rawDecHex = raw?["decimal"] as? String,
               let rawValue = decimalFromHex(rawValueHex),
               let dec = Int((rawDecHex.hasPrefix("0x") ? String(rawDecHex.dropFirst(2)) : rawDecHex), radix: 16) {
                amount = rawValue / pow10(dec)
            } else if let v = row["value"] as? NSNumber {
                amount = v.decimalValue
            }
            let blockNum = (row["blockNum"] as? String).flatMap {
                Int64(($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0), radix: 16)
            }
            let ts = ((row["metadata"] as? [String: Any])?["blockTimestamp"] as? String).flatMap(parseISODate)
            out.append(Transfer(
                hash: hash,
                uniqueId: (row["uniqueId"] as? String) ?? hash,
                from: from, to: to,
                amount: amount,
                asset: row["asset"] as? String,
                category: category,
                contract: contract,
                blockNumber: blockNum,
                timestamp: ts
            ))
        }
        return out
    }

    // MARK: - HTTP

    private func postJSON(url: URL, body: [String: Any], network: String) async throws(RPCError) -> Data {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw .invalidResponse("failed to encode Alchemy request")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: Date().addingTimeInterval(2))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw .invalidResponse("Alchemy HTTP \(http.statusCode) on \(network)")
            }
        }
        return data
    }

    // MARK: - Hex / decimal helpers

    static func decimalFromHex(_ hexString: String) -> Decimal? {
        var hex = hexString
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        if hex.isEmpty { return .zero }
        // **B5 guard.** `Decimal`'s mantissa is 128-bit, so it represents
        // integers exactly only up to 2^128-1 = 32 hex chars. Beyond that it
        // does NOT overflow to NaN — it silently TRUNCATES to ~38 significant
        // digits (e.g. a uint256 came back as `…907828000…0`), a corrupt amount
        // that would render a wrong balance. Reject anything wider than 128 bits
        // up front so the caller drops the row instead (no real token balance
        // needs >2^128 base units; spam contracts that report uint256 max are
        // dropped here as defense-in-depth on top of the registry filter). The
        // `isNaN` check stays as belt-and-suspenders.
        guard hex.count <= 32 else { return nil }
        var result = Decimal(0)
        let sixteen = Decimal(16)
        for char in hex {
            guard let digit = char.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(digit)
        }
        return result.isNaN ? nil : result
    }

    static func pow10(_ n: Int) -> Decimal {
        let clamped = min(max(n, 0), 38)
        var r = Decimal(1)
        for _ in 0..<clamped { r *= 10 }
        return r
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseISODate(_ s: String) -> Date? {
        isoFormatter.date(from: s) ?? isoFormatterNoFrac.date(from: s)
    }
}
