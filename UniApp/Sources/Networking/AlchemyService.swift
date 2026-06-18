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
            all.append(contentsOf: Self.parseTokens(data))
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
                return  // honest degrade — leave the cache cold; per-chain falls back
            }
            for (k, v) in Self.groupBatchedRows(data) {
                grouped[k, default: []].append(contentsOf: v)
            }
            pageKey = Self.restPageKey(from: data)
            pages += 1
        } while pageKey != nil && pages < Self.maxPages

        // Warm the cache for EVERY requested (network,address) — including the
        // empty slices, so a chain the wallet holds nothing on caches `[]` and
        // doesn't trigger a redundant individual fetch this refresh.
        let expires = Date().addingTimeInterval(Self.prefetchCacheTTL)
        for net in networks {
            for addr in addresses {
                let ck = "\(net)|\(addr.lowercased())"
                tokenCache[ck] = CachedTokens(expires: expires, tokens: grouped[ck] ?? [])
            }
        }
    }

    /// Map one `tokens/by-address` row to a `Token`. Shared by the
    /// single-network parse and the batched group so both parse identically.
    /// Native coin = `tokenAddress: null` → `contract == nil`.
    static func tokenFromRow(_ row: [String: Any]) -> Token? {
        guard let rawHex = row["tokenBalance"] as? String else { return nil }
        let contract = row["tokenAddress"] as? String   // null → native
        let meta = row["tokenMetadata"] as? [String: Any]
        return Token(
            contract: contract,
            rawBalanceHex: rawHex,
            symbol: meta?["symbol"] as? String,
            name: meta?["name"] as? String,
            decimals: meta?["decimals"] as? Int
        )
    }

    static func parseTokens(_ data: Data) -> [Token] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let rows = dataObj["tokens"] as? [[String: Any]] else { return [] }
        return rows.compactMap(tokenFromRow)
    }

    /// Group a batched response's rows by `"network|address"` (address
    /// lowercased — the `tokenCache` key shape). Pure; `prefetchBalances` does
    /// the cache write.
    static func groupBatchedRows(_ data: Data) -> [String: [Token]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let rows = dataObj["tokens"] as? [[String: Any]] else { return [:] }
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

    func assetTransfers(network: String, address: String, maxCount: Int) async throws(RPCError) -> [Transfer] {
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
        // failure is a real error.
        let sentResult = try? await sent
        let recvResult = try? await received
        guard sentResult != nil || recvResult != nil else {
            throw .allEndpointsFailed(.ethereum)  // chain is cosmetic here; connector logs the real one
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
        let params: [String: Any] = [
            addressKey: address,
            // H2: include `internal` — contract-initiated native moves (exchange
            // withdrawals, bridge payouts, DEX native-out) live here on
            // Ethereum/Polygon; omitting it hid real history at no saving.
            // NFTs (`erc721`/`erc1155`) are deliberately excluded — this is the
            // fungibles view; NFT history is a separate feature.
            "category": ["external", "internal", "erc20"],
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
        // **B5 guard.** A full uint256 is 64 hex chars (~78 decimal digits) —
        // far past Decimal's 38-significant-digit capacity, where the
        // accumulation below overflows to NaN. Reject over-long input up front,
        // and NaN-check the result, so a pathological raw balance returns nil
        // (the caller drops the row) instead of a silently-corrupt amount.
        guard hex.count <= 64 else { return nil }
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
