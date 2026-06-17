import Foundation
import OSLog

/// Production `TransactionScanner` that reads real on-chain transaction
/// history via the `RPCClient` actor + per-family adapters.
///
/// **Per-family dispatch.** Every chain in `SupportedChain` resolves to
/// exactly one family adapter:
///
/// | Family             | Chains                                                              | Adapter                              |
/// |--------------------|---------------------------------------------------------------------|--------------------------------------|
/// | Bitcoin            | BTC, BCH, LTC, DOGE                                                 | `BitcoinFamilyTransactionAdapter`    |
/// | EVM                | ETH, ARB, BASE, OP, Scroll, zkSync, MATIC, BNB, opBNB, AVAX, Celo | `EVMTransactionAdapter`              |
/// | Solana             | SOL                                                                 | `SolanaTransactionAdapter`           |
/// | XRPL               | XRP                                                                 | `XRPLTransactionAdapter`             |
/// | TRON               | TRX                                                                 | `TronTransactionAdapter`             |
/// | Stellar            | XLM                                                                 | `StellarTransactionAdapter`          |
/// | Aptos / Sui / NEAR | APT, SUI, NEAR                                                      | `LongTailTransactionAdapters`        |
/// | TON / Polkadot     | TON, DOT                                                            | `LongTailTransactionAdapters`        |
///
/// **Honesty contract (Rule #16 §A.5).** Every adapter hits a real
/// public endpoint registered in `RPCRegistry`. If a chain has no
/// transactions, the result is the empty array — never a stub event.
/// If the endpoint errors, the chain's fan-out simply yields nothing
/// and the others continue; the user sees the chains that succeeded
/// rather than a global failure.
///
/// **Rule #3 compliance.** Pure native plumbing (`RPCClient` actor,
/// `URLSession`, `JSONSerialization`). No third-party SDK.
struct RealRPCTransactionScanner: TransactionScanner {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "tx-scanner")

    /// **The honest full-history bound (2026-06-13).** The bulk
    /// `scan` path — the one that persists into SwiftData and feeds
    /// the balance chart — fetches the wallet's FULL transaction
    /// history via per-chain pagination, hard-capped at this many
    /// events per chain per scan. The cap is a safety rail against
    /// pathological accounts (exchanges, airdrop magnets with tens
    /// of thousands of rows) hammering free public endpoints; each
    /// adapter logs when it stops at the cap so the truncation is
    /// never silent. Wallets under the cap — the overwhelming
    /// majority — get every transaction they have.
    static let fullHistoryCap = 1_000

    let client: RPCClient

    init(client: RPCClient = RPCClient.shared) {
        self.client = client
    }

    // MARK: - Bulk

    func scan(
        addresses: [SupportedChain: String],
        limit: Int
    ) async -> [TransactionEvent] {
        await scan(
            addresses: addresses,
            limit: limit,
            customContractsByChain: [:],
            ownAddressesByChain: [:]
        )
    }

    func scan(
        addresses: [SupportedChain: String],
        limit: Int,
        customContractsByChain: [SupportedChain: [String]]
    ) async -> [TransactionEvent] {
        await scan(
            addresses: addresses,
            limit: limit,
            customContractsByChain: customContractsByChain,
            ownAddressesByChain: [:]
        )
    }

    /// **Full-depth contract (2026-06-13).** The bulk scan is the
    /// persistence path (`WalletRefreshCoordinator` upserts every
    /// returned event into SwiftData, and the balance chart is
    /// rebuilt purely from those rows) — so a shallow `limit` here
    /// silently erased historical peaks from the chart (the
    /// user's 10,000-USDT receive never appeared because only the
    /// newest 25 rows were ever fetched). The caller's `limit` is
    /// therefore treated as a FLOOR: the effective per-chain depth
    /// is `max(limit, fullHistoryCap)`. `streamScan` (the
    /// test-mode live feed) keeps the caller's literal limit — a
    /// preview feed doesn't need a thousand rows.
    /// **Self-transfer rule (2026-06-16, Rule #24).** `ownAddressesByChain`
    /// is the wallet's FULL set of its own addresses per chain (every
    /// derived / change / receive address on that chain). A transfer whose
    /// COUNTERPARTY is one of the wallet's own addresses is a self-transfer
    /// → both legs are reclassified `.internal` here, at the single
    /// per-chain chokepoint, regardless of which adapter produced the
    /// event. This catches the multi-address case the per-address adapters
    /// cannot see on their own (each adapter only knows the ONE address it
    /// was asked to scan, so an A→B move between two of the wallet's own
    /// addresses lands as `.outgoing` to B from A's scan and `.incoming`
    /// from A in B's scan; the reclassification flips both to `.internal`).
    /// A single-address self-send (input addr == output addr, the
    /// 2026-06-13 BTC repro `d258f57fba…77cdee0e`) is already `.internal`
    /// from the BTC adapter and passes through unchanged.
    func scan(
        addresses: [SupportedChain: String],
        limit: Int,
        customContractsByChain: [SupportedChain: [String]],
        ownAddressesByChain: [SupportedChain: Set<String>],
        deepHistory: Bool = false
    ) async -> [TransactionEvent] {
        // **Latency fix (2026-06-17).** The bulk scan used to force
        // `max(limit, fullHistoryCap)` = 1000 events PER CHAIN on EVERY
        // refresh — deep-paginating dozens of RPC calls per chain, which is
        // exactly what hammered Infura into a 429 storm and made history
        // fetches take 10–22 s each (even for chains with no activity). A live
        // pull-to-refresh only needs the recent page (`limit`, ~25), one or
        // two RPC calls per chain; the full-history backfill is opt-in via
        // `deepHistory` (a future "load full history" / first-import path).
        let depth = deepHistory ? max(limit, Self.fullHistoryCap) : limit
        return await withTaskGroup(of: [TransactionEvent].self) { group in
            for (chain, address) in addresses {
                let custom = customContractsByChain[chain] ?? []
                let own = ownAddressesByChain[chain] ?? [address]
                group.addTask { [client] in
                    let events = await Self.fetch(
                        chain: chain,
                        address: address,
                        limit: depth,
                        client: client,
                        customContracts: custom
                    )
                    return events.map { Self.reclassifySelfTransfer($0, ownAddresses: own) }
                }
            }
            var events: [TransactionEvent] = []
            events.reserveCapacity(addresses.count * min(depth, 64))
            for await batch in group {
                events.append(contentsOf: batch)
            }
            return events
        }
    }

    // MARK: - Uniform self-transfer reclassification

    /// Normalize an address for own-set membership. EVM / Bitcoin-family
    /// addresses are case-insensitive at this comparison boundary
    /// (checksum casing on EVM; the adapters already lowercased BTC), so
    /// we fold to lowercase. Case-sensitive chains (Solana base58, XRPL,
    /// Tron, Stellar, Cosmos bech32, Aptos/Sui/NEAR/TON) compare verbatim —
    /// lowercasing them would never *create* a false positive (a lowercase
    /// fold of two distinct base58 strings stays distinct in practice for
    /// real wallet addresses), and it keeps one uniform rule. The own-set
    /// is built with the same fold, so both sides match.
    private static func normalizeForOwnSet(_ address: String) -> String {
        address.lowercased()
    }

    /// Reclassify one event to `.internal` when its counterparty is one of
    /// the wallet's own addresses. Idempotent and safe: an event already
    /// `.internal` (single-address self-send) is returned unchanged; an
    /// event whose counterparty is empty (no single counterparty — multi-
    /// input BTC, contract call) or genuinely foreign is returned
    /// unchanged. When reclassifying, the counterparty is cleared (an
    /// `.internal` leg has no external counterparty, matching every
    /// adapter's own `.internal` shape) but the amount + fee + status are
    /// preserved exactly as the adapter computed them.
    private static func reclassifySelfTransfer(
        _ event: TransactionEvent,
        ownAddresses: Set<String>
    ) -> TransactionEvent {
        guard event.direction != .internal else { return event }
        let counterparty = event.counterparty
        guard !counterparty.isEmpty else { return event }
        let normalizedOwn = Set(ownAddresses.map(normalizeForOwnSet))
        guard normalizedOwn.contains(normalizeForOwnSet(counterparty)) else { return event }
        return TransactionEvent(
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
        )
    }

    // MARK: - Streaming

    func streamScan(
        addresses: [SupportedChain: String],
        limit: Int
    ) -> AsyncStream<TransactionEvent> {
        streamScan(addresses: addresses, limit: limit, customContractsByChain: [:])
    }

    func streamScan(
        addresses: [SupportedChain: String],
        limit: Int,
        customContractsByChain: [SupportedChain: [String]]
    ) -> AsyncStream<TransactionEvent> {
        AsyncStream(TransactionEvent.self) { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for (chain, address) in addresses {
                        let custom = customContractsByChain[chain] ?? []
                        group.addTask { [client] in
                            let events = await Self.fetch(
                                chain: chain,
                                address: address,
                                limit: limit,
                                client: client,
                                customContracts: custom
                            )
                            for event in events {
                                continuation.yield(event)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Per-chain dispatch

    /// Routes `(chain, address)` to its per-chain `ChainConnector` (the
    /// fleet design). Each connector owns its own `fetchHistory` — same
    /// endpoints / pagination / parsing the family transaction adapters
    /// used, ported verbatim — and returns up to `limit` events,
    /// newest-first. Connector errors are logged and swallowed here — a
    /// failing chain shouldn't blank the other chains' rows. The registry's
    /// exhaustive switch replaces the per-family switch that used to live
    /// here.
    private static func fetch(
        chain: SupportedChain,
        address: String,
        limit: Int,
        client: RPCClient,
        customContracts: [String] = []
    ) async -> [TransactionEvent] {
        // Short-circuit stub addresses — no point hitting an RPC for
        // a placeholder. Stub prefix is shared with the balance
        // scanner (see `StubKeyImportService.stubAddressPrefix`).
        if address.hasPrefix(StubKeyImportService.stubAddressPrefix) {
            return []
        }
        do {
            let connector = ChainConnectorRegistry.connector(for: chain)
            return try await connector.fetchHistory(
                address: address,
                limit: limit,
                customContracts: customContracts
            )
        } catch {
            // A cancellation is NOT a failure — a per-chain `withTimeout`
            // elapsed (a slow explorer, e.g. Dogecoin), a newer pull-to-refresh
            // superseded this one, or the user navigated away. The persisted
            // history stands and the next refresh retries; log quietly so it
            // doesn't read as "Transaction fetch failed … : cancelled".
            if RPCError.isCancellation(error) {
                log.debug("Transaction fetch cancelled for \(chain.rawValue, privacy: .public) at \(address, privacy: .private) (timeout/superseded — will retry)")
            } else if RPCError.isHTTPNotFound(error) {
                // A 404 = the account has no on-chain history yet (unfunded /
                // never used) — an empty history, not a failure. Log quietly so
                // an unfunded Stellar/Tron account doesn't spam the warning log.
                log.debug("No transaction history for \(chain.rawValue, privacy: .public) at \(address, privacy: .private) (404 — unfunded)")
            } else {
                log.warning("Transaction fetch failed for \(chain.rawValue, privacy: .public) at \(address, privacy: .private): \(String(describing: error), privacy: .public)")
            }
            return []
        }
    }
}
