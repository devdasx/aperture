import Testing
import Foundation
@testable import Aperture

/// **Alchemy balance + history parsing/grouping unit tests (2026-06-18).**
///
/// These exercise the pure, network-free seams added by the EVM fetch rebuild:
/// batched multi-network grouping, REST pagination key extraction, token
/// parsing, error-aware transfer parsing (the silent-empty-history fix), and
/// the hex→Decimal overflow guard. No live RPC — deterministic fixtures only,
/// so they pin behavior without flakiness.
struct AlchemyServiceTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - parseTokens (single-network) — native + erc20, decimals

    @Test("parseTokens reads the native row (contract nil) and an erc20 row with metadata decimals")
    func parseTokensNativeAndToken() throws {
        let json = """
        { "data": { "tokens": [
          { "address":"0xabc", "network":"eth-mainnet", "tokenAddress": null,
            "tokenBalance":"0xde0b6b3a7640000",
            "tokenMetadata": { "decimals":18, "symbol":"ETH", "name":"Ether" } },
          { "address":"0xabc", "network":"eth-mainnet", "tokenAddress":"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            "tokenBalance":"0xf4240",
            "tokenMetadata": { "decimals":6, "symbol":"USDC", "name":"USD Coin" } }
        ] } }
        """
        let tokens = try AlchemyService.parseTokens(data(json))
        #expect(tokens.count == 2)
        let native = tokens.first { $0.isNative }
        #expect(native != nil)
        #expect(native?.rawBalanceHex == "0xde0b6b3a7640000")   // 1 ETH
        let usdc = tokens.first { !$0.isNative }
        #expect(usdc?.contract?.lowercased() == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        #expect(usdc?.decimals == 6)
        #expect(usdc?.symbol == "USDC")
    }

    @Test("parseTokens THROWS on an error envelope or a missing data.tokens (BUG 2A)")
    func parseTokensErrors() {
        // No `data.tokens` — was a silent `[]` that became "native row absent".
        #expect(throws: RPCError.self) { _ = try AlchemyService.parseTokens(data("{}")) }
        #expect(throws: RPCError.self) { _ = try AlchemyService.parseTokens(data("not json")) }
        // An Alchemy error envelope at HTTP 200 surfaces the real message.
        let errBody = #"{"error":{"code":-32000,"message":"data product not enabled"}}"#
        #expect(throws: RPCError.self) { _ = try AlchemyService.parseTokens(data(errBody)) }
    }

    @Test("tokenFromRow treats a native-sentinel tokenAddress as native (BUG 2C)")
    func nativeSentinel() throws {
        // Some providers return native with a 0xeee… sentinel instead of null.
        let json = #"{"data":{"tokens":[{"address":"0xa","network":"eth-mainnet","tokenAddress":"0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE","tokenBalance":"0xde0b6b3a7640000"}]}}"#
        let tokens = try AlchemyService.parseTokens(data(json))
        #expect(tokens.count == 1)
        #expect(tokens.first?.isNative == true)   // sentinel → native, not a token
    }

    // MARK: - usdPrice + priceUSD parsing (withPrices, 2026-06-19)

    @Test("usdPrice prefers the USD entry, parses String and NSNumber values, nil when absent")
    func usdPriceParsing() {
        #expect(AlchemyService.usdPrice(from: [["currency": "usd", "value": "1.0001"]]) == Decimal(string: "1.0001"))
        #expect(AlchemyService.usdPrice(from: [["currency": "eur", "value": "0.9"], ["currency": "USD", "value": "1.05"]]) == Decimal(string: "1.05"))
        #expect(AlchemyService.usdPrice(from: [["currency": "usd", "value": 2.5 as NSNumber]]) == Decimal(string: "2.5"))
        #expect(AlchemyService.usdPrice(from: []) == nil)
        #expect(AlchemyService.usdPrice(from: nil) == nil)
        // No explicit usd entry → falls back to the first entry's value.
        #expect(AlchemyService.usdPrice(from: [["value": "3.0"]]) == Decimal(string: "3.0"))
    }

    @Test("parseTokens reads tokenPrices into priceUSD (legitimacy signal)")
    func parseTokensPrice() throws {
        let json = """
        { "data": { "tokens": [
          { "address":"0xa","network":"eth-mainnet","tokenAddress":"0xLink","tokenBalance":"0xde0b6b3a7640000",
            "tokenMetadata": { "decimals":18, "symbol":"LINK", "name":"Chainlink Token" },
            "tokenPrices": [ { "currency":"usd", "value":"14.20" } ] },
          { "address":"0xa","network":"eth-mainnet","tokenAddress":"0xSpam","tokenBalance":"0x1",
            "tokenMetadata": { "decimals":18, "symbol":"CLAIM", "name":"claim-rewards.xyz" } }
        ] } }
        """
        let tokens = try AlchemyService.parseTokens(data(json))
        let link = tokens.first { $0.symbol == "LINK" }
        #expect(link?.priceUSD == Decimal(string: "14.20"))
        let spam = tokens.first { $0.symbol == "CLAIM" }
        #expect(spam?.priceUSD == nil)   // no tokenPrices → unpriced
    }

    @Test("canonicalNetwork normalizes the matic→polygon response slug")
    func canonicalSlug() {
        #expect(AlchemyService.canonicalNetwork("matic-mainnet") == "polygon-mainnet")
        #expect(AlchemyService.canonicalNetwork("eth-mainnet") == "eth-mainnet")
    }

    @Test("groupBatchedRows keys a matic-mainnet response row under polygon-mainnet")
    func groupBatchedPolygonSlug() throws {
        let json = #"{"data":{"tokens":[{"address":"0xAAA","network":"matic-mainnet","tokenAddress":null,"tokenBalance":"0x1"}]}}"#
        let grouped = try AlchemyService.groupBatchedRows(data(json))
        #expect(grouped["polygon-mainnet|0xaaa"]?.count == 1)
        #expect(grouped["matic-mainnet|0xaaa"] == nil)   // not under the raw slug
    }

    // MARK: - groupBatchedRows (Task 1) — by (network,address)

    @Test("groupBatchedRows groups by network and lowercased address across the batch")
    func groupBatched() throws {
        let json = """
        { "data": { "tokens": [
          { "address":"0xAAA", "network":"eth-mainnet", "tokenAddress":null, "tokenBalance":"0x1" },
          { "address":"0xAAA", "network":"eth-mainnet", "tokenAddress":"0xToken", "tokenBalance":"0x2" },
          { "address":"0xAAA", "network":"base-mainnet", "tokenAddress":null, "tokenBalance":"0x3" },
          { "address":"0xBBB", "network":"eth-mainnet", "tokenAddress":null, "tokenBalance":"0x4" }
        ] } }
        """
        let grouped = try AlchemyService.groupBatchedRows(data(json))
        #expect(grouped["eth-mainnet|0xaaa"]?.count == 2)
        #expect(grouped["base-mainnet|0xaaa"]?.count == 1)
        #expect(grouped["eth-mainnet|0xbbb"]?.count == 1)
        // A (network,address) the batch had no rows for is simply absent here —
        // `prefetchBalances` (2B) only caches the slices actually present.
        #expect(grouped["base-mainnet|0xbbb"] == nil)
    }

    @Test("groupBatchedRows THROWS on an error envelope (BUG 2A/2B)")
    func groupBatchedThrowsOnError() {
        let errBody = #"{"error":{"message":"unsupported"}}"#
        #expect(throws: RPCError.self) { _ = try AlchemyService.groupBatchedRows(data(errBody)) }
    }

    // MARK: - restPageKey (pagination, B1)

    @Test("restPageKey returns the key when present, nil when empty or absent")
    func pageKeyExtraction() {
        #expect(AlchemyService.restPageKey(from: data(#"{"data":{"pageKey":"abc123","tokens":[]}}"#)) == "abc123")
        #expect(AlchemyService.restPageKey(from: data(#"{"data":{"pageKey":"","tokens":[]}}"#)) == nil)
        #expect(AlchemyService.restPageKey(from: data(#"{"data":{"tokens":[]}}"#)) == nil)
        #expect(AlchemyService.restPageKey(from: data("{}")) == nil)
    }

    // MARK: - parseTransfers (Task 6 / H1–H3)

    @Test("parseTransfers parses native (exact rawContract), internal, and erc20 rows")
    func transfersSuccess() throws {
        let json = """
        { "jsonrpc":"2.0","id":1,"result":{ "transfers":[
          { "hash":"0xh1","uniqueId":"0xh1:external","from":"0xfrom","to":"0xto",
            "value":0.5,"asset":"ETH","category":"external",
            "rawContract":{ "value":"0x6f05b59d3b20000","address":null,"decimal":"0x12" },
            "blockNum":"0xb0eadc","metadata":{ "blockTimestamp":"2021-05-01T00:00:00.000Z" } },
          { "hash":"0xh2","uniqueId":"0xh2:internal","from":"0xcontract","to":"0xto",
            "value":1.0,"asset":"ETH","category":"internal",
            "rawContract":{ "value":"0xde0b6b3a7640000","address":null,"decimal":"0x12" } },
          { "hash":"0xh3","uniqueId":"0xh3:erc20","from":"0xfrom","to":"0xto",
            "asset":"USDC","category":"erc20",
            "rawContract":{ "value":"0xf4240","address":"0xToken","decimal":"0x6" } }
        ], "pageKey":"" } }
        """
        let transfers = try AlchemyService.parseTransfers(data(json))
        #expect(transfers.count == 3)
        let native = transfers.first { $0.uniqueId == "0xh1:external" }
        // Exact: 0x6f05b59d3b20000 wei / 1e18 == 0.5 (no Double rounding).
        #expect(native?.amount == Decimal(string: "0.5"))
        #expect(native?.contract == nil)
        // H2: the `internal` category survives.
        #expect(transfers.contains { $0.category == "internal" })
        let usdc = transfers.first { $0.uniqueId == "0xh3:erc20" }
        #expect(usdc?.amount == Decimal(string: "1"))      // 0xf4240 = 1_000_000 / 1e6
        #expect(usdc?.contract == "0xToken")
    }

    @Test("parseTransfers THROWS on a JSON-RPC error body (not an empty list) — H1")
    func transfersErrorThrows() {
        let json = #"{ "jsonrpc":"2.0","id":1,"error":{ "code":-32602,"message":"invalid params" } }"#
        #expect(throws: RPCError.self) {
            _ = try AlchemyService.parseTransfers(data(json))
        }
    }

    @Test("parseTransfers maps a 429 error body to .rateLimited")
    func transfersRateLimited() {
        let json = #"{ "jsonrpc":"2.0","id":1,"error":{ "code":429,"message":"throttled" } }"#
        do {
            _ = try AlchemyService.parseTransfers(data(json))
            Issue.record("expected a throw")
        } catch {
            if case .rateLimited = error { } else { Issue.record("expected .rateLimited, got \(error)") }
        }
    }

    @Test("parseTransfers returns empty (no throw) for a genuinely empty result")
    func transfersEmpty() throws {
        let json = #"{ "jsonrpc":"2.0","id":1,"result":{ "transfers":[], "pageKey":"" } }"#
        #expect(try AlchemyService.parseTransfers(data(json)).isEmpty)
    }

    // MARK: - decimalFromHex overflow + edge guards (B5)

    @Test("decimalFromHex handles zero, small values, and rejects invalid/over-long input")
    func hexDecimal() {
        #expect(AlchemyService.decimalFromHex("0x0") == .zero)
        #expect(AlchemyService.decimalFromHex("0xff") == Decimal(255))
        #expect(AlchemyService.decimalFromHex("0xZZ") == nil)              // invalid digit
        // 32 hex chars = 2^128-1 fits Decimal's 128-bit mantissa exactly.
        #expect(AlchemyService.decimalFromHex("0x" + String(repeating: "f", count: 32)) != nil)
        // 33+ SIGNIFICANT hex chars exceed 2^128 — Decimal would silently
        // truncate to ~38 significant digits (a corrupt amount); rejected.
        #expect(AlchemyService.decimalFromHex("0x" + String(repeating: "f", count: 33)) == nil)
        #expect(AlchemyService.decimalFromHex("0x" + String(repeating: "f", count: 64)) == nil)
    }

    @Test("decimalFromHex strips ABI 32-byte zero-padding (the missing-balances fix)")
    func hexDecimalPadding() {
        // Portfolio `tokenBalance` is a 64-hex-char (32-byte) left-zero-padded
        // value. 10 USDC = 0x…000989680; the padding must not trip the guard.
        let tenUSDC = "0x" + String(repeating: "0", count: 58) + "989680"
        #expect(AlchemyService.decimalFromHex(tenUSDC) == Decimal(10_000_000))
        // A real ETH balance the API returned, fully padded to 64 chars.
        let eth = "0x" + String(repeating: "0", count: 50) + "4367a98c3e0a63"
        #expect(AlchemyService.decimalFromHex(eth) == Decimal(string: "18972801339624035"))
        // A padded zero decodes to zero, not nil.
        #expect(AlchemyService.decimalFromHex("0x" + String(repeating: "0", count: 64)) == .zero)
        // 32 significant chars padded out to 64 still fits 128 bits → parses.
        #expect(AlchemyService.decimalFromHex("0x" + String(repeating: "0", count: 32) + String(repeating: "f", count: 32)) != nil)
        // 33 significant chars (even if total ≤ 64) still exceed 2^128 → nil.
        #expect(AlchemyService.decimalFromHex("0x" + String(repeating: "0", count: 31) + String(repeating: "f", count: 33)) == nil)
    }
}
