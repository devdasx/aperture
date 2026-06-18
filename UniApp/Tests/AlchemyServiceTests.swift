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
    func parseTokensNativeAndToken() {
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
        let tokens = AlchemyService.parseTokens(data(json))
        #expect(tokens.count == 2)
        let native = tokens.first { $0.isNative }
        #expect(native != nil)
        #expect(native?.rawBalanceHex == "0xde0b6b3a7640000")   // 1 ETH
        let usdc = tokens.first { !$0.isNative }
        #expect(usdc?.contract?.lowercased() == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        #expect(usdc?.decimals == 6)
        #expect(usdc?.symbol == "USDC")
    }

    @Test("parseTokens returns empty (never throws) on a malformed body")
    func parseTokensMalformed() {
        #expect(AlchemyService.parseTokens(data("{}")).isEmpty)
        #expect(AlchemyService.parseTokens(data("not json")).isEmpty)
    }

    // MARK: - groupBatchedRows (Task 1) — by (network,address)

    @Test("groupBatchedRows groups by network and lowercased address across the batch")
    func groupBatched() {
        let json = """
        { "data": { "tokens": [
          { "address":"0xAAA", "network":"eth-mainnet", "tokenAddress":null, "tokenBalance":"0x1" },
          { "address":"0xAAA", "network":"eth-mainnet", "tokenAddress":"0xToken", "tokenBalance":"0x2" },
          { "address":"0xAAA", "network":"base-mainnet", "tokenAddress":null, "tokenBalance":"0x3" },
          { "address":"0xBBB", "network":"eth-mainnet", "tokenAddress":null, "tokenBalance":"0x4" }
        ] } }
        """
        let grouped = AlchemyService.groupBatchedRows(data(json))
        #expect(grouped["eth-mainnet|0xaaa"]?.count == 2)
        #expect(grouped["base-mainnet|0xaaa"]?.count == 1)
        #expect(grouped["eth-mainnet|0xbbb"]?.count == 1)
        // A (network,address) the batch had no rows for is simply absent here —
        // `prefetchBalances` fills it with [] when warming the cache.
        #expect(grouped["base-mainnet|0xbbb"] == nil)
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
        // 65 hex chars — past uint256, rejected by the length guard.
        #expect(AlchemyService.decimalFromHex("0x" + String(repeating: "f", count: 65)) == nil)
        // 64 hex chars all-f = uint256 max — overflows Decimal → nil (NaN guard).
        #expect(AlchemyService.decimalFromHex("0x" + String(repeating: "f", count: 64)) == nil)
    }
}
