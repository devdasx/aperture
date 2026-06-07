import Foundation

/// Solana adapter. JSON-RPC against the Solana RPC API.
/// `getBalance(address)` returns `{ value: lamports }` envelope.
struct SolanaChainAdapter: Sendable {
    let client: RPCClient

    /// Native SOL balance — lamports / 10^9.
    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data = try await client.callJSONResultData(
            chain: .solana,
            method: "getBalance",
            params: [address]
        )
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let lamports = (dict["value"] as? NSNumber)?.int64Value ?? 0
        let sol = NSDecimalNumber(value: lamports).decimalValue / 1_000_000_000
        return ChainAccountSummary(nativeBalance: sol, isUsed: sol > 0)
    }

    /// Raw SPL token discovery via `getTokenAccountsByOwner`. Returns
    /// every fungible SPL token the owner address holds, decoded into
    /// `(mint, amount, decimals)` triples. Aperture pairs each mint
    /// with a small built-in metadata registry for symbol/name; mints
    /// the registry doesn't know fall through to a truncated mint
    /// display (honest about what we don't know).
    struct SPLTokenAccount: Sendable {
        let mint: String
        let amount: Decimal       // canonical units, already decoded
        let decimals: Int
    }

    func fetchTokenAccounts(address: String) async throws(RPCError) -> [SPLTokenAccount] {
        let filter: [String: Sendable] = [
            "programId": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",  // SPL Token program
        ]
        let opts: [String: Sendable] = [
            "encoding": "jsonParsed",
        ]
        let data = try await client.callJSONResultData(
            chain: .solana,
            method: "getTokenAccountsByOwner",
            params: [address, filter, opts]
        )
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = dict["value"] as? [[String: Any]] else {
            return []
        }
        return value.compactMap { item in
            guard let account = item["account"] as? [String: Any],
                  let acctData = account["data"] as? [String: Any],
                  let parsed = acctData["parsed"] as? [String: Any],
                  let info = parsed["info"] as? [String: Any],
                  let mint = info["mint"] as? String,
                  let tokenAmount = info["tokenAmount"] as? [String: Any],
                  let amountStr = tokenAmount["amount"] as? String,
                  let raw = Decimal(string: amountStr) else {
                return nil
            }
            let decimals = (tokenAmount["decimals"] as? NSNumber)?.intValue ?? 0
            let amount = decimals == 0 ? raw : raw / Self.pow10(decimals)
            // Filter out zero-balance accounts — Solana keeps
            // closed-but-rent-exempt token accounts hanging around.
            guard amount > 0 else { return nil }
            return SPLTokenAccount(mint: mint, amount: amount, decimals: decimals)
        }
    }

    private static func pow10(_ n: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<n { result *= 10 }
        return result
    }

    /// First-page of recent signatures via `getSignaturesForAddress`.
    func fetchRecentTransactions(address: String, limit: Int = 25) async throws(RPCError) -> [SolanaRawTransaction] {
        let params: [Sendable] = [address, ["limit": limit]]
        let data = try await client.callJSONResultData(
            chain: .solana,
            method: "getSignaturesForAddress",
            params: params
        )
        let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return array.map { dict in
            let sig = dict["signature"] as? String ?? ""
            let slot = (dict["slot"] as? NSNumber)?.int64Value
            let blockTime = (dict["blockTime"] as? NSNumber)?.doubleValue
            let hasErr = dict["err"] != nil && !(dict["err"] is NSNull)
            return SolanaRawTransaction(
                txHash: sig,
                blockNumber: slot,
                occurredAt: blockTime.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                status: hasErr ? .failed : .confirmed
            )
        }
    }
}

struct SolanaRawTransaction: Sendable {
    let txHash: String
    let blockNumber: Int64?
    let occurredAt: Date
    let status: SolanaTxStatus
}

enum SolanaTxStatus: Sendable { case pending, confirmed, failed }
