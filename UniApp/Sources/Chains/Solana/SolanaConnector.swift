import Foundation
import OSLog

/// **Solana connector — the JSON-RPC / SPL reference implementation.**
///
/// A FULLY INDEPENDENT module for `.solana`: its own `getBalance`
/// native read, its own `getTokenAccountsByOwner` SPL discovery across
/// BOTH token programs (legacy + Token-2022), and its own
/// `getSignaturesForAddress` + `getTransaction` parsed-instruction
/// history. It owns its request shapes + parsing end-to-end and
/// dispatches every call through the shared `RPCClient` actor (rotation
/// + rate-limit + circuit-breaking + ConcurrencyGate) — never a raw
/// `URLSession`. Endpoints come from `RPCRegistry.endpoints(for:
/// .solana)` (api.mainnet-beta.solana.com primary, solana-rpc.publicnode
/// fallback — one JSON-RPC shape covers both).
///
/// **Ported verbatim-faithful** from `SolanaChainAdapter`
/// (`fetchAccountSummary` balance, `fetchTokenAccounts` SPL discovery)
/// and `SolanaTransactionAdapter` (`fetch` history), plus the curated
/// `SolanaTokenRegistry` filter that `RealRPCBalanceScanner` applies to
/// the discovered accounts. Same endpoints, same `jsonParsed` decode,
/// same 10^9 lamports-per-SOL native scale, same per-mint decimals from
/// the token account, same both-programs merge, same bounded-fan-out
/// signature hydration, same `preTokenBalances`/`postTokenBalances`
/// direction classification.
///
/// **404 / unfunded.** Solana never surfaces a 404 for an unfunded
/// account — `getBalance` returns `{ value: 0 }` and
/// `getTokenAccountsByOwner` returns `{ value: [] }` for a brand-new
/// address, so the zero-balance state falls out of the normal parse with
/// no special-casing. `RPCError.isHTTPNotFound` is honored defensively
/// anyway (a provider that ever 404s the account path degrades to a zero
/// summary rather than throwing), matching the uniform connector
/// contract.
struct SolanaConnector: ChainConnector {
    let chain: SupportedChain = .solana
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "solana-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native SOL balance + used-address flag via `getBalance`. Ported
    /// from `SolanaChainAdapter.fetchAccountSummary`.
    ///
    /// `getBalance(address)` returns a `{ value: lamports }` envelope;
    /// lamports / 10^9 = SOL. `isUsed` keys on a positive balance (the
    /// same honest heuristic the adapter uses — Solana exposes no cheap
    /// per-address nonce/tx-count without a separate signature page).
    /// An HTTP 404 (which Solana never produces for an unfunded account,
    /// but a misbehaving provider might) maps to a zero summary rather
    /// than throwing, per the `ChainConnector` contract.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data: Data
        do {
            data = try await client.callJSONResultData(
                chain: chain,
                method: "getBalance",
                params: [address]
            )
        } catch {
            if RPCError.isHTTPNotFound(error) {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            throw error
        }
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let lamports = (dict["value"] as? NSNumber)?.int64Value ?? 0
        let sol = NSDecimalNumber(value: lamports).decimalValue / Self.lamportsPerSol
        return ChainAccountSummary(nativeBalance: sol, isUsed: sol > 0)
    }

    // MARK: - Token balances

    /// SPL-token balances for the curated `SolanaTokenRegistry` mints +
    /// the user's `customContracts` (mints), discovered in ONE
    /// `getTokenAccountsByOwner` pass per token program. Ported from
    /// `SolanaChainAdapter.fetchTokenAccounts` (both-programs discovery)
    /// + the curated/custom filter `RealRPCBalanceScanner` applies.
    ///
    /// `getTokenAccountsByOwner` returns EVERY mint the address has ever
    /// touched (dust airdrops, expired LP, scam tokens), so the rows are
    /// filtered to (registry mints ∪ `customContracts`) — surfacing all
    /// of them would flood the home with tokens the user didn't choose
    /// to hold (Rule #2 §A.7). Registry mints take their symbol/name from
    /// `SolanaTokenRegistry`; custom mints render with a truncated-mint
    /// display (the coordinator's custom-token pass owns their
    /// user-chosen symbol/name downstream). Per-mint decimals come from
    /// the token account itself (`tokenAmount.decimals`).
    ///
    /// Non-throwing per the contract: a discovery failure (every program
    /// query failed) degrades to `[]` (no rows), never a fabricated set
    /// of zeros — the coordinator preserves the user's stored balances.
    /// Only POSITIVE balances are returned (zero-balance rent-exempt
    /// accounts are dropped at parse time).
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        guard let accounts = await fetchAllTokenAccounts(address: address) else {
            return []
        }
        let customMints = Set(customContracts)

        let now = Date()
        var rows: [TokenBalance] = []
        rows.reserveCapacity(accounts.count)
        for account in accounts {
            // amount is already canonical (raw / 10^decimals) and > 0 —
            // the parse drops zero-balance accounts.
            let isRegistry = SolanaTokenRegistry.mints[account.mint] != nil
            let isCustom = customMints.contains(account.mint)
            guard isRegistry || isCustom else { continue }

            let symbol: String
            let name: String
            if isRegistry {
                symbol = SolanaTokenRegistry.symbol(for: account.mint)
                name = SolanaTokenRegistry.name(for: account.mint)
            } else {
                // Custom mint without registry metadata here; the
                // coordinator's custom-token pass owns the user-chosen
                // symbol/name. Render an honest truncated-mint placeholder.
                symbol = SolanaTokenRegistry.symbol(for: account.mint)
                name = account.mint
            }
            rows.append(TokenBalance(
                chain: chain,
                address: address,
                contract: account.mint,
                symbol: symbol,
                name: name,
                decimals: account.decimals,
                amount: account.amount,
                fiatBalance: nil,           // pricing stays in the coordinator
                fiatCurrencyCode: "",       // coordinator stamps the active currency
                lastUpdated: now
            ))
        }
        return rows
    }

    /// One discovered SPL token account — `(mint, canonical amount,
    /// decimals)`. Mirrors `SolanaChainAdapter.SPLTokenAccount`; kept
    /// internal so the connector owns its own work item.
    private struct SPLTokenAccount: Sendable {
        let mint: String
        let amount: Decimal       // canonical units, already decoded
        let decimals: Int
    }

    /// Legacy SPL Token + Token-2022 program ids. `getTokenAccountsByOwner`
    /// hard-filters on ONE `programId`, so a single query can never see
    /// the other program's accounts — Token-2022 mints (PYUSD, AUSD,
    /// DUSD, USDG, plus any user-added `.splToken2022` mint) are invisible
    /// to the legacy-only query. Two queries, merged; a token account is
    /// owned by exactly one program, so the union has no duplicates.
    /// Both forms are the 43-char base58 (decoding to a canonical 32-byte
    /// pubkey) — M-016/M-017: do NOT regress the Token-2022 id to the
    /// bogus 44-char `…EbZ` form.
    private static let tokenProgramIds: [String] = [
        "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",   // SPL Token (legacy)
        "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",   // Token-2022
    ]

    /// Token accounts across BOTH SPL programs. The two queries are
    /// independent (different `programId` filter, order-independent
    /// merge) so they run in PARALLEL with `async let` — both still
    /// dispatch through the shared `client`, so the per-endpoint
    /// `RateLimiter` bounds total in-flight requests exactly as before.
    /// Returns `nil` only when EVERY program query failed (a real scan
    /// failure — the caller emits no rows, preserving persisted
    /// balances); a partial result is returned honestly when one program
    /// answered. Ported from `SolanaChainAdapter.fetchTokenAccounts` +
    /// `RealRPCBalanceScanner.fetchAllSolanaTokenAccounts`.
    private func fetchAllTokenAccounts(address: String) async -> [SPLTokenAccount]? {
        async let legacy = fetchTokenAccounts(address: address, programId: Self.tokenProgramIds[0])
        async let token2022 = fetchTokenAccounts(address: address, programId: Self.tokenProgramIds[1])
        let legacyResult = await legacy
        let token2022Result = await token2022

        guard legacyResult != nil || token2022Result != nil else { return nil }
        return (legacyResult ?? []) + (token2022Result ?? [])
    }

    /// One `getTokenAccountsByOwner` query against a single token
    /// program. `jsonParsed` encoding; zero-balance rent-exempt accounts
    /// dropped. Returns `nil` on a transport/decode failure so the caller
    /// can tell a real failure from an empty (zero-token) account. Ported
    /// from `SolanaChainAdapter.fetchTokenAccounts(address:programId:)`.
    private func fetchTokenAccounts(address: String, programId: String) async -> [SPLTokenAccount]? {
        let filter: [String: Sendable] = ["programId": programId]
        let opts: [String: Sendable] = ["encoding": "jsonParsed"]
        guard let data = try? await client.callJSONResultData(
            chain: chain,
            method: "getTokenAccountsByOwner",
            params: [address, filter, opts]
        ),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = dict["value"] as? [[String: Any]] else {
            return nil
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

    // MARK: - Transaction history

    /// Upper bound on simultaneous `getTransaction` detail fetches. Must
    /// stay at or below the primary endpoint's burst capacity so the
    /// token bucket's bounded wait is never exhausted by our own
    /// fan-out. Ported from
    /// `SolanaTransactionAdapter.maxConcurrentDetailFetches`.
    private static let maxConcurrentDetailFetches = 4

    /// SOL + SPL transaction history via `getSignaturesForAddress`
    /// (paginated newest-first with the `before` cursor) +
    /// `getTransaction` (parsed-instruction hydration through a bounded
    /// fan-out window). Ported verbatim from `SolanaTransactionAdapter.fetch`.
    ///
    /// Scope: native SOL `system::transfer` + SPL
    /// `spl-token::transfer`/`transferChecked`. Other instruction types
    /// (program invocations, NFT mints) are skipped — they don't read
    /// cleanly as received/sent rows. A page-1 list failure throws; a
    /// later-page failure keeps the signatures already listed.
    /// `RPCError.cancelled` propagates immediately.
    ///
    /// `customContracts` is currently unused for gating (the parse only
    /// surfaces curated/known mints + the raw mint hash), kept for the
    /// uniform `ChainConnector` signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
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
                    chain: chain,
                    method: "getSignaturesForAddress",
                    params: [address, sigOptions]
                )
            } catch {
                if case .cancelled = error { throw error }
                if before == nil { throw error }
                Self.log.warning("Signature page after \(before ?? "-", privacy: .private) failed on \(self.chain.rawValue, privacy: .public) — keeping \(sigArray.count, privacy: .public) signatures")
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
                Self.log.info("Solana signature list on \(self.chain.rawValue, privacy: .public) hit the \(limit, privacy: .public)-signature cap — older rows not fetched this scan")
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
        // BOUNDED window. The primary endpoint's token bucket gives up
        // after a short bounded wait; N simultaneous waiters would
        // deterministically exhaust that bound, throw spurious
        // `.rateLimited`, and trip the circuit breaker. A small window
        // keeps the limiter fed at its sustained rate. Results are
        // written back by index so the feed preserves the (newest-first)
        // signature order.
        var resultsByIndex = [TransactionEvent?](repeating: nil, count: signatures.count)
        await withTaskGroup(of: (Int, TransactionEvent?).self) { group in
            var inFlight = 0
            for (index, sigInfo) in signatures.enumerated() {
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

    /// Resolve one signature to a `TransactionEvent` by inspecting the
    /// transaction's parsed instructions. Returns `nil` if it doesn't
    /// decode as a transfer affecting this address (program call, vote,
    /// ATA management, etc.). Ported from
    /// `SolanaTransactionAdapter.fetchOne`.
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
            chain: chain,
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
                guard let direction else { continue }
                return TransactionEvent(
                    chain: chain,
                    address: address,
                    txHash: signature,
                    direction: direction,
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
                // transferChecked carries `tokenAmount.amount` (raw) WITH
                // authoritative decimals; legacy transfer carries `amount`
                // and NO decimals — `decimals == 0` there means "unknown",
                // tracked via `decimalsKnown`.
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
                // SPL source/dest are TOKEN ACCOUNTS, not the wallet
                // address. The authoritative owner mapping lives in
                // `meta.pre/postTokenBalances` (each entry carries
                // `owner`); classify against the wallet owner from those.
                // This is what makes RECEIVED `transferChecked` rows land
                // — the wallet is never the authority on an incoming
                // transfer. Fall back to the authority heuristic only when
                // the balances metadata is absent.
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
                        // Decimals unresolvable — rendering raw base units
                        // would overstate by 10^decimals. Honest omission.
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
                        continue
                    }
                }
                let amount = raw / Self.scale(decimals: resolvedDecimals)
                return TransactionEvent(
                    chain: chain,
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

    // MARK: - Direction classification (ported verbatim)

    /// Classify an SPL transfer's direction for `wallet` from the
    /// transaction's pre/post token balances. Each balance entry carries
    /// the token account's `owner`, so the wallet's net per-mint delta is
    /// computable regardless of whether the wallet signed (outgoing) or
    /// merely received (`transferChecked` into one of its associated
    /// token accounts). Returns `nil` when the balances metadata doesn't
    /// cover the wallet for this mint, or when the instruction names no
    /// mint and the wallet's balance changes span multiple mints (an
    /// ambiguous swap leg). Ported from
    /// `SolanaTransactionAdapter.classifyViaTokenBalances`.
    private static func classifyViaTokenBalances(
        meta: [String: Any],
        wallet: String,
        mint: String?
    ) -> (direction: TransactionDirection, counterparty: String, decimals: Int?)? {
        let pre = meta["preTokenBalances"] as? [[String: Any]] ?? []
        let post = meta["postTokenBalances"] as? [[String: Any]] ?? []
        guard !pre.isEmpty || !post.isEmpty else { return nil }

        // Net raw-amount delta per mint per owner. Different mints carry
        // different scales — netting them into one number can invert a
        // swap leg's direction. Classification only ever happens within a
        // single mint.
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

        // Resolve which mint this leg is about.
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
            // Wallet appears but net change is zero — a transfer between
            // the wallet's own token accounts.
            direction = .internal
        }
        // Counterparty: the owner whose same-mint delta moved opposite to
        // the wallet's.
        let counterparty = owners.first { owner, delta in
            owner != wallet && (
                (direction == .incoming && delta < 0) ||
                (direction == .outgoing && delta > 0)
            )
        }?.key ?? ""
        return (direction, direction == .internal ? "" : counterparty, walletDecimalsByMint[resolvedMint])
    }

    /// Direction + counterparty from a (wallet, from, to) triple — the
    /// native and authority-fallback path. Ported from
    /// `SolanaTransactionAdapter.classify`.
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

    // MARK: - Mint metadata helpers (ported verbatim)

    /// Map well-known SPL mints to their human ticker. Intentionally
    /// small (USDC, USDT) — broader resolution lives in
    /// `SolanaTokenRegistry`; unknown mints render as "SPL" + the mint
    /// hash as the contract. Ported from
    /// `SolanaTransactionAdapter.knownMintSymbol`.
    private static func knownMintSymbol(_ mint: String?) -> String? {
        guard let mint else { return nil }
        switch mint {
        case "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": return "USDC"
        case "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": return "USDT"
        default: return nil
        }
    }

    /// Decimals for a curated mint; `nil` when unknown (callers then skip
    /// the row rather than render raw base units). Ported from
    /// `SolanaTransactionAdapter.registryDecimals`.
    private static func registryDecimals(_ mint: String?) -> Int? {
        guard let mint else { return nil }
        return SolanaTokenRegistry.mints[mint]?.decimals
    }

    // MARK: - Scale helpers

    /// 10^9 — Solana's smallest unit is the lamport.
    private static let lamportsPerSol: Decimal = {
        var result = Decimal(1)
        for _ in 0..<9 { result *= 10 }
        return result
    }()

    private static func pow10(_ n: Int) -> Decimal {
        let clamped = max(0, min(n, 38))
        var result = Decimal(1)
        for _ in 0..<clamped { result *= 10 }
        return result
    }

    /// Token-decimals scale, clamped against a malicious node (negative →
    /// trap, absurdly large → spin). 77 ≈ Decimal's significand capacity.
    /// Ported from `SolanaTransactionAdapter.scale`.
    private static func scale(decimals: Int) -> Decimal {
        let clamped = max(0, min(decimals, 77))
        var result = Decimal(1)
        for _ in 0..<clamped { result *= 10 }
        return result
    }
}
