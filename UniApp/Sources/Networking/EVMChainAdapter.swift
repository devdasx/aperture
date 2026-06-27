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
    /// for a given chain. Used for metadata fallback discovery only.
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
        // `Int(_:radix:)` never yields a negative from unsigned hex (an
        // out-of-range value returns nil above), so only the upper bound needs
        // checking.
        if value > 77 { return 18 }
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
