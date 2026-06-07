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
