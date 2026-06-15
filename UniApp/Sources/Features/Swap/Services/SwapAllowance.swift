import Foundation

/// Reads an ERC-20 `allowance(owner, spender)` on an EVM chain via
/// `eth_call`, so the executor can decide whether a token swap needs an
/// `approve` first. Chain RPC (Rule #27) through the shared `RPCClient`
/// (rate-limited, fallback-rotated). Returns the raw 0x-hex 32-byte word
/// (compared without `Decimal` via `SwapEVMABI.isAllowance` — u256 overflows
/// `Decimal`). `nil` on any RPC/parse failure (the caller treats an
/// unreadable allowance as "approve to be safe").
enum SwapAllowance {
    static func read(
        token: String,
        owner: String,
        spender: String,
        chain: SupportedChain
    ) async -> String? {
        guard let calldata = SwapEVMABI.allowanceCallData(owner: owner, spender: spender) else {
            return nil
        }
        let callObject: [String: Sendable] = ["to": token, "data": calldata]
        return try? await RPCClient.shared.callJSONString(
            chain: chain,
            method: "eth_call",
            params: [callObject, "latest"]
        )
    }

    /// `eth_gasPrice` → wei (UInt64). Used for the self-built approve tx and
    /// as the swap tx's gas-price fallback when Li.Fi omits one. `nil` on
    /// failure (the caller then refuses honestly rather than sign with a
    /// guessed price).
    static func gasPriceWei(chain: SupportedChain) async -> UInt64? {
        guard let hex = try? await RPCClient.shared.callJSONString(
            chain: chain, method: "eth_gasPrice", params: []
        ) else { return nil }
        return SwapEVMABI.quantityToUInt64(hex)
    }

    /// Live pending nonce for `address` on `chain` (`eth_getTransactionCount`
    /// with the `"pending"` tag, matching the Send signer). `nil` on failure.
    static func pendingNonce(address: String, chain: SupportedChain) async -> UInt64? {
        guard let hex = try? await RPCClient.shared.callJSONString(
            chain: chain, method: "eth_getTransactionCount", params: [address, "pending"]
        ) else { return nil }
        return SwapEVMABI.quantityToUInt64(hex)
    }

    /// Poll `eth_getTransactionReceipt` until the tx confirms (`0x1`) or
    /// fails (`0x0`). Returns `true` confirmed, `false` failed/reverted,
    /// `nil` if it never resolved within the window (timeout). Used to wait
    /// for an approval to land before signing the swap.
    static func awaitReceipt(
        txHash: String,
        chain: SupportedChain,
        attempts: Int = 12,
        delaySeconds: UInt64 = 5
    ) async -> Bool? {
        for _ in 0..<attempts {
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let data = try? await RPCClient.shared.callJSONResultData(
                chain: chain, method: "eth_getTransactionReceipt", params: [txHash]
            ) else { continue }
            guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue // null receipt → still pending
            }
            switch dict["status"] as? String {
            case "0x1": return true
            case "0x0": return false
            default: continue
            }
        }
        return nil // timed out
    }
}
