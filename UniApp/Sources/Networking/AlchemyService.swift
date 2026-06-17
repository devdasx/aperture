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
        let body: [String: Any] = [
            "addresses": [["address": address, "networks": [network]]],
            "withMetadata": true,
            "withPrices": false,
            "includeNativeTokens": true,
            "includeErc20Tokens": true,
        ]
        let data = try await postJSON(url: url, body: body, network: network)
        let tokens = Self.parseTokens(data)
        tokenCache[cacheKey] = CachedTokens(expires: Date().addingTimeInterval(cacheTTL), tokens: tokens)
        return tokens
    }

    private static func parseTokens(_ data: Data) -> [Token] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let rows = dataObj["tokens"] as? [[String: Any]] else { return [] }
        var out: [Token] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let rawHex = row["tokenBalance"] as? String else { continue }
            let contract = row["tokenAddress"] as? String   // null → native
            let meta = row["tokenMetadata"] as? [String: Any]
            out.append(Token(
                contract: contract,
                rawBalanceHex: rawHex,
                symbol: meta?["symbol"] as? String,
                name: meta?["name"] as? String,
                decimals: meta?["decimals"] as? Int
            ))
        }
        return out
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
            "category": ["external", "erc20"],
            "maxCount": cap,
            "order": "desc",
            "withMetadata": true,
            "excludeZeroValue": true,
        ]
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "alchemy_getAssetTransfers", "params": [params]]
        let data = try await postJSON(url: url, body: body, network: network)
        return Self.parseTransfers(data)
    }

    private static func parseTransfers(_ data: Data) -> [Transfer] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
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
            // Prefer the exact raw value / decimals; fall back to the
            // already-adjusted `value` number for native rows.
            var amount = Decimal(0)
            if let rawValueHex = raw?["value"] as? String,
               let rawDecHex = raw?["decimal"] as? String,
               let rawValue = decimalFromHex(rawValueHex),
               let dec = Int((rawDecHex.hasPrefix("0x") ? String(rawDecHex.dropFirst(2)) : rawDecHex), radix: 16) {
                amount = rawValue / pow10(dec)
            } else if let v = row["value"] as? Double {
                amount = Decimal(v)
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
        var result = Decimal(0)
        let sixteen = Decimal(16)
        for char in hex {
            guard let digit = char.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(digit)
        }
        return result
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
