import Foundation

/// Reads an ERC-20 `allowance(owner, spender)` on an EVM chain via
/// `eth_call`, so the **Token Approvals** scanner can show the LIVE
/// allowance for each `(token, spender)` pair it discovered from logs.
/// Chain RPC (Rule #27) through the shared `RPCClient` (rate-limited,
/// fallback-rotated). Returns the raw 0x-hex 32-byte word (the caller
/// compares it as big-endian bytes — a u256 overflows `Decimal`). `nil`
/// on any RPC/parse failure (an unreadable allowance is simply skipped,
/// never fabricated — Rule #16).
enum EVMAllowanceReader {
    static func read(
        token: String,
        owner: String,
        spender: String,
        chain: SupportedChain
    ) async -> String? {
        guard let calldata = EVMERC20ABI.allowanceCallData(owner: owner, spender: spender) else {
            return nil
        }
        let callObject: [String: Sendable] = ["to": token, "data": calldata]
        return try? await RPCClient.shared.callJSONString(
            chain: chain,
            method: "eth_call",
            params: [callObject, "latest"]
        )
    }
}
