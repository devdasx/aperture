import Foundation
import OSLog

/// Domain-layer adapter for EVM chains (Ethereum, Arbitrum, Base,
/// Optimism, Polygon, BNB Chain, Avalanche, Celo, Scroll, zkSync Era,
/// Kava EVM, opBNB). One adapter for all 12 — every EVM RPC speaks
/// the standard JSON-RPC surface, so the adapter parameterizes only
/// on `chain` for endpoint selection.
///
/// **Phase 1 scope (this turn):** native balance fetch via
/// `eth_getBalance`, used-address heuristic via
/// `eth_getTransactionCount`. ERC-20 token balances and history land
/// in Phase 6 (T-057).
///
/// **Honest output.** Returns native balance as `Decimal` already
/// divided by `10^18` (EVM convention). Token balances will divide
/// by per-token `decimals()` once T-057 lands.
struct EVMChainAdapter: Sendable {
    let chain: SupportedChain
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "evm-adapter")

    /// Native balance in chain units (ETH, MATIC, BNB, …) — already
    /// divided by 10^18. `eth_getBalance` returns hex-encoded wei.
    func fetchNativeBalance(address: String) async throws(RPCError) -> Decimal {
        let hexString = try await client.callJSONString(
            chain: chain,
            method: "eth_getBalance",
            params: [address, "latest"]
        )
        guard let wei = Decimal(hexString: hexString) else {
            throw .decodingFailed("Failed to parse hex balance: \(hexString)")
        }
        return wei / Self.weiPerEther
    }

    /// **2026-06-09 — Multicall3 batched balance fetcher.** Reads N
    /// ERC-20 token balances for one holder in a SINGLE `eth_call` via
    /// the [Multicall3](https://github.com/mds1/multicall) contract
    /// deployed at the same address on every major EVM chain:
    /// `0xcA11bde05977b3631167028862bE2a173976CA11`.
    ///
    /// Compared to N separate `fetchTokenBalance(holder:contract:)`
    /// calls, this is one network round trip instead of N — for a
    /// chain like Ethereum with ~25 tokens in the registry, that's a
    /// **~25× reduction in RPC requests** for the token-scan phase.
    /// Across 12 EVM chains the overall token-scan wall-clock drops
    /// from "rate-limit-bound" to "single-round-trip-bound."
    ///
    /// Returns one `Decimal?` per requested contract, in the same
    /// order as `contracts`. A `nil` entry means that token's
    /// individual `balanceOf` reverted or returned no data (e.g.
    /// non-ERC-20 contract, contract not deployed on this chain,
    /// proxy without storage) — we report it honestly, the caller
    /// treats it as zero for display.
    ///
    /// Falls back to per-token sequential fetch if multicall3 isn't
    /// deployed on the chain (response = empty bytes, or the
    /// `eth_call` returned a deterministic JSON-RPC error).
    ///
    /// **Throws on transport-level failure (2026-06-11).** When the
    /// batched call fails because the device is offline, the chain's
    /// endpoints are rate-limiting, or every endpoint is down, the
    /// error propagates — it is NOT converted into all-zero
    /// balances, and the ~25× per-token fallback storm is NOT fired
    /// against a fleet that is already throttling us. Callers must
    /// treat a thrown error as "balances unknown", never as
    /// "balances are zero."
    ///
    /// **ABI**: `aggregate3((address target, bool allowFailure,
    /// bytes callData)[] calls)` returns
    /// `(bool success, bytes returnData)[]`. Selector `0x82ad56cb`.
    /// Each call is `balanceOf(address)` with the holder padded to
    /// 32 bytes.
    func fetchTokenBalancesBatched(
        holder: String,
        contracts: [String]
    ) async throws(RPCError) -> [Decimal?] {
        guard !contracts.isEmpty else { return [] }

        let callData = Self.encodeMulticall3Aggregate3(
            holder: holder,
            tokenContracts: contracts
        )
        let txObject: [String: Sendable] = [
            "to": Self.multicall3Address,
            "data": callData,
        ]
        let hexString: String
        do {
            hexString = try await client.callJSONString(
                chain: chain,
                method: "eth_call",
                params: [txObject, "latest"]
            )
        } catch {
            // **2026-06-11 — narrowed fallback trigger.** Only fall
            // back to per-token calls when the batched call failed
            // for a reason per-token calls could plausibly survive:
            // a deterministic JSON-RPC error from the Multicall3
            // address (not deployed / reverting on this chain).
            // Everything else — `.cancelled`, `.rateLimited`,
            // `.network`, `.allEndpointsFailed`, malformed
            // responses — rethrows: firing N more `eth_call`s at a
            // fleet that is offline or throttling us would amplify
            // traffic ~25× at the worst possible moment, and
            // swallowing the error would convert a total outage
            // into silent all-zero balances.
            if case .rpcError = error {
                return try await fetchTokenBalancesSequentialFallback(
                    holder: holder,
                    contracts: contracts
                )
            }
            throw error
        }
        let stripped = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard !stripped.isEmpty else {
            return try await fetchTokenBalancesSequentialFallback(
                holder: holder,
                contracts: contracts
            )
        }
        return Self.decodeMulticall3Result(stripped, expectedCount: contracts.count)
    }

    /// Fallback path used when Multicall3 isn't deployed on the chain
    /// (the batched `eth_call` returned empty bytes or a deterministic
    /// JSON-RPC error). Per-token `balanceOf` fetch.
    ///
    /// **Rule #28 — parallel fan-out (2026-06-14).** The per-token
    /// `eth_call balanceOf` reads are fully independent — `eth_call`
    /// is a read-only state query with no inherent ordering between
    /// reads of different contracts at the same block
    /// (ethereum.org JSON-RPC spec), so a sequential loop needlessly
    /// serialized N round trips. They now fan out through a
    /// `withTaskGroup`; results are written back into a
    /// pre-sized array at each token's INPUT INDEX so the returned
    /// order matches `contracts` exactly (the caller pairs result[i]
    /// with contracts[i]). Every call still goes through the same
    /// `client` (→ `RPCClient.shared`), so the per-endpoint
    /// `RateLimiter` token bucket bounds total in-flight requests —
    /// concurrent `acquire`s serialize at the bucket actor and each
    /// consumes one token, identical throttling to the old loop, just
    /// without the artificial wait between tokens.
    ///
    /// **Honest failure (2026-06-11, preserved).** A token whose
    /// individual fetch throws yields `nil` (balance unknown), never a
    /// fabricated `0`. If EVERY token failed, the last error is
    /// rethrown — an outage must surface as an error the caller can
    /// render, not as a wallet that suddenly holds nothing.
    /// Cancellation propagates: a cancelled child surfaces as
    /// `.cancelled` and aborts the whole fan-out.
    private func fetchTokenBalancesSequentialFallback(
        holder: String,
        contracts: [String]
    ) async throws(RPCError) -> [Decimal?] {
        guard !contracts.isEmpty else { return [] }

        // One slot per input contract; tasks write by index so the
        // returned array preserves `contracts` order regardless of
        // completion order. `.failure` carries the error so the
        // "all failed → rethrow" / cancellation contracts survive.
        enum Outcome: Sendable {
            case success(Decimal)
            case failure(RPCError)
        }

        var slots: [Outcome?] = Array(repeating: nil, count: contracts.count)

        await withTaskGroup(of: (Int, Outcome).self) { group in
            for (index, contract) in contracts.enumerated() {
                group.addTask {
                    do {
                        let balance = try await self.fetchTokenBalance(
                            holder: holder,
                            contract: contract
                        )
                        return (index, .success(balance))
                    } catch {
                        // `withTaskGroup` re-types the child's error as
                        // `any Error`; `fetchTokenBalance` only ever
                        // throws `RPCError`, so the cast always
                        // succeeds — the `??` is a typed-throws bridge,
                        // not a real fallback.
                        return (index, .failure((error as? RPCError) ?? .allEndpointsFailed(self.chain)))
                    }
                }
            }
            for await (index, outcome) in group {
                slots[index] = outcome
            }
        }

        var results: [Decimal?] = []
        results.reserveCapacity(contracts.count)
        var lastError: RPCError?
        for slot in slots {
            switch slot {
            case .success(let value):
                results.append(value)
            case .failure(let error):
                // Cancellation aborts the whole fan-out — surface it
                // as cancellation, never as a partial all-nil result.
                if case .cancelled = error { throw error }
                lastError = error
                results.append(nil)
            case .none:
                // Unreachable: every index gets exactly one outcome
                // from the group. Treated as "unknown" defensively.
                results.append(nil)
            }
        }
        if let lastError, !results.isEmpty, results.allSatisfy({ $0 == nil }) {
            throw lastError
        }
        return results
    }

    /// Multicall3 deployment address (same on every major EVM chain).
    internal static let multicall3Address = "0xcA11bde05977b3631167028862bE2a173976CA11"

    /// Read a single ERC-20 token balance via `eth_call balanceOf`.
    /// Returns the raw integer balance (token base units, e.g.
    /// 1_000_000 for 1 USDC since USDC has 6 decimals). Throws
    /// on RPC errors; returns `0` when the call succeeds with empty
    /// data (a not-deployed contract on this chain).
    func fetchTokenBalance(holder: String, contract: String) async throws(RPCError) -> Decimal {
        let callData = EVMTokenRegistry.balanceOfCallData(holder: holder)
        let txObject: [String: Sendable] = [
            "to": contract,
            "data": callData,
        ]
        let hexString = try await client.callJSONString(
            chain: chain,
            method: "eth_call",
            params: [txObject, "latest"]
        )
        // Empty result ("0x") means the contract doesn't exist on
        // this chain, or balanceOf reverted. Treat as zero — honest
        // and avoids surfacing per-token RPC failures the user can't
        // act on.
        let stripped = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard !stripped.isEmpty,
              let raw = Decimal(hexString: hexString) else {
            return 0
        }
        return raw
    }

    /// `eth_getTransactionCount` (nonce) at the latest block. Non-
    /// zero ⇒ the address has sent at least one transaction ⇒ "used."
    /// Doesn't catch receive-only addresses (nonce stays 0 if the
    /// address only receives). For receive-only detection we also
    /// look at balance > 0; combined heuristic is "isUsed = nonce >
    /// 0 || balance > 0."
    func fetchTransactionCount(address: String) async throws(RPCError) -> Int {
        let hexString = try await client.callJSONString(
            chain: chain,
            method: "eth_getTransactionCount",
            params: [address, "latest"]
        )
        let stripped = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard let nonce = Int(stripped, radix: 16) else {
            throw .decodingFailed("Failed to parse hex nonce: \(hexString)")
        }
        return nonce
    }

    /// Combined: returns native balance + `isUsed` flag in one
    /// public method so callers don't have to compose two requests.
    /// Both calls share the same endpoint rotation; if the first
    /// succeeds and the second fails on a fallback, the result is
    /// still honest: balance from the working endpoint, isUsed
    /// reflecting only the balance signal.
    func fetchAccountSummary(address: String) async throws(RPCError) -> AccountSummary {
        // Sequential by design under Swift 6 typed throws —
        // `async let` doesn't currently propagate `throws(RPCError)`
        // cleanly. The two calls share the endpoint's rate-limit
        // bucket anyway, so the wall-clock saving from running them
        // concurrently is marginal and not worth the type-erasure.
        let balance = try await fetchNativeBalance(address: address)
        let nonce = (try? await fetchTransactionCount(address: address)) ?? 0
        let isUsed = nonce > 0 || balance > 0
        return AccountSummary(
            nativeBalance: balance,
            isUsed: isUsed,
            transactionCount: nonce
        )
    }

    /// What an EVM adapter returns from `fetchAccountSummary`.
    struct AccountSummary: Sendable {
        let nativeBalance: Decimal
        let isUsed: Bool
        let transactionCount: Int
    }

    private static let weiPerEther: Decimal = {
        var result = Decimal(1)
        for _ in 0..<18 { result *= 10 }
        return result
    }()

    // MARK: - Token metadata (Custom Tokens — name() / symbol() / decimals())

    /// Read a token's `(name, symbol, decimals)` via three parallel
    /// `eth_call`s. Used by the Add Custom Token flow to populate the
    /// preview card automatically once the user pastes a contract.
    ///
    /// **Standard ERC-20 selectors (constant across every EVM chain):**
    /// - `name()`     → `0x06fdde03` → ABI-encoded `string`
    /// - `symbol()`   → `0x95d89b41` → ABI-encoded `string`
    /// - `decimals()` → `0x313ce567` → uint8
    ///
    /// **ABI string decode strategy.** Standard ERC-20 returns
    /// `(offset, length, data)` — 32 bytes for the offset, 32 bytes
    /// for the length, then `length` bytes of UTF-8 padded to a
    /// 32-byte boundary. Some legacy tokens (MKR, EOS, original-DAI)
    /// instead return a `bytes32` directly — fewer bytes, no offset
    /// header. The decoder tries the standard form first and falls
    /// back to `bytes32` if that produces nonsense (empty,
    /// non-printable, or implausibly-long length).
    ///
    /// Throws `.decodingFailed` when both name and symbol come back
    /// empty — that's the honest signal that the contract isn't a
    /// real ERC-20 surface, and the Add sheet renders the right
    /// copy for it per Rule #16.
    func fetchTokenMetadata(contract: String) async throws(RPCError) -> TokenMetadataFetchResult {
        async let nameHexTask: String? = (try? await callTokenView(contract: contract, selector: "0x06fdde03"))
        async let symbolHexTask: String? = (try? await callTokenView(contract: contract, selector: "0x95d89b41"))
        async let decimalsHexTask: String? = (try? await callTokenView(contract: contract, selector: "0x313ce567"))
        let nameHex = await nameHexTask ?? ""
        let symbolHex = await symbolHexTask ?? ""
        let decimalsHex = await decimalsHexTask ?? ""

        let name = Self.decodeABIString(hex: nameHex)
        let symbol = Self.decodeABIString(hex: symbolHex)
        let decimals = Self.decodeUInt8(hex: decimalsHex)

        if !name.isEmpty || !symbol.isEmpty {
            return TokenMetadataFetchResult(
                name: name.isEmpty ? symbol : name,
                symbol: symbol.isEmpty ? name : symbol,
                decimals: decimals
            )
        }

        // **2026-06-09 — Trust Wallet info.json fallback.** RPC
        // path returned empty for both `name()` and `symbol()`. The
        // contract might be: (a) on a chain whose RPC fleet is
        // currently rate-limited, (b) a token with non-standard ABI
        // that doesn't match the view selectors, or (c) on a chain
        // we hit a transient outage on. Trust Wallet maintains a
        // CDN-cached `info.json` for every well-known token at
        // `blockchains/<slug>/assets/<eip55>/info.json`. If they
        // have it, we get name + symbol + decimals from one HTTPS
        // GET — completely independent of any RPC. Honest:
        // Trust Wallet's index isn't the same trust surface as
        // reading on-chain (it's curated, not real-time), but for
        // adding a known token to the wallet it's a reasonable
        // ground truth. The user can still edit the resolved
        // name/symbol in the preview step.
        if let result = await Self.fetchTrustWalletInfoJSON(chain: chain, contract: contract) {
            return result
        }
        throw .decodingFailed("Contract did not return ERC-20 name/symbol and no off-chain info found")
    }

    /// Last-resort metadata fetcher — tries Trust Wallet's
    /// `info.json` for the token. Returns nil if the file doesn't
    /// exist or the JSON shape doesn't match what we need. No
    /// network errors thrown — this is a fallback path, every
    /// failure quietly returns nil.
    private static func fetchTrustWalletInfoJSON(
        chain: SupportedChain,
        contract: String
    ) async -> TokenMetadataFetchResult? {
        guard let slug = trustWalletChainSlug(for: chain) else { return nil }
        let checksummed = Keccak256.eip55Checksum(contract: contract)
        let stripped = checksummed.hasPrefix("0x") ? String(checksummed.dropFirst(2)) : checksummed
        let withPrefix = "0x" + stripped
        // Try both checksummed-and-lowercase address paths — Trust
        // Wallet's tree stores EVM contracts in EIP-55 form but a
        // small number of older entries linger in lowercase.
        let candidates = [
            "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(slug)/assets/\(withPrefix)/info.json",
            "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(slug)/assets/0x\(stripped.lowercased())/info.json",
        ]
        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continue
                }
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = dict["name"] as? String,
                   let symbol = dict["symbol"] as? String,
                   let decimals = (dict["decimals"] as? NSNumber)?.intValue {
                    return TokenMetadataFetchResult(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines),
                        decimals: decimals
                    )
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Trust Wallet's `trustwallet/assets` repository directory name
    /// for a given chain. Mirrors `CoinMarkCache.trustWalletChainSlug`
    /// so the same mapping is used for both icons and metadata.
    private static func trustWalletChainSlug(for chain: SupportedChain) -> String? {
        switch chain {
        case .ethereum:   return "ethereum"
        case .arbitrum:   return "arbitrum"
        case .base:       return "base"
        case .optimism:   return "optimism"
        case .scroll:     return "scroll"
        case .zkSync:     return "zksync"
        case .polygon:    return "polygon"
        case .bnbChain:   return "smartchain"
        case .opBNB:      return "opbnb"
        case .avalanche:  return "avalanchec"
        case .celo:       return "celo"
        case .kavaEvm:    return "kavaevm"
        default:          return nil
        }
    }

    /// One `eth_call` to a view function. Returns the hex string the
    /// RPC returned (`"0x..."`).
    private func callTokenView(contract: String, selector: String) async throws(RPCError) -> String {
        let txObject: [String: Sendable] = [
            "to": contract,
            "data": selector,
        ]
        return try await client.callJSONString(
            chain: chain,
            method: "eth_call",
            params: [txObject, "latest"]
        )
    }

    /// Decode an ABI-encoded `string` (or fall back to a `bytes32`
    /// trim) from the hex returned by `eth_call`. Pure helper, no
    /// network.
    static func decodeABIString(hex: String) -> String {
        let stripped = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        guard !stripped.isEmpty else { return "" }
        let bytes = hexToBytes(stripped)
        guard bytes.count >= 32 else { return trimmedBytes32(bytes) }

        // Standard form: first 32 bytes = offset (should be 0x20),
        // next 32 bytes = length, then `length` bytes of data.
        if bytes.count >= 64 {
            let lengthSlice = Array(bytes[32..<64])
            var length: Int = 0
            for b in lengthSlice { length = (length << 8) | Int(b) }
            // Plausibility: length must fit in the remaining data and
            // can't exceed 1024 (reasonable cap for token names).
            if length > 0 && length <= 1024 && bytes.count >= 64 + length {
                let dataBytes = Array(bytes[64..<(64 + length)])
                if let str = String(data: Data(dataBytes), encoding: .utf8),
                   !str.isEmpty,
                   str.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0.value == 0x09 }) {
                    return str.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        // Fallback: treat the first 32 bytes as a `bytes32` and trim
        // trailing zero padding (legacy MKR-style tokens).
        return trimmedBytes32(Array(bytes.prefix(32)))
    }

    /// Decode a uint8 (the standard return for `decimals()`) from a
    /// hex `eth_call` response. Tolerates either a 32-byte ABI-padded
    /// form (the standard) or a bare byte. Returns 18 (the EVM
    /// default) when decode fails — honest fallback for malformed
    /// contracts.
    static func decodeUInt8(hex: String) -> Int {
        let stripped = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        guard !stripped.isEmpty, let value = Int(stripped, radix: 16) else { return 18 }
        // Sanity clamp — `decimals()` should be in 0...77 (max EVM
        // uint256 has 78 decimal digits; nothing real exceeds 30).
        if value < 0 || value > 77 { return 18 }
        return value
    }

    /// Trim a `bytes32` value to its UTF-8 string content (legacy
    /// MKR-style tokens). Strips trailing zero padding.
    private static func trimmedBytes32(_ bytes: [UInt8]) -> String {
        var trimmed = bytes
        while let last = trimmed.last, last == 0 {
            trimmed.removeLast()
        }
        guard let str = String(data: Data(trimmed), encoding: .utf8) else { return "" }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[i..<next], radix: 16) {
                bytes.append(byte)
            }
            i = next
        }
        return bytes
    }
}

/// Result of `EVMChainAdapter.fetchTokenMetadata(contract:)`. Same
/// shape as `EVMTokenRegistry.Entry`'s display fields so the Add
/// sheet's preview card can render either source uniformly.
struct TokenMetadataFetchResult: Sendable, Equatable {
    let name: String
    let symbol: String
    let decimals: Int
}

// MARK: - Decimal hex parsing helper

private extension Decimal {
    /// Parse a hex string like `"0x1234..."` into a `Decimal`. Used
    /// for EVM balance / value fields which are returned as
    /// hex-encoded base-10 integers (no fractional part). Returns
    /// `nil` on invalid input.
    init?(hexString: String) {
        var hex = hexString
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        if hex.isEmpty {
            self = .zero
            return
        }
        // Decimal can hold up to ~38 significant digits; EVM
        // balances at 256 bits are 78 decimal digits worst case.
        // We accept the precision loss for now (a 100,000 ETH
        // balance has only 6 leading digits in ETH units), and
        // log when truncation occurred so it's visible in
        // debugging.
        var result = Decimal(0)
        let sixteen = Decimal(16)
        for char in hex {
            guard let digit = char.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(digit)
        }
        self = result
    }
}

// MARK: - Multicall3 ABI codec

extension EVMChainAdapter {

    /// Encode the `aggregate3((address,bool,bytes)[])` call data for
    /// N token balanceOf reads against the same holder. Returns a
    /// `0x`-prefixed hex string ready for `eth_call`.
    ///
    /// Each item is `Call3(target: tokenContract, allowFailure: true,
    /// callData: balanceOf(holder))`. `allowFailure: true` so a single
    /// reverted token (e.g. proxy without storage) doesn't kill the
    /// whole batch.
    internal static func encodeMulticall3Aggregate3(
        holder: String,
        tokenContracts: [String]
    ) -> String {
        let selector = "82ad56cb" // aggregate3
        let outerOffset = pad32(toHex: 0x20) // 0x20 = where the array starts

        let n = tokenContracts.count
        let nHex = pad32(toHex: n)

        // balanceOf(address) call data: 4-byte selector + 32-byte padded
        // holder = 36 bytes = 72 hex chars. Padded to 64 hex chars (32
        // bytes) per ABI dynamic-bytes encoding → total 128 hex chars.
        let holderHex = strip0xLower(holder)
        let holderPadded = padLeft(holderHex, to: 64)
        let balanceOfSelector = "70a08231"
        let balanceOfData = balanceOfSelector + holderPadded
        // bytes data is 36 bytes = 72 hex chars; pad-right to 64 bytes =
        // 128 hex chars per ABI dynamic-bytes alignment.
        let bytesDataPadded = balanceOfData + String(repeating: "0", count: 128 - balanceOfData.count)

        // Item layout (192 bytes / 384 hex chars per item):
        //   address  | 32 bytes  | padded contract
        //   bool     | 32 bytes  | 0...01
        //   offset   | 32 bytes  | offset to bytes from start of item = 0x60
        //   length   | 32 bytes  | 0x24 (36 bytes of callData)
        //   data     | 64 bytes  | balanceOfData + zero pad
        let itemSize = 192 // bytes
        let itemBoolTrue = pad32(toHex: 1)
        let itemBytesOffset = pad32(toHex: 0x60)
        let itemBytesLength = pad32(toHex: 0x24)

        // Offsets are relative to the start of the array data (after
        // length). First offset = N×32 (skip the N offset slots),
        // each next offset = prev + itemSize.
        var offsetsHex = ""
        for i in 0..<n {
            let off = n * 32 + i * itemSize
            offsetsHex += pad32(toHex: off)
        }

        var itemsHex = ""
        for contract in tokenContracts {
            let contractPadded = padLeft(strip0xLower(contract), to: 64)
            itemsHex += contractPadded
            itemsHex += itemBoolTrue
            itemsHex += itemBytesOffset
            itemsHex += itemBytesLength
            itemsHex += bytesDataPadded
        }

        return "0x" + selector + outerOffset + nHex + offsetsHex + itemsHex
    }

    /// Decode the `(bool success, bytes returnData)[]` result of an
    /// `aggregate3` call. Each returnData is a 32-byte uint256 (the
    /// token's `balanceOf` result). Returns one `Decimal?` per item;
    /// `nil` indicates that token's call reverted or returned
    /// empty / sub-word returnData (contract not deployed on this
    /// chain — see the length-word validation below).
    ///
    /// Response layout:
    ///   offset to outer array | 32 bytes (always 0x20)
    ///   length N              | 32 bytes
    ///   [N item offsets]      | 32 bytes each, relative to start of array data
    ///   [N items]
    /// Each item `(bool, bytes)`:
    ///   bool success          | 32 bytes (1 = success)
    ///   offset to bytes       | 32 bytes (= 0x40 from item start)
    ///   bytes length          | 32 bytes (= 0x20 for uint256)
    ///   bytes data            | 32 bytes (the balance as uint256)
    internal static func decodeMulticall3Result(_ hex: String, expectedCount: Int) -> [Decimal?] {
        // Each hex char is 4 bits, so 1 byte = 2 hex chars.
        // outer offset (64) + length (64) = first 128 chars.
        guard hex.count >= 128 else { return Array(repeating: nil, count: expectedCount) }
        let lengthHex = substring(hex, from: 64, length: 64)
        guard let n = Int(lengthHex, radix: 16), n == expectedCount else {
            return Array(repeating: nil, count: expectedCount)
        }

        // Array data starts at hex char 128 (after offset + length).
        // We don't strictly need to parse the N item offsets — items are
        // contiguous and we know each item is 128 bytes (256 hex chars):
        //   bool (64) + offset (64) + length (64) + data (64) = 256 hex.
        // But the spec is: offsets index relative to array data start.
        // For safety, read each offset explicitly.
        var results: [Decimal?] = []
        results.reserveCapacity(n)
        let arrayDataStart = 128
        for i in 0..<n {
            let offHex = substring(hex, from: arrayDataStart + i * 64, length: 64)
            guard let off = Int(offHex, radix: 16) else {
                results.append(nil)
                continue
            }
            let itemStart = arrayDataStart + off * 2 // off is in bytes, hex chars = bytes * 2
            // Three fixed words (bool, offset, length) = 192 hex
            // chars must be present before we read anything.
            guard itemStart + 192 <= hex.count else {
                results.append(nil)
                continue
            }
            // bool success
            let successHex = substring(hex, from: itemStart, length: 64)
            let success = (Int(successHex, radix: 16) ?? 0) != 0
            if !success {
                results.append(nil)
                continue
            }
            // **2026-06-11 — validate the returnData length word.**
            // A `balanceOf` CALL against an address with no code on
            // this chain SUCCEEDS with EMPTY returndata: the item is
            // then only the three fixed words (length = 0), and the
            // old fixed read at itemStart + 192 consumed the NEXT
            // item's success flag (0x…01), fabricating a phantom
            // 1-base-unit balance the user never owned. Anything
            // shorter than a full 32-byte word is "no balance
            // returned" → nil.
            let lengthWordHex = substring(hex, from: itemStart + 128, length: 64)
            guard let byteLength = Int(lengthWordHex, radix: 16),
                  byteLength >= 32,
                  itemStart + 256 <= hex.count else {
                results.append(nil)
                continue
            }
            // bytes data — 32 bytes of uint256
            // offset (itemStart + 64) + length (itemStart + 128) +
            // data (itemStart + 192). For balanceOf the data is 32
            // bytes — read it directly.
            let dataHex = substring(hex, from: itemStart + 192, length: 64)
            if let value = Decimal(hexString: dataHex) {
                results.append(value)
            } else {
                results.append(nil)
            }
        }
        return results
    }

    // MARK: - Hex helpers

    /// Left-pad `s` with `0` chars until it reaches `width` characters.
    internal static func padLeft(_ s: String, to width: Int) -> String {
        if s.count >= width { return s }
        return String(repeating: "0", count: width - s.count) + s
    }

    /// Strip leading `0x` and lowercase.
    internal static func strip0xLower(_ s: String) -> String {
        let core = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        return core.lowercased()
    }

    /// Pad an integer to a 32-byte (64 hex char) big-endian hex string.
    internal static func pad32(toHex value: Int) -> String {
        return String(format: "%064x", value)
    }

    /// Substring by integer character offsets — `String.Index` arithmetic
    /// at scale is hostile to readability. We're inside a hex stream;
    /// every char is one byte's worth.
    internal static func substring(_ s: String, from: Int, length: Int) -> String {
        guard from >= 0, length >= 0, from + length <= s.count else { return "" }
        let start = s.index(s.startIndex, offsetBy: from)
        let end = s.index(start, offsetBy: length)
        return String(s[start..<end])
    }
}
