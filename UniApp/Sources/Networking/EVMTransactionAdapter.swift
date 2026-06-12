import Foundation
import OSLog

/// Transaction-history adapter for the EVM family — Ethereum,
/// Arbitrum, Base, Optimism, Scroll, zkSync Era, Polygon, BNB Smart
/// Chain, opBNB, Avalanche C, Celo, Kava EVM. One adapter for all 12
/// because every EVM RPC speaks the same `eth_getLogs` interface and
/// `eth_getBlockByNumber` interface for resolving timestamps.
///
/// **Strategy.** We can't ask a public RPC for "all transactions
/// involving this address" — Ethereum's JSON-RPC doesn't expose that
/// directly (Etherscan / Blockscout indexers do, but they require API
/// keys or trust). What we CAN do without any indexer:
///
/// 1. `eth_getLogs` filtered to the ERC-20 `Transfer(address,address,uint256)`
///    event with the user's address in the `from` or `to` topic.
///    Returns every token transfer touching the wallet across the
///    entire chain history (paginated by block range).
/// 2. For native ETH/BNB/AVAX transfers we currently cannot enumerate
///    via standard JSON-RPC alone — `eth_getLogs` only sees logged
///    events, and native transfers don't emit logs. We document this
///    limitation honestly per Rule #16: token transfers ship now,
///    native transfers land when the user supplies an indexer key
///    or when we add an opt-in indexer integration. The UI surfaces
///    "Token transfers only — native ETH/BNB/… history requires
///    an indexer" inline, not silently.
///
/// **Block range.** We scan the last `Self.scanBlockRange` blocks
/// (~14 days for ETH at 12s blocks, ~30 days for BSC at 3s, etc.).
/// Wider ranges paginate; for the test-mode preview that's enough
/// to show the recent activity the user expects.
///
/// **Honesty (Rule #16).** Every event is real on-chain data parsed
/// from the canonical ERC-20 log shape. Decimals: we don't look up
/// the contract's `decimals()` per row (would 10x the RPC traffic);
/// we keep the raw amount in token base units and the UI's
/// `WalletFormatting` divides by the registry's known decimals when
/// rendering. For unknown contracts, the value renders raw with the
/// contract's short address as the symbol so the user can verify
/// — never zeroed or hidden.
struct EVMTransactionAdapter: Sendable {
    let chain: SupportedChain
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "evm-tx-adapter")

    /// ERC-20 `Transfer(address indexed from, address indexed to,
    /// uint256 value)` event topic-0. Padded keccak256("Transfer
    /// (address,address,uint256)"); identical across every EVM chain.
    private static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

    /// How many blocks of history to scan. EVM logs can be heavy;
    /// we cap at 100k blocks (~14 days on Ethereum, less on faster
    /// chains). The cap balances "user sees recent activity" against
    /// "free public RPC doesn't time out."
    private static let scanBlockRange: Int64 = 100_000

    func fetch(
        address: String,
        limit: Int,
        customContracts: [String] = []
    ) async throws -> [TransactionEvent] {
        // **2026-06-09 rebuilt for coverage + speed.**
        //
        // **Coverage**: every EVM chain has a Routescan
        // Etherscan-compatible API
        // (`https://api.routescan.io/v2/network/mainnet/evm/{chainId}/etherscan/api`).
        // Routescan covers ALL 12 EVM chains Aperture supports
        // including the 3 that don't have public Blockscout
        // instances (BSC, opBNB, Avalanche). For the 9 chains with
        // Blockscout, both paths give the same data — we prefer
        // Routescan because it consistently supports `tokentx`
        // (whereas some Blockscout deployments don't), giving us a
        // single canonical indexer path across all chains.
        //
        // **Speed**: indexer's `tokentx` returns N indexed ERC-20
        // transfers in ONE HTTP request. Previously the ERC-20 path
        // ran 2 `eth_getLogs` calls (one per topic direction) over
        // a 100k-block range — typical wall-clock 5–30s per chain,
        // and slower chains time out entirely. The indexer path
        // resolves in <1s per chain.
        //
        // **Honesty fallbacks**:
        // - If the indexer call fails entirely → fall back to the
        //   prior Blockscout `txlist` + `eth_getLogs` paths.
        // - If individual records are malformed → skip the
        //   record, keep the rest. Never throw away the whole
        //   batch on one bad row.
        //
        // **Parallelism**: native (`txlist`) and token (`tokentx`)
        // run as `async let` — two concurrent HTTP requests, one
        // chain's worth of history arrives in roughly one round
        // trip's wall-clock.
        //
        // **Token allowlist (2026-06-09).** The indexer's `tokentx`
        // returns EVERY ERC-20 transfer involving the address —
        // including unsolicited "airdrop" spam from phishing
        // contracts (e.g. `gas711.com`-style impersonation
        // contracts). The user explicitly asked: "fetch only token
        // we've add or tokens user add. that's all." So we build
        // the allowed-contracts set as registry ∪ user's custom
        // tokens. Anything outside that set is dropped — its
        // counterparty isn't from a contract the user has chosen
        // to track. Native ETH/BNB transfers are unaffected; this
        // filter only gates the token path.
        let allowedContracts = Self.buildAllowedContracts(
            chain: chain,
            customContracts: customContracts
        )
        async let nativeEventsRaw = fetchNativeTransactions(address: address, limit: limit)
        async let tokenEventsRaw = fetchTokenTransfers(
            address: address,
            limit: limit,
            allowedContracts: allowedContracts
        )
        // Partial-result tolerance: one failing direction shouldn't
        // blank the other. But if BOTH fetches failed, throw so the
        // caller renders an error state instead of an empty history
        // that lies about "no activity."
        var nativeEvents: [TransactionEvent] = []
        var nativeFailure: Error?
        do {
            nativeEvents = try await nativeEventsRaw
        } catch {
            nativeFailure = error
            Self.log.error("Native history fetch failed on \(chain.rawValue, privacy: .public) for \(address, privacy: .private): \(String(describing: error), privacy: .public)")
        }
        var tokenEvents: [TransactionEvent] = []
        var tokenFailure: Error?
        do {
            tokenEvents = try await tokenEventsRaw
        } catch {
            tokenFailure = error
            Self.log.error("Token history fetch failed on \(chain.rawValue, privacy: .public) for \(address, privacy: .private): \(String(describing: error), privacy: .public)")
        }
        if let nativeFailure, tokenFailure != nil {
            throw nativeFailure
        }
        // Combine + sort + cap. With pagination, native and token
        // each fetch up to `limit` rows, so the combined set can
        // exceed the per-chain cap — when it does, the OLDEST rows
        // are the ones dropped, and the truncation is logged so it
        // is never silent (Rule #16 honesty).
        let combined = nativeEvents + tokenEvents
        if combined.count > limit {
            Self.log.info("Combined native+token history on \(chain.rawValue, privacy: .public) (\(combined.count, privacy: .public) rows) exceeds the \(limit, privacy: .public)-row full-history cap — oldest rows truncated")
        }
        return combined
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Routescan Etherscan-compatible indexer

    /// Routescan's universal Etherscan-compatible API base URL for
    /// each supported EVM chain. Returns nil for non-EVM chains (the
    /// switch statement is exhaustive at runtime — `default` covers
    /// the type-system requirement). 12 chains × 1 URL pattern:
    ///
    /// `https://api.routescan.io/v2/network/mainnet/evm/{chainId}/etherscan/api`
    private static func routescanAPIBase(for chain: SupportedChain) -> URL? {
        let chainID: Int
        switch chain {
        case .ethereum: chainID = 1
        case .optimism: chainID = 10
        case .bnbChain: chainID = 56
        case .opBNB:    chainID = 204
        case .polygon:  chainID = 137
        case .base:     chainID = 8453
        case .arbitrum: chainID = 42161
        case .avalanche: chainID = 43114
        case .scroll:   chainID = 534352
        case .zkSync:   chainID = 324
        case .celo:     chainID = 42220
        case .kavaEvm:  chainID = 2222
        default: return nil
        }
        return URL(string: "https://api.routescan.io/v2/network/mainnet/evm/\(chainID)/etherscan/api")
    }

    /// Build the lowercase set of contract addresses the user
    /// considers their own. Spam airdrops from contracts outside
    /// this set are dropped at parse time.
    private static func buildAllowedContracts(
        chain: SupportedChain,
        customContracts: [String]
    ) -> Set<String> {
        var allowed: Set<String> = []
        for token in EVMTokenRegistry.tokens(for: chain) {
            allowed.insert(token.contract.lowercased())
        }
        for contract in customContracts {
            allowed.insert(contract.lowercased())
        }
        return allowed
    }

    /// Sequentially page an Etherscan-compatible action until `limit`
    /// rows (the per-chain full-history cap), a short page (history
    /// exhausted), or a mid-pagination failure.
    ///
    /// **Full history (2026-06-13).** The pre-pagination code asked
    /// for a single `page=1&offset=limit` slice, so an imported
    /// wallet's older activity — including its historical balance
    /// peaks — never reached the database. Pages now run STRICTLY
    /// sequentially (never in parallel) so the indexer's free-tier
    /// rate limit is fed at a polite pace, and:
    ///
    /// - `RPCError.cancelled` propagates immediately between pages;
    /// - a failure on page 1 propagates (the caller decides the
    ///   fallback);
    /// - a failure on a LATER page keeps the rows already fetched —
    ///   the caller persists them, so a mid-pagination outage
    ///   degrades to "deep but incomplete" rather than empty (the
    ///   repository upsert is idempotent; the next scan resumes).
    private func runEtherscanQueryAllPages(
        action: String,
        address: String,
        limit: Int
    ) async throws(RPCError) -> [[String: Any]]? {
        let pageSize = min(limit, 100)
        var rows: [[String: Any]] = []
        var page = 1
        while rows.count < limit {
            let pageRows: [[String: Any]]?
            do {
                pageRows = try await runEtherscanQuery(
                    action: action,
                    address: address,
                    page: page,
                    pageSize: pageSize
                )
            } catch {
                if case .cancelled = error { throw error }
                if page == 1 { throw error }
                Self.log.warning("Indexer \(action, privacy: .public) page \(page, privacy: .public) failed on \(chain.rawValue, privacy: .public) — keeping \(rows.count, privacy: .public) rows already fetched: \(String(describing: error), privacy: .public)")
                break
            }
            guard let pageRows else {
                // No Routescan coverage — same answer on every page.
                return page == 1 ? nil : rows
            }
            rows.append(contentsOf: pageRows)
            if pageRows.count < pageSize { break } // history exhausted
            if rows.count >= limit {
                // Honest bound: RealRPCTransactionScanner.fullHistoryCap.
                Self.log.info("Indexer \(action, privacy: .public) on \(chain.rawValue, privacy: .public) hit the \(limit, privacy: .public)-row full-history cap — older rows not fetched this scan")
                break
            }
            page += 1
        }
        return rows
    }

    /// Run one Etherscan-compatible GET page, return the JSON array
    /// under `"result"`.
    ///
    /// **Failure ≠ no data (2026-06-11).** Returns `nil` only when
    /// the chain has no Routescan coverage (the caller may use a
    /// legacy fallback). Transport / HTTP failures — including the
    /// free tier's HTTP 429 and the Etherscan-style
    /// `result: "Max rate limit reached"` string body — now THROW a
    /// typed `RPCError`, so callers can distinguish "the indexer
    /// says there are no rows" from "the indexer is unreachable or
    /// throttling us" instead of silently cascading into the
    /// 100k-block `eth_getLogs` fallback at the worst moment.
    private func runEtherscanQuery(
        action: String,
        address: String,
        page: Int,
        pageSize: Int
    ) async throws(RPCError) -> [[String: Any]]? {
        guard let base = Self.routescanAPIBase(for: chain) else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "sort", value: "desc"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "offset", value: String(pageSize))
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw RPCError.cancelled }
            throw RPCError.network(urlError.localizedDescription)
        } catch {
            throw RPCError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                let retryAfter: Date
                if let header = http.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = TimeInterval(header) {
                    retryAfter = Date().addingTimeInterval(seconds)
                } else {
                    retryAfter = Date().addingTimeInterval(60)
                }
                throw RPCError.rateLimited(retryAfter: retryAfter)
            }
            if !(200..<300).contains(http.statusCode) {
                throw RPCError.invalidResponse("HTTP \(http.statusCode) from indexer")
            }
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RPCError.decodingFailed("Indexer body did not parse as a JSON object")
        }
        if let txs = root["result"] as? [[String: Any]] {
            // Includes the honest "no rows" shape: status "0",
            // message "No transactions found", result [].
            return txs
        }
        // Etherscan-compatible APIs signal throttling with HTTP 200
        // and `result: "Max rate limit reached"` — a STRING. A
        // string result is always a failure, never "no data."
        if let message = root["result"] as? String {
            if message.lowercased().contains("rate limit") {
                throw RPCError.rateLimited(retryAfter: Date().addingTimeInterval(60))
            }
            throw RPCError.invalidResponse("Indexer error: \(message)")
        }
        throw RPCError.decodingFailed("Indexer response missing `result` array")
    }

    // MARK: - Native ETH transactions (Blockscout indexer)

    /// Native EVM transactions (`Transfer(address,address,uint256)` is
    /// an ERC-20 event — native ETH/MATIC/BNB transfers don't emit
    /// logs, so `eth_getLogs` can't see them). We fetch these from a
    /// chain-specific Blockscout indexer instance — open-source,
    /// Etherscan-compatible API, no key required.
    ///
    /// Chains without a public Blockscout (`bnbChain`, `opBNB`,
    /// `avalanche` at the time of writing) return the empty array
    /// honestly — the ERC-20 path still works for those, just not
    /// native sends. Documented per chain in `blockscoutHost(for:)`.
    private func fetchNativeTransactions(address: String, limit: Int) async throws -> [TransactionEvent] {
        // **Indexer-first path (2026-06-09).** Routescan covers all
        // 12 EVM chains with the same Etherscan-compatible interface,
        // including the 3 chains (BSC, opBNB, Avalanche) that don't
        // have a public Blockscout instance. If the indexer returns
        // rows, parse them and return. Otherwise (empty result while
        // the chain has Blockscout, etc.) fall back to the prior
        // Blockscout-only path so we don't regress the 9 chains that
        // were working.
        //
        // **2026-06-11 — indexer failure handling.** For NATIVE
        // history the fallback is a single cheap GET against a
        // DIFFERENT host (Blockscout), so falling back while
        // Routescan throttles us is safe — unlike the token path's
        // `eth_getLogs` storm. Cancellation still propagates as
        // cancellation.
        // **2026-06-12 — distinguish "no rows" from "indexer failed".**
        // The previous `if let rows, !rows.isEmpty` fell through to the
        // Blockscout fallback whenever the indexer returned an honest
        // empty result (fresh address, watch-only, etc.) — wasting a
        // second network round-trip on a question we already had the
        // answer to. Now: a SUCCESSFUL empty result returns `[]`
        // directly; only a thrown indexer error falls back.
        let indexerRows: [[String: Any]]?
        do {
            indexerRows = try await runEtherscanQueryAllPages(action: "txlist", address: address, limit: limit)
        } catch {
            if case RPCError.cancelled = error { throw error }
            Self.log.error("Indexer txlist failed on \(chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            indexerRows = nil
        }
        if let rows = indexerRows {
            // Honest empty IS the answer — don't fall back.
            return parseNativeRows(rows, address: address, limit: limit)
        }
        // Fallback: legacy Blockscout `txlist`. Same shape, same
        // parser — so a single helper handles both paths. Paged
        // sequentially (2026-06-13) to the same full-history cap as
        // the indexer path; a failure after page 1 keeps the rows
        // already fetched rather than blanking the chain.
        guard let host = Self.blockscoutHost(for: chain) else { return [] }
        let pageSize = min(limit, 100)
        var rows: [[String: Any]] = []
        var page = 1
        while rows.count < limit {
            let urlString = "\(host)/api?module=account&action=txlist&address=\(address)&sort=desc&page=\(page)&offset=\(pageSize)"
            guard let url = URL(string: urlString) else { break }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw RPCError.cancelled
            } catch {
                if page == 1 { throw error }
                Self.log.warning("Blockscout txlist page \(page, privacy: .public) failed on \(chain.rawValue, privacy: .public) — keeping \(rows.count, privacy: .public) rows")
                break
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let txs = root["result"] as? [[String: Any]] else {
                break
            }
            rows.append(contentsOf: txs)
            if txs.count < pageSize { break } // history exhausted
            if rows.count >= limit {
                // Honest bound: RealRPCTransactionScanner.fullHistoryCap.
                Self.log.info("Blockscout txlist on \(chain.rawValue, privacy: .public) hit the \(limit, privacy: .public)-row full-history cap")
                break
            }
            page += 1
        }
        return parseNativeRows(rows, address: address, limit: limit)
    }

    /// Parse Etherscan-compatible `txlist` rows into
    /// `TransactionEvent`s. Shared between the indexer-first path
    /// (Routescan) and the Blockscout fallback — both APIs emit
    /// identical row shapes (Etherscan v1 standard), so this parser
    /// works for either. Honest failure: rows missing required
    /// fields are skipped, not nil'd-out, so a bad batch doesn't
    /// drop the whole history.
    private func parseNativeRows(
        _ rows: [[String: Any]],
        address: String,
        limit: Int
    ) -> [TransactionEvent] {
        var events: [TransactionEvent] = []
        events.reserveCapacity(rows.count)
        let lower = address.lowercased()
        for tx in rows.prefix(limit) {
            guard let hash = tx["hash"] as? String,
                  let from = tx["from"] as? String,
                  let to = tx["to"] as? String,
                  let valueStr = tx["value"] as? String,
                  let timestampStr = tx["timeStamp"] as? String,
                  let timestamp = Int64(timestampStr) else {
                continue
            }
            // Skip zero-value transactions (contract calls without
            // value) — they're not "received / sent" rows.
            let valueRaw = Decimal(string: valueStr) ?? 0
            if valueRaw == 0 { continue }
            // Native EVM uses 18 decimals.
            let amount = valueRaw / Self.scale(decimals: 18)
            let isError = (tx["isError"] as? String) == "1" || (tx["isError"] as? Int) == 1
            let blockStr = tx["blockNumber"] as? String
            let blockNumber = blockStr.flatMap { Int64($0) }
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestamp))

            let direction: TransactionDirection
            let counterparty: String
            if from.lowercased() == lower && to.lowercased() == lower {
                direction = .internal
                counterparty = ""
            } else if from.lowercased() == lower {
                direction = .outgoing
                counterparty = to
            } else if to.lowercased() == lower {
                direction = .incoming
                counterparty = from
            } else {
                continue
            }

            // Fee (only for outgoing): gasUsed × gasPrice in wei.
            var fee: Decimal? = nil
            if direction == .outgoing,
               let gasUsedStr = tx["gasUsed"] as? String,
               let gasUsed = Decimal(string: gasUsedStr),
               let gasPriceStr = tx["gasPrice"] as? String,
               let gasPrice = Decimal(string: gasPriceStr) {
                fee = (gasUsed * gasPrice) / Self.scale(decimals: 18)
            }

            events.append(TransactionEvent(
                chain: chain,
                address: address,
                txHash: hash,
                direction: direction,
                amount: amount,
                tokenSymbol: chain.ticker,
                tokenContract: nil,
                blockNumber: blockNumber,
                occurredAt: occurredAt,
                status: isError ? .failed : .confirmed,
                counterparty: counterparty,
                fee: fee
            ))
        }
        return events
    }

    /// Per-chain Blockscout host. Returns nil for chains without a
    /// usable public instance — those chains get ERC-20 history via
    /// `eth_getLogs` (the `fetchTokenTransfers` path) but no native
    /// send history. Honest in code; the UI's empty-state stays
    /// truthful when one chain has no usable indexer.
    private static func blockscoutHost(for chain: SupportedChain) -> String? {
        switch chain {
        case .ethereum:   return "https://eth.blockscout.com"
        case .arbitrum:   return "https://arbitrum.blockscout.com"
        case .base:       return "https://base.blockscout.com"
        case .optimism:   return "https://optimism.blockscout.com"
        case .scroll:     return "https://scroll.blockscout.com"
        case .zkSync:     return "https://zksync.blockscout.com"
        case .polygon:    return "https://polygon.blockscout.com"
        case .celo:       return "https://celo.blockscout.com"
        case .kavaEvm:    return "https://kava-evm.blockscout.com"
        // No public Blockscout instances we trust at time of writing:
        // BSC (bnbChain) — official explorer is bscscan.com (key-only)
        // opBNB — same
        // Avalanche C — official explorer snowtrace.io (key-only)
        case .bnbChain, .opBNB, .avalanche: return nil
        // Non-EVM cases never reach this function via the switch in
        // RealRPCTransactionScanner; included only for exhaustiveness.
        default: return nil
        }
    }

    // MARK: - ERC-20 transfers (indexer-first, eth_getLogs fallback)

    /// **Primary path (2026-06-09).** Routescan's `tokentx`
    /// Etherscan-compatible endpoint returns indexed ERC-20 transfers
    /// for the address in a single HTTP round trip. Works on all 12
    /// EVM chains (Routescan covers chainIds 1, 10, 56, 137, 204,
    /// 324, 2222, 8453, 42161, 42220, 43114, 534352). Each row
    /// already carries `tokenSymbol`, `tokenDecimal`, `contractAddress`,
    /// `timeStamp`, and the `from`/`to` pair — no follow-up
    /// `eth_getBlockByNumber` needed for timestamps and no
    /// `EVMTokenRegistry` lookup required for symbol/decimals on
    /// arbitrary contracts (long-tail tokens just work).
    ///
    /// **Fallback path.** If the indexer is unreachable or returns
    /// empty, fall through to `fetchTokenTransfersViaLogs` — the
    /// prior `eth_getLogs` implementation, retained verbatim so we
    /// don't regress chains where the indexer happens to be down.
    private func fetchTokenTransfers(
        address: String,
        limit: Int,
        allowedContracts: Set<String>
    ) async throws -> [TransactionEvent] {
        // **2026-06-11 — indexer failure ≠ "no data".** An HTTP 429
        // from Routescan's free tier (or any transport failure) used
        // to be indistinguishable from "no token transfers" here and
        // silently cascaded into `fetchTokenTransfersViaLogs` — a
        // 100k-block `eth_getLogs` sweep plus per-block timestamp
        // round-trips, the heaviest possible queries fired precisely
        // while we're already being throttled. Indexer FAILURE now
        // propagates to the caller (`fetch` tolerates one failed
        // direction); only an honest empty / no-coverage result
        // falls through to the logs path.
        //
        // **2026-06-12 — empty IS the answer.** An indexer that
        // returns `result: []` for an address with no token transfers
        // is the honest answer; falling back to the 100k-block
        // `eth_getLogs` sweep just to confirm the empty result wastes
        // RPC quota on a question we already have the answer to. Only
        // the `nil` case (no coverage at all — chain not in
        // Routescan's table) falls back.
        if let rows = try await runEtherscanQueryAllPages(action: "tokentx", address: address, limit: limit) {
            return parseTokenTxRows(
                rows,
                address: address,
                limit: limit,
                allowedContracts: allowedContracts
            )
        }
        return try await fetchTokenTransfersViaLogs(
            address: address,
            limit: limit,
            allowedContracts: allowedContracts
        )
    }

    /// Parse Etherscan-compatible `tokentx` rows. Each row carries
    /// `tokenSymbol`, `tokenDecimal`, `contractAddress`, `timeStamp`,
    /// `from`, `to`, `value` — so we get full event reconstruction
    /// without a separate registry lookup or block-timestamp call.
    /// Unknown / long-tail tokens use whatever symbol the issuer
    /// declared on-chain (honest: that's what the explorer shows
    /// too).
    private func parseTokenTxRows(
        _ rows: [[String: Any]],
        address: String,
        limit: Int,
        allowedContracts: Set<String>
    ) -> [TransactionEvent] {
        var events: [TransactionEvent] = []
        events.reserveCapacity(rows.count)
        let lower = address.lowercased()
        for tx in rows {
            guard let hash = tx["hash"] as? String,
                  let from = tx["from"] as? String,
                  let to = tx["to"] as? String,
                  let valueStr = tx["value"] as? String,
                  let timestampStr = tx["timeStamp"] as? String,
                  let timestamp = Int64(timestampStr),
                  let contractAddr = tx["contractAddress"] as? String else {
                continue
            }
            // **Allowlist gate (2026-06-09).** Drop the row if it
            // came from a contract the user doesn't track. Done
            // BEFORE the prefix(limit) so spam doesn't crowd out
            // legitimate rows. Empty allowlist → admit nothing
            // (defensive; never happens once registry has entries).
            if !allowedContracts.contains(contractAddr.lowercased()) {
                continue
            }
            if events.count >= limit { break }
            let valueRaw = Decimal(string: valueStr) ?? 0
            if valueRaw == 0 { continue }

            // Decimals: prefer the indexer's declared value (always
            // present for ERC-20). If somehow missing or unparseable,
            // fall back to the registry, then 18.
            let decimals: Int
            if let d = tx["tokenDecimal"] as? String, let parsed = Int(d) {
                decimals = parsed
            } else if let d = tx["tokenDecimal"] as? Int {
                decimals = d
            } else if let registryTok = EVMTokenRegistry.tokens(for: chain)
                .first(where: { $0.contract.lowercased() == contractAddr.lowercased() }) {
                decimals = registryTok.decimals
            } else {
                decimals = 18
            }
            // **2026-06-11 — validate indexer-supplied decimals.**
            // `tokenDecimal` is untrusted indexer data: a negative
            // value trapped `scale(decimals:)`'s range loop (fatal
            // crash mid-refresh) and a huge value spun it for
            // minutes. `Decimal` carries ~38 significant digits and
            // no real token exceeds that; rows outside the sane
            // range are rejected, never scaled.
            guard (0...38).contains(decimals) else { continue }
            let amount = valueRaw / Self.scale(decimals: decimals)

            // Symbol: prefer the indexer's declared value. Fall back
            // to registry, then to a short contract hash (honest;
            // the user can verify the contract via a block explorer).
            let symbol: String
            if let s = (tx["tokenSymbol"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                symbol = s
            } else if let registryTok = EVMTokenRegistry.tokens(for: chain)
                .first(where: { $0.contract.lowercased() == contractAddr.lowercased() }) {
                symbol = registryTok.symbol
            } else {
                symbol = Self.shortContract(contractAddr)
            }

            let direction: TransactionDirection
            let counterparty: String
            if from.lowercased() == lower && to.lowercased() == lower {
                direction = .internal
                counterparty = ""
            } else if to.lowercased() == lower {
                direction = .incoming
                counterparty = from
            } else if from.lowercased() == lower {
                direction = .outgoing
                counterparty = to
            } else {
                // Neither side is the wallet — an indexer row that
                // doesn't involve this address. Mirrors the
                // parseNativeRows guard; never default to outgoing.
                continue
            }

            let blockNumber: Int64? = {
                if let s = tx["blockNumber"] as? String { return Int64(s) }
                if let i = tx["blockNumber"] as? Int { return Int64(i) }
                return nil
            }()

            events.append(TransactionEvent(
                chain: chain,
                address: address,
                txHash: hash,
                direction: direction,
                amount: amount,
                tokenSymbol: symbol,
                tokenContract: contractAddr,
                blockNumber: blockNumber,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                status: .confirmed,
                counterparty: counterparty,
                fee: nil
            ))
        }
        return events
    }

    /// **Fallback path.** Original `eth_getLogs` implementation,
    /// retained so chains where the indexer is briefly unreachable
    /// still surface recent activity. Slower (5–30s per chain) and
    /// bounded by `scanBlockRange`, but works against any standard
    /// JSON-RPC endpoint without an indexer.
    private func fetchTokenTransfersViaLogs(
        address: String,
        limit: Int,
        allowedContracts: Set<String>
    ) async throws -> [TransactionEvent] {
        let latestBlock = try await fetchLatestBlock()
        let fromBlock = max(0, latestBlock - Self.scanBlockRange)
        let fromHex = "0x" + String(fromBlock, radix: 16)
        let toHex = "0x" + String(latestBlock, radix: 16)

        // Pad the user's address to 32 bytes (66 hex chars including
        // "0x") for topic matching — EVM logs encode topics as 32-byte
        // words, and `from`/`to` are indexed parameters so they live in
        // topics not data.
        let padded = Self.padTopic(address)

        // **2026-06-09 — contract-scoped fallback.** Pre-known
        // contract addresses (registry ∪ user's custom tokens) get
        // passed into the JSON-RPC `address` filter so the node
        // only scans logs from THESE contracts, not every contract
        // on the chain. The same allowlist also gates the parser
        // below — defense in depth in case the node ignores the
        // `address` filter for some reason.
        let contracts: [String]? = allowedContracts.isEmpty
            ? nil
            : Array(allowedContracts)

        async let incomingLogs = fetchLogs(
            from: fromHex, to: toHex,
            fromTopic: nil, toTopic: padded,
            contractAddresses: contracts
        )
        async let outgoingLogs = fetchLogs(
            from: fromHex, to: toHex,
            fromTopic: padded, toTopic: nil,
            contractAddresses: contracts
        )

        // Catch each direction independently — one failing log fetch
        // must not cancel the other. Throw only when BOTH failed,
        // so the caller can distinguish "no logs" from "fetch broke."
        let incoming: [[String: Any]]?
        do {
            incoming = try await incomingLogs
        } catch {
            Self.log.error("Incoming eth_getLogs failed on \(chain.rawValue, privacy: .public) for \(address, privacy: .private): \(String(describing: error), privacy: .public)")
            incoming = nil
        }
        let outgoing: [[String: Any]]?
        do {
            outgoing = try await outgoingLogs
        } catch {
            Self.log.error("Outgoing eth_getLogs failed on \(chain.rawValue, privacy: .public) for \(address, privacy: .private): \(String(describing: error), privacy: .public)")
            outgoing = nil
        }
        if incoming == nil && outgoing == nil {
            throw RPCError.allEndpointsFailed(chain)
        }
        let allLogs = (incoming ?? []) + (outgoing ?? [])
        let sorted = allLogs.sorted { (a, b) in
            let aBlock = a["blockNumber"] as? String ?? "0x0"
            let bBlock = b["blockNumber"] as? String ?? "0x0"
            let aInt = Int64(aBlock.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
            let bInt = Int64(bBlock.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
            return aInt > bInt
        }
        let trimmed = Array(sorted.prefix(limit))

        // Block-timestamp cache so we don't re-fetch the same block N
        // times when the address has many logs in the same block.
        var blockTimes: [Int64: Date] = [:]
        var events: [TransactionEvent] = []
        events.reserveCapacity(trimmed.count)

        let lower = address.lowercased()
        for log in trimmed {
            guard let topics = log["topics"] as? [String], topics.count >= 3,
                  let dataHex = log["data"] as? String,
                  let txHash = log["transactionHash"] as? String,
                  let blockHex = log["blockNumber"] as? String,
                  let contractAddr = log["address"] as? String else {
                continue
            }
            // Allowlist re-check — some providers ignore the
            // JSON-RPC `address` filter and return wildcard logs.
            // Don't ship those rows.
            if !allowedContracts.isEmpty,
               !allowedContracts.contains(contractAddr.lowercased()) {
                continue
            }
            let blockNum = Int64(blockHex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
            let fromAddr = Self.unpadTopic(topics[1])
            let toAddr = Self.unpadTopic(topics[2])
            let amountRaw = Self.decimalFromHex(dataHex) ?? 0

            let direction: TransactionDirection
            let counterparty: String
            if fromAddr.lowercased() == lower && toAddr.lowercased() == lower {
                direction = .internal
                counterparty = ""
            } else if toAddr.lowercased() == lower {
                direction = .incoming
                counterparty = fromAddr
            } else if fromAddr.lowercased() == lower {
                direction = .outgoing
                counterparty = toAddr
            } else {
                // Neither topic matches the wallet — a provider that
                // ignored the topic filter. Skip; never default to
                // outgoing.
                continue
            }

            // Resolve timestamp — cached per block to keep traffic
            // bounded.
            let occurredAt: Date
            if let cached = blockTimes[blockNum] {
                occurredAt = cached
            } else if let fetched = try? await fetchBlockTimestamp(blockNumber: blockNum) {
                blockTimes[blockNum] = fetched
                occurredAt = fetched
            } else {
                occurredAt = Date()
            }

            // Look up token symbol + decimals from the registry by
            // contract address. Unknown contracts render the short
            // contract hash as the symbol (honest — the user can
            // verify the contract via a block explorer if needed).
            let token = EVMTokenRegistry.tokens(for: chain)
                .first { $0.contract.lowercased() == contractAddr.lowercased() }
            let symbol = token?.symbol ?? Self.shortContract(contractAddr)
            let decimals = token?.decimals ?? 18
            let amount = amountRaw / Self.scale(decimals: decimals)

            events.append(TransactionEvent(
                chain: chain,
                address: address,
                txHash: txHash,
                direction: direction,
                amount: amount,
                tokenSymbol: symbol,
                tokenContract: contractAddr,
                blockNumber: blockNum,
                occurredAt: occurredAt,
                status: .confirmed,
                counterparty: counterparty,
                fee: nil
            ))
        }
        return events
    }

    // MARK: - JSON-RPC plumbing

    private func fetchLatestBlock() async throws -> Int64 {
        let hexBlock = try await client.callJSONString(
            chain: chain,
            method: "eth_blockNumber",
            params: []
        )
        let stripped = hexBlock.hasPrefix("0x") ? String(hexBlock.dropFirst(2)) : hexBlock
        return Int64(stripped, radix: 16) ?? 0
    }

    /// `eth_getLogs` with topic filter on the Transfer event + one of
    /// from/to. `nil` for the other topic = "any address."
    ///
    /// **2026-06-09 — contract scoping.** When `contractAddresses`
    /// is non-empty, the JSON-RPC `address` field is set so the node
    /// only walks logs from those contracts. A typical node has to
    /// scan billions of log entries across every contract in the
    /// block range; restricting to ~30 registry contracts cuts that
    /// to a few million → 10–50× faster per call. Per the JSON-RPC
    /// spec `address` accepts either a single string or an array
    /// (we use the array form so a single call covers every known
    /// contract for the chain).
    private func fetchLogs(
        from fromBlock: String,
        to toBlock: String,
        fromTopic: String?,
        toTopic: String?,
        contractAddresses: [String]? = nil
    ) async throws -> [[String: Any]] {
        // JSON-RPC topics array accepts strings and JSON null
        // (wildcard). `[String?]` serializes `nil` as JSON null via
        // `JSONSerialization`. The whole filter is `[String: Sendable]`
        // so it satisfies `RPCClient.callJSONResultData`'s
        // `[Sendable]` parameter contract.
        let topics: [String?] = [Self.transferTopic, fromTopic, toTopic]
        var filter: [String: Sendable] = [
            "fromBlock": fromBlock,
            "toBlock": toBlock,
            "topics": topics,
        ]
        // **Scope to known contracts when available.** Without
        // this, the node walks every ERC-20 Transfer event in the
        // block range — slow. With it, the node restricts the scan
        // to the supplied contracts. Empty array = wildcard
        // (`address: []` would actually break some providers, so
        // we omit the field instead). Lowercased for consistency
        // across providers — some nodes are case-sensitive.
        if let contracts = contractAddresses, !contracts.isEmpty {
            filter["address"] = contracts.map { $0.lowercased() }
        }
        let data = try await client.callJSONResultData(
            chain: chain,
            method: "eth_getLogs",
            params: [filter]
        )
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private func fetchBlockTimestamp(blockNumber: Int64) async throws -> Date {
        let hexBlock = "0x" + String(blockNumber, radix: 16)
        let data = try await client.callJSONResultData(
            chain: chain,
            method: "eth_getBlockByNumber",
            params: [hexBlock, false]
        )
        guard let block = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampHex = block["timestamp"] as? String else {
            return Date()
        }
        let stripped = timestampHex.hasPrefix("0x") ? String(timestampHex.dropFirst(2)) : timestampHex
        guard let ts = Int64(stripped, radix: 16) else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    // MARK: - Helpers

    private static func padTopic(_ address: String) -> String {
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        let padded = String(repeating: "0", count: max(0, 64 - stripped.count)) + stripped
        return "0x" + padded.lowercased()
    }

    private static func unpadTopic(_ topic: String) -> String {
        let stripped = topic.hasPrefix("0x") ? String(topic.dropFirst(2)) : topic
        // Last 40 hex chars = 20-byte EVM address.
        if stripped.count >= 40 {
            return "0x" + String(stripped.suffix(40))
        }
        return topic
    }

    private static func shortContract(_ addr: String) -> String {
        let stripped = addr.hasPrefix("0x") ? String(addr.dropFirst(2)) : addr
        if stripped.count >= 10 {
            return "0x" + String(stripped.prefix(4)) + "…" + String(stripped.suffix(4))
        }
        return addr
    }

    private static func scale(decimals: Int) -> Decimal {
        // Defensive clamp (2026-06-11): a negative count traps the
        // range loop ("Range requires lowerBound <= upperBound"), a
        // huge one hangs it. Callers validate their inputs; this is
        // the backstop so no future caller can crash or stall it.
        let clamped = min(max(decimals, 0), 38)
        var result = Decimal(1)
        for _ in 0..<clamped { result *= 10 }
        return result
    }

    /// Parse a hex string like `"0x1234..."` into a `Decimal`. Same
    /// shape as `EVMChainAdapter`'s private helper — duplicated here
    /// because that extension is `fileprivate` to its file. Used for
    /// the ERC-20 `Transfer` event's `data` field which is the
    /// 32-byte uint256 amount in hex.
    private static func decimalFromHex(_ hexString: String) -> Decimal? {
        var hex = hexString
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        if hex.isEmpty { return .zero }
        var result = Decimal(0)
        let sixteen = Decimal(16)
        for ch in hex {
            guard let digit = ch.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(digit)
        }
        return result
    }
}
