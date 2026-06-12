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
/// **Rate limits.** For N signatures we issue ⌈N/100⌉ sequential
/// list pages + N detail calls. The detail calls run through a
/// bounded fan-out window (`maxConcurrentDetailFetches`) so the
/// endpoint's `RateLimiter` is fed at its sustained rate instead of
/// being stampeded past its bounded wait; if a specific call still
/// fails, the adapter swallows the per-signature failure and returns
/// what landed. At the full-history cap (1,000 signatures) the
/// hydration pass is deliberately slow — wall-clock-bounded by the
/// endpoint's sustained rate — rather than a parallel storm.
struct SolanaTransactionAdapter: Sendable {
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "sol-tx-adapter")

    /// Upper bound on simultaneous `getTransaction` detail fetches.
    /// Must stay at or below the primary endpoint's burst capacity
    /// (5) so the token bucket's bounded wait is never exhausted by
    /// our own fan-out.
    private static let maxConcurrentDetailFetches = 4

    func fetch(address: String, limit: Int) async throws -> [TransactionEvent] {
        // **Full history (2026-06-13).** The signature list pages
        // with the `before` cursor (newest-first; the cursor is the
        // last signature of the previous page). Pages run
        // sequentially through the rate-limited `RPCClient` until
        // `limit` signatures (the per-chain full-history cap —
        // logged when hit), a short page (history exhausted), or a
        // mid-pagination failure — which keeps the signatures
        // already listed (`RPCError.cancelled` still propagates
        // immediately). Listing is cheap; the cost lives in the
        // per-signature detail hydration below, which stays inside
        // the bounded fan-out window.
        let pageSize = min(limit, 100)
        var sigArray: [[String: Any]] = []
        var before: String?
        while sigArray.count < limit {
            if Task.isCancelled { throw RPCError.cancelled }
            var sigOptions: [String: Sendable] = ["limit": pageSize]
            if let before { sigOptions["before"] = before }
            let sigData: Data
            do {
                sigData = try await client.callJSONResultData(
                    chain: .solana,
                    method: "getSignaturesForAddress",
                    params: [address, sigOptions]
                )
            } catch {
                if case .cancelled = error { throw error }
                if before == nil { throw error }
                Self.log.warning("Signature page after \(before ?? "-", privacy: .private) failed — keeping \(sigArray.count, privacy: .public) signatures")
                break
            }
            guard let page = (try? JSONSerialization.jsonObject(with: sigData)) as? [[String: Any]],
                  !page.isEmpty else {
                break
            }
            sigArray.append(contentsOf: page)
            guard let lastSignature = page.last?["signature"] as? String,
                  lastSignature != before else { break }
            before = lastSignature
            if page.count < pageSize { break } // history exhausted
            if sigArray.count >= limit {
                // Honest bound: RealRPCTransactionScanner.fullHistoryCap.
                Self.log.info("Solana signature list hit the \(limit, privacy: .public)-signature full-history cap — older rows not fetched this scan")
            }
        }
        let signatures = sigArray.prefix(limit).compactMap { entry -> (signature: String, slot: Int64, blockTime: Int64?, err: Bool)? in
            guard let signature = entry["signature"] as? String else { return nil }
            let slot = (entry["slot"] as? Int64) ?? 0
            let blockTime = entry["blockTime"] as? Int64
            let err = (entry["err"] as? NSNull) == nil && entry["err"] != nil
            return (signature, slot, blockTime, err)
        }

        // Fan the per-signature `getTransaction` calls out with a
        // BOUNDED window. The primary endpoint's token bucket
        // (10 rps, burst 5) gives up after a ~1 s bounded wait — 25
        // simultaneous waiters deterministically exhaust that bound,
        // throw spurious `.rateLimited` before a single request is
        // sent, and trip the endpoint's circuit breaker. A small
        // window keeps the limiter fed at its sustained rate.
        // Results are written back by index so the feed preserves
        // the signature list's (newest-first) order.
        var resultsByIndex = [TransactionEvent?](repeating: nil, count: signatures.count)
        await withTaskGroup(of: (Int, TransactionEvent?).self) { group in
            var inFlight = 0
            for (index, sigInfo) in signatures.enumerated() {
                // A torn-down refresh stops enqueueing; the group
                // cancels already-running children automatically.
                if Task.isCancelled { break }
                if inFlight >= Self.maxConcurrentDetailFetches,
                   let (finishedIndex, finishedEvent) = await group.next() {
                    resultsByIndex[finishedIndex] = finishedEvent
                    inFlight -= 1
                }
                group.addTask {
                    let event = await self.fetchOne(
                        address: address,
                        signature: sigInfo.signature,
                        slot: sigInfo.slot,
                        blockTime: sigInfo.blockTime,
                        hadError: sigInfo.err
                    )
                    return (index, event)
                }
                inFlight += 1
            }
            for await (index, event) in group {
                resultsByIndex[index] = event
            }
        }
        return resultsByIndex.compactMap { $0 }
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
                // `tokenAmount.amount` (raw integer string) WITH
                // authoritative decimals; legacy transfer carries
                // `amount` and NO decimals at all — `decimals == 0`
                // there means "unknown", not zero, so track
                // knowability separately.
                let rawAmount: String
                let decimals: Int
                let decimalsKnown: Bool
                if let tokenAmount = info["tokenAmount"] as? [String: Any] {
                    rawAmount = (tokenAmount["amount"] as? String) ?? "0"
                    decimals = (tokenAmount["decimals"] as? Int) ?? 0
                    decimalsKnown = tokenAmount["decimals"] is Int
                } else {
                    rawAmount = (info["amount"] as? String) ?? "0"
                    decimals = 0
                    decimalsKnown = false
                }
                let mint = (info["mint"] as? String)
                let raw = Decimal(string: rawAmount) ?? 0
                // For SPL, source / dest are TOKEN ACCOUNTS, not the
                // user's wallet address. The authoritative owner
                // mapping lives in `meta.preTokenBalances` /
                // `meta.postTokenBalances` (each entry carries
                // `owner`); classify direction against the wallet
                // owner from those. This is what makes RECEIVED
                // `transferChecked` rows land — the wallet is never
                // the authority on an incoming transfer. Fall back
                // to the authority-based heuristic only when the
                // balances metadata is absent.
                let direction: TransactionDirection
                let counterparty: String
                let resolvedDecimals: Int
                if let meta,
                   let classified = Self.classifyViaTokenBalances(
                       meta: meta,
                       wallet: address,
                       mint: mint
                   ) {
                    direction = classified.direction
                    counterparty = classified.counterparty
                    if decimalsKnown {
                        resolvedDecimals = decimals
                    } else if let known = classified.decimals ?? Self.registryDecimals(mint) {
                        resolvedDecimals = known
                    } else {
                        // Decimals unresolvable — rendering the raw
                        // base-unit integer as a human amount would
                        // overstate by 10^decimals (1 USDC → shown
                        // as 1,000,000). Honest omission instead.
                        continue
                    }
                } else {
                    let authority = (info["authority"] as? String) ?? source
                    let (fallbackDirection, fallbackCounterparty) = Self.classify(
                        address: address, from: authority, to: dest
                    )
                    guard let fallbackDirection else { continue }
                    direction = fallbackDirection
                    counterparty = fallbackCounterparty
                    if decimalsKnown {
                        resolvedDecimals = decimals
                    } else if let known = Self.registryDecimals(mint) {
                        resolvedDecimals = known
                    } else {
                        // Same honesty rule as above — never render
                        // raw base units.
                        continue
                    }
                }
                let amount = raw / Self.scale(decimals: resolvedDecimals)
                return TransactionEvent(
                    chain: .solana,
                    address: address,
                    txHash: signature,
                    direction: direction,
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

    /// Classify an SPL transfer's direction for `wallet` from the
    /// transaction's pre/post token balances. Each balance entry
    /// carries the token account's `owner`, so the wallet's net
    /// per-mint delta is computable regardless of whether the wallet
    /// signed (outgoing) or merely received (`transferChecked` into
    /// one of its associated token accounts).
    ///
    /// Returns `nil` when the balances metadata doesn't cover the
    /// wallet for this mint, or when the instruction names no mint
    /// and the wallet's balance changes span multiple mints (an
    /// ambiguous swap leg) — the caller then falls back to the
    /// authority heuristic.
    private static func classifyViaTokenBalances(
        meta: [String: Any],
        wallet: String,
        mint: String?
    ) -> (direction: TransactionDirection, counterparty: String, decimals: Int?)? {
        let pre = meta["preTokenBalances"] as? [[String: Any]] ?? []
        let post = meta["postTokenBalances"] as? [[String: Any]] ?? []
        guard !pre.isEmpty || !post.isEmpty else { return nil }

        // Net raw-amount delta per mint per owner. Raw amounts of
        // DIFFERENT mints carry different scales — netting them into
        // one number (the legacy `transfer` case, whose instruction
        // names no mint) can invert the direction of a swap leg.
        // Classification only ever happens within a single mint.
        var deltaByMintAndOwner: [String: [String: Decimal]] = [:]
        var walletDecimalsByMint: [String: Int] = [:]
        func accumulate(_ entries: [[String: Any]], sign: Decimal) {
            for entry in entries {
                guard let owner = entry["owner"] as? String,
                      let entryMint = entry["mint"] as? String else { continue }
                if let mint, entryMint != mint { continue }
                let uiTokenAmount = entry["uiTokenAmount"] as? [String: Any] ?? [:]
                let rawString = (uiTokenAmount["amount"] as? String) ?? "0"
                let rawValue = Decimal(string: rawString) ?? 0
                deltaByMintAndOwner[entryMint, default: [:]][owner, default: 0] += sign * rawValue
                if owner == wallet, walletDecimalsByMint[entryMint] == nil,
                   let entryDecimals = uiTokenAmount["decimals"] as? Int {
                    walletDecimalsByMint[entryMint] = entryDecimals
                }
            }
        }
        accumulate(pre, sign: -1)
        accumulate(post, sign: 1)

        // Resolve which mint this leg is about: the instruction's
        // mint when present, otherwise the single mint under which
        // the wallet appears. When the wallet appears under MULTIPLE
        // mints and the instruction names none (legacy-transfer swap
        // legs), the leg is ambiguous — bail out rather than invent
        // a direction from mixed scales.
        let walletMints = deltaByMintAndOwner.compactMap { mintKey, owners in
            owners[wallet] != nil ? mintKey : nil
        }
        let resolvedMint: String
        if let mint {
            guard walletMints.contains(mint) else { return nil }
            resolvedMint = mint
        } else if walletMints.count == 1, let onlyMint = walletMints.first {
            resolvedMint = onlyMint
        } else {
            return nil
        }

        let owners = deltaByMintAndOwner[resolvedMint] ?? [:]
        let walletDelta = owners[wallet] ?? 0
        let direction: TransactionDirection
        if walletDelta > 0 {
            direction = .incoming
        } else if walletDelta < 0 {
            direction = .outgoing
        } else {
            // Wallet appears in the balances but its net change is
            // zero — a transfer between the wallet's own token
            // accounts.
            direction = .internal
        }
        // Counterparty: the owner whose delta — within the SAME
        // mint — moved opposite to the wallet's.
        let counterparty = owners.first { owner, delta in
            owner != wallet && (
                (direction == .incoming && delta < 0) ||
                (direction == .outgoing && delta > 0)
            )
        }?.key ?? ""
        return (direction, direction == .internal ? "" : counterparty, walletDecimalsByMint[resolvedMint])
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

    /// Decimals for a curated mint. `nil` when the mint is unknown
    /// (or nil) — callers must then skip the row rather than render
    /// raw base units as a human amount.
    private static func registryDecimals(_ mint: String?) -> Int? {
        guard let mint else { return nil }
        return SolanaTokenRegistry.mints[mint]?.decimals
    }

    private static let lamportsPerSol: Decimal = {
        var result = Decimal(1)
        for _ in 0..<9 { result *= 10 }
        return result
    }()

    private static func scale(decimals: Int) -> Decimal {
        // `decimals` arrives from RPC JSON — clamp so a malicious
        // node can't trap the range (negative) or spin the loop
        // (absurdly large). 77 ≈ Decimal's significand capacity.
        let clamped = max(0, min(decimals, 77))
        var result = Decimal(1)
        for _ in 0..<clamped { result *= 10 }
        return result
    }
}
