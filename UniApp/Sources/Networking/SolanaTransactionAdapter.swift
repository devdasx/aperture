import Foundation
import OSLog

/// Transaction-history adapter for Solana mainnet. Uses two JSON-RPC
/// methods on the same endpoint set:
///
/// 1. `getSignaturesForAddress(address, { limit })` — returns the
///    paginated list of signatures touching the address.
/// 2. `getTransaction(signature, { encoding: "jsonParsed" })` —
///    resolves each signature to a full transaction with the
///    instructions decoded enough to extract sender / receiver /
///    lamport amounts for `system::transfer` and SPL `transfer`
///    instructions.
///
/// **Scope.** Native SOL transfers (lamport-based `system::transfer`)
/// + SPL token transfers (`spl-token::transfer` /
/// `spl-token::transferChecked`). Other instruction types (program
/// invocations, NFT mints) are skipped — they don't read cleanly as
/// "received" / "sent" rows in a wallet activity feed, and surfacing
/// them as noise would be worse than honest omission.
///
/// **Rate limits.** The public mainnet-beta endpoint allows ~100 RPS
/// per IP. For 25 signatures (the default `limit`) we issue 26 calls
/// (1 list + 25 detail). The endpoint's `RateLimiter` paces these to
/// stay under the cap; if the cap trips on a specific block, the
/// adapter swallows the per-signature failure and returns what
/// landed.
struct SolanaTransactionAdapter: Sendable {
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "sol-tx-adapter")

    func fetch(address: String, limit: Int) async throws -> [TransactionEvent] {
        let sigOptions: [String: Sendable] = ["limit": min(limit, 25)]
        let sigData = try await client.callJSONResultData(
            chain: .solana,
            method: "getSignaturesForAddress",
            params: [address, sigOptions]
        )
        guard let sigArray = (try? JSONSerialization.jsonObject(with: sigData)) as? [[String: Any]] else {
            return []
        }
        let signatures = sigArray.prefix(limit).compactMap { entry -> (signature: String, slot: Int64, blockTime: Int64?, err: Bool)? in
            guard let signature = entry["signature"] as? String else { return nil }
            let slot = (entry["slot"] as? Int64) ?? 0
            let blockTime = entry["blockTime"] as? Int64
            let err = (entry["err"] as? NSNull) == nil && entry["err"] != nil
            return (signature, slot, blockTime, err)
        }

        var events: [TransactionEvent] = []
        events.reserveCapacity(signatures.count)
        for sigInfo in signatures {
            if let event = await fetchOne(
                address: address,
                signature: sigInfo.signature,
                slot: sigInfo.slot,
                blockTime: sigInfo.blockTime,
                hadError: sigInfo.err
            ) {
                events.append(event)
            }
        }
        return events
    }

    /// Resolve one signature to a `TransactionEvent` by inspecting
    /// the transaction's parsed instructions. Returns `nil` if the
    /// transaction doesn't decode as a transfer affecting this
    /// address (program call, vote, etc.).
    private func fetchOne(
        address: String,
        signature: String,
        slot: Int64,
        blockTime: Int64?,
        hadError: Bool
    ) async -> TransactionEvent? {
        let txOptions: [String: Sendable] = [
            "encoding": "jsonParsed",
            "maxSupportedTransactionVersion": 0,
        ]
        guard let data = try? await client.callJSONResultData(
            chain: .solana,
            method: "getTransaction",
            params: [signature, txOptions]
        ) else {
            return nil
        }
        guard let tx = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let transaction = tx["transaction"] as? [String: Any],
              let message = transaction["message"] as? [String: Any],
              let instructions = message["instructions"] as? [[String: Any]] else {
            return nil
        }

        let meta = tx["meta"] as? [String: Any]
        let occurredAt: Date
        if let blockTime {
            occurredAt = Date(timeIntervalSince1970: TimeInterval(blockTime))
        } else {
            occurredAt = Date()
        }
        let status: TransactionStatus = hadError ? .failed : .confirmed
        let feeLamports = (meta?["fee"] as? Int64) ?? 0
        let fee = feeLamports > 0 ? (Decimal(feeLamports) / Self.lamportsPerSol) : nil

        // Look for system::transfer or spl-token::transfer
        // instructions that involve this address.
        for instruction in instructions {
            guard let parsed = instruction["parsed"] as? [String: Any],
                  let info = parsed["info"] as? [String: Any] else {
                continue
            }
            let program = (instruction["program"] as? String) ?? ""
            let type = (parsed["type"] as? String) ?? ""

            // Native SOL: system::transfer
            if program == "system", type == "transfer" {
                let source = (info["source"] as? String) ?? ""
                let dest = (info["destination"] as? String) ?? ""
                let lamports = (info["lamports"] as? Int64) ?? 0
                let amount = Decimal(lamports) / Self.lamportsPerSol
                let (direction, counterparty) = Self.classify(address: address, from: source, to: dest)
                if direction == nil { continue }
                return TransactionEvent(
                    chain: .solana,
                    address: address,
                    txHash: signature,
                    direction: direction!,
                    amount: amount,
                    tokenSymbol: "SOL",
                    tokenContract: nil,
                    blockNumber: slot,
                    occurredAt: occurredAt,
                    status: status,
                    counterparty: counterparty,
                    fee: direction == .outgoing ? fee : nil
                )
            }
            // SPL token: spl-token::transfer or transferChecked
            if program == "spl-token", (type == "transfer" || type == "transferChecked") {
                let source = (info["source"] as? String) ?? ""
                let dest = (info["destination"] as? String) ?? ""
                // For transferChecked the amount lives under
                // `tokenAmount.amount` (raw integer string); for
                // legacy transfer it's `amount` (raw integer string).
                let rawAmount: String
                let decimals: Int
                if let tokenAmount = info["tokenAmount"] as? [String: Any] {
                    rawAmount = (tokenAmount["amount"] as? String) ?? "0"
                    decimals = (tokenAmount["decimals"] as? Int) ?? 0
                } else {
                    rawAmount = (info["amount"] as? String) ?? "0"
                    decimals = 0
                }
                let mint = (info["mint"] as? String)
                let raw = Decimal(string: rawAmount) ?? 0
                let amount = raw / Self.scale(decimals: decimals)
                // For SPL, source / dest are token accounts not the
                // user's wallet address. The wallet's relation is
                // determined via the authority field (the signer).
                let authority = (info["authority"] as? String) ?? source
                let (direction, counterparty) = Self.classify(address: address, from: authority, to: dest)
                if direction == nil { continue }
                return TransactionEvent(
                    chain: .solana,
                    address: address,
                    txHash: signature,
                    direction: direction!,
                    amount: amount,
                    tokenSymbol: Self.knownMintSymbol(mint) ?? "SPL",
                    tokenContract: mint,
                    blockNumber: slot,
                    occurredAt: occurredAt,
                    status: status,
                    counterparty: counterparty,
                    fee: direction == .outgoing ? fee : nil
                )
            }
        }
        return nil
    }

    private static func classify(
        address: String,
        from: String,
        to: String
    ) -> (TransactionDirection?, String) {
        if from == address && to == address {
            return (.internal, "")
        }
        if from == address {
            return (.outgoing, to)
        }
        if to == address {
            return (.incoming, from)
        }
        return (nil, "")
    }

    /// Map well-known SPL mints to their human-readable ticker. The
    /// list is intentionally small (USDC, USDT) — broader mint
    /// resolution lives in the token registry; missing mints render
    /// as "SPL" + the mint hash as the contract, which the user
    /// can verify on Solscan.
    private static func knownMintSymbol(_ mint: String?) -> String? {
        guard let mint else { return nil }
        switch mint {
        case "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": return "USDC"
        case "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": return "USDT"
        default: return nil
        }
    }

    private static let lamportsPerSol: Decimal = {
        var result = Decimal(1)
        for _ in 0..<9 { result *= 10 }
        return result
    }()

    private static func scale(decimals: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<decimals { result *= 10 }
        return result
    }
}
