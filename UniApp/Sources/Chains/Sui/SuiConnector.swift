import Foundation
import OSLog

/// **Sui connector — the `suix_*` JSON-RPC reference for the fleet's
/// Move-VM chain.**
///
/// A FULLY INDEPENDENT module for `.sui`: its own `suix_getBalance`
/// native read and its own dual-direction `suix_queryTransactionBlocks`
/// history (one cursor-paged scan filtered by `FromAddress`, one by
/// `ToAddress`, merged + deduped). It owns its request shapes + parsing
/// end-to-end and dispatches every call through the shared `RPCClient`
/// actor via `callJSONResultData` (rotation + rate-limit +
/// circuit-breaking + ConcurrencyGate) against the registered endpoints
/// `RPCRegistry.endpoints(for: .sui)` (sui.io fullnode primary,
/// BlockVision fallback — one JSON-RPC shape covers both). Never a raw
/// `URLSession`.
///
/// **Ported verbatim-faithful** from `SuiChainAdapter.fetchAccountSummary`
/// (balance) and `LongTailTransactionAdapters.fetchSui` /
/// `querySuiBlocks` / `appendSuiEvents` (history): same
/// `suix_getBalance` → `result.totalBalance` MIST string, same 9-decimal
/// scaling (mistPerSui = 10^9), same `suix_queryTransactionBlocks`
/// filter/options/cursor envelope, same `pageSize = min(limit, 50)`
/// QUERY_MAX_RESULT_LIMIT clamp, same `balanceChanges` SUI-coin parsing
/// keyed on `AddressOwner == address`, same digest dedup +
/// both-directions ⇒ `.internal` self-send reclassification.
///
/// **Sui has no fungible-token layer Aperture tracks** — the native
/// coin is the only asset the scanner reads for this chain (no `.sui`
/// branch exists in `RealRPCBalanceScanner`'s token dispatch), so
/// `fetchTokenBalances` returns `[]` honestly (Rule #16). The parameter
/// is kept for the uniform `ChainConnector` signature.
struct SuiConnector: ChainConnector {
    let chain: SupportedChain = .sui
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "sui-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native SUI balance + used-address flag via `suix_getBalance`.
    /// Ported from `SuiChainAdapter.fetchAccountSummary`.
    ///
    /// The result envelope carries `totalBalance` as a decimal STRING in
    /// MIST (Sui's smallest unit) → divided by 10^9. `isUsed` keys on
    /// `balance > 0`: Sui has no nonce/sequence the balance read exposes,
    /// so a positive balance is the honest "this address holds funds"
    /// signal (an emptied account reads as unused here, matching the
    /// existing adapter exactly).
    ///
    /// Typed throws per the contract: `RPCError.cancelled` propagates;
    /// an HTTP 404 (unfunded account on a fullnode that 404s rather than
    /// returning a zero envelope) maps to a zero summary, never a throw.
    /// A malformed/missing `totalBalance` is treated as zero — the
    /// fullnode returns `"0"` for fresh accounts, so a parse miss is the
    /// same honest zero state rather than an alarm.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data: Data
        do {
            data = try await client.callJSONResultData(
                chain: chain, method: "suix_getBalance", params: [address]
            )
        } catch {
            if case .cancelled = error { throw error }
            if RPCError.isHTTPNotFound(error) {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            throw error
        }
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let totalStr = dict["totalBalance"] as? String,
              let mist = Decimal(string: totalStr) else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        let sui = mist / Self.mistPerSui
        return ChainAccountSummary(nativeBalance: sui, isUsed: sui > 0)
    }

    // MARK: - Token balances

    /// Sui carries no fungible-token layer Aperture tracks (no `.sui`
    /// branch in `RealRPCBalanceScanner`'s token dispatch) — the native
    /// coin is the only asset. Returns `[]` honestly (Rule #16).
    /// `customContracts` is unused but kept for the uniform
    /// `ChainConnector` signature.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    // MARK: - Transaction history

    /// Sui's `QUERY_MAX_RESULT_LIMIT` — server clamps every page here.
    private static let pageMax = 50

    /// Recent SUI history via two `suix_queryTransactionBlocks` scans —
    /// one filtered `FromAddress` (outgoing), one `ToAddress` (incoming)
    /// — merged, deduped by digest, and capped at `limit`. Ported from
    /// `LongTailTransactionAdapters.fetchSui`.
    ///
    /// **Dedup + self-send.** A transaction where the wallet is both
    /// sender and recipient is returned by BOTH scans; concatenating
    /// blindly would double-render it. The merge dedupes by digest and
    /// reclassifies a digest present in both result sets as `.internal`
    /// (self-send) with an empty counterparty.
    ///
    /// `customContracts` is unused (the SUI-coin filter already scopes
    /// the rows) but kept for the uniform `ChainConnector` signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        async let outgoingRaw = queryBlocks(address: address, asSender: true, limit: limit)
        async let incomingRaw = queryBlocks(address: address, asSender: false, limit: limit)
        let outgoing = (try? await outgoingRaw) ?? []
        let incoming = (try? await incomingRaw) ?? []
        try Task.checkCancellation()

        let outgoingDigests = Set(outgoing.map(\.txHash))
        let incomingDigests = Set(incoming.map(\.txHash))
        var seen = Set<String>()
        var combined: [TransactionEvent] = []
        combined.reserveCapacity(outgoing.count + incoming.count)
        for event in outgoing + incoming {
            guard seen.insert(event.txHash).inserted else { continue }
            if outgoingDigests.contains(event.txHash) && incomingDigests.contains(event.txHash) {
                combined.append(TransactionEvent(
                    chain: event.chain,
                    address: event.address,
                    txHash: event.txHash,
                    direction: .internal,
                    amount: event.amount,
                    tokenSymbol: event.tokenSymbol,
                    tokenContract: event.tokenContract,
                    blockNumber: event.blockNumber,
                    occurredAt: event.occurredAt,
                    status: event.status,
                    counterparty: "",
                    fee: event.fee
                ))
            } else {
                combined.append(event)
            }
        }
        return combined
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    /// **Full history.** `suix_queryTransactionBlocks` pages with a
    /// cursor (the response carries `nextCursor` + `hasNextPage`); the
    /// server-side page maximum is 50. Pages run sequentially through the
    /// rate-limited `RPCClient` until `limit` events, `hasNextPage ==
    /// false`, or a mid-pagination failure — which keeps the pages
    /// already fetched (`RPCError.cancelled` still propagates
    /// immediately). Ported from `querySuiBlocks`.
    private func queryBlocks(address: String, asSender: Bool, limit: Int) async throws -> [TransactionEvent] {
        let filterKey = asSender ? "FromAddress" : "ToAddress"
        let filter: [String: Sendable] = [filterKey: address]
        let options: [String: Sendable] = [
            "showInput": true,
            "showEffects": true,
            "showEvents": true,
            "showBalanceChanges": true,
        ]
        let query: [String: Sendable] = [
            "filter": filter,
            "options": options,
        ]
        let pageSize = min(limit, Self.pageMax)
        var events: [TransactionEvent] = []
        var cursor: String?
        while events.count < limit {
            let cursorParam: Sendable = cursor ?? NSNull()
            let data: Data
            do {
                // The trailing `true` requests descending order
                // (newest-first), matching the feed's sort.
                data = try await client.callJSONResultData(
                    chain: chain,
                    method: "suix_queryTransactionBlocks",
                    params: [query, cursorParam, pageSize, true]
                )
            } catch {
                if case .cancelled = error { throw error }
                if cursor == nil { throw error }
                Self.log.warning("Sui \(filterKey, privacy: .public) page failed — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let blocks = root["data"] as? [[String: Any]] else {
                break
            }
            appendEvents(from: blocks, address: address, limit: limit, into: &events)
            let hasNextPage = (root["hasNextPage"] as? Bool) ?? false
            guard hasNextPage,
                  let nextCursor = root["nextCursor"] as? String,
                  nextCursor != cursor else { break }
            cursor = nextCursor
            if events.count >= limit {
                Self.log.info("Sui \(filterKey, privacy: .public) history hit the \(limit, privacy: .public)-event cap — older rows not fetched this scan")
            }
        }
        return events
    }

    /// Parse one `suix_queryTransactionBlocks` page, appending events
    /// until `limit`. Ported verbatim from `appendSuiEvents`.
    ///
    /// Each block's `balanceChanges` is scanned for the `0x2::sui::SUI`
    /// coin entry whose `owner.AddressOwner` equals this address; that
    /// signed MIST delta gives direction (negative ⇒ outgoing) and the
    /// absolute SUI amount (÷ 10^9). One event per block is emitted — the
    /// feed shows the net SUI movement, not every internal coin object.
    private func appendEvents(
        from blocks: [[String: Any]],
        address: String,
        limit: Int,
        into events: inout [TransactionEvent]
    ) {
        events.reserveCapacity(min(events.count + blocks.count, limit))
        for block in blocks {
            if events.count >= limit { break }
            guard let digest = block["digest"] as? String,
                  let timestampMsStr = block["timestampMs"] as? String,
                  let timestampMs = Int64(timestampMsStr) else {
                continue
            }
            let effects = block["effects"] as? [String: Any] ?? [:]
            let statusEnvelope = effects["status"] as? [String: Any] ?? [:]
            let statusStr = (statusEnvelope["status"] as? String) ?? "success"
            let status: TransactionStatus = statusStr == "success" ? .confirmed : .failed

            let balanceChanges = block["balanceChanges"] as? [[String: Any]] ?? []
            for change in balanceChanges {
                guard let coinType = change["coinType"] as? String,
                      coinType == "0x2::sui::SUI",
                      let amountStr = change["amount"] as? String,
                      let amountInt = Int64(amountStr),
                      let ownerEnvelope = change["owner"] as? [String: Any],
                      let ownerAddress = ownerEnvelope["AddressOwner"] as? String,
                      ownerAddress == address else {
                    continue
                }
                let absAmount = abs(Decimal(amountInt)) / Self.mistPerSui
                let direction: TransactionDirection = amountInt < 0 ? .outgoing : .incoming
                let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)

                events.append(TransactionEvent(
                    chain: chain,
                    address: address,
                    txHash: digest,
                    direction: direction,
                    amount: absAmount,
                    tokenSymbol: chain.ticker,
                    tokenContract: nil,
                    blockNumber: nil,
                    occurredAt: occurredAt,
                    status: status,
                    counterparty: "",
                    fee: nil
                ))
                break // one event per block is enough for the feed.
            }
        }
    }

    /// 10^9 — Sui's smallest unit is the MIST.
    private static let mistPerSui: Decimal = 1_000_000_000
}
