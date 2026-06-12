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
/// | EVM                | ETH, ARB, BASE, OP, Scroll, zkSync, MATIC, BNB, opBNB, AVAX, Celo, Kava EVM | `EVMTransactionAdapter`              |
/// | Solana             | SOL                                                                 | `SolanaTransactionAdapter`           |
/// | XRPL               | XRP                                                                 | `XRPLTransactionAdapter`             |
/// | TRON               | TRX                                                                 | `TronTransactionAdapter`             |
/// | Stellar            | XLM                                                                 | `StellarTransactionAdapter`          |
/// | Aptos / Sui / NEAR | APT, SUI, NEAR                                                      | `LongTailTransactionAdapters`        |
/// | TON / Polkadot     | TON, DOT                                                            | `LongTailTransactionAdapters`        |
/// | Kava (Cosmos)      | KAVA                                                                | `LongTailTransactionAdapters`        |
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

    let client: RPCClient

    init(client: RPCClient = RPCClient.shared) {
        self.client = client
    }

    // MARK: - Bulk

    func scan(
        addresses: [SupportedChain: String],
        limit: Int
    ) async -> [TransactionEvent] {
        await scan(addresses: addresses, limit: limit, customContractsByChain: [:])
    }

    func scan(
        addresses: [SupportedChain: String],
        limit: Int,
        customContractsByChain: [SupportedChain: [String]]
    ) async -> [TransactionEvent] {
        await withTaskGroup(of: [TransactionEvent].self) { group in
            for (chain, address) in addresses {
                let custom = customContractsByChain[chain] ?? []
                group.addTask { [client] in
                    await Self.fetch(
                        chain: chain,
                        address: address,
                        limit: limit,
                        client: client,
                        customContracts: custom
                    )
                }
            }
            var events: [TransactionEvent] = []
            events.reserveCapacity(addresses.count * limit)
            for await batch in group {
                events.append(contentsOf: batch)
            }
            return events
        }
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

    /// Routes `(chain, address)` to its family adapter. Each adapter
    /// returns up to `limit` events, newest-first. Adapter errors are
    /// logged and swallowed — a failing chain shouldn't blank the
    /// other chains' rows.
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
            switch chain {
            case .bitcoin, .bitcoinCash, .litecoin, .dogecoin:
                let adapter = BitcoinFamilyTransactionAdapter(chain: chain, client: client)
                return try await adapter.fetch(address: address, limit: limit)

            case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
                 .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm:
                let adapter = EVMTransactionAdapter(chain: chain, client: client)
                return try await adapter.fetch(
                    address: address,
                    limit: limit,
                    customContracts: customContracts
                )

            case .solana:
                let adapter = SolanaTransactionAdapter(client: client)
                return try await adapter.fetch(address: address, limit: limit)

            case .ripple:
                let adapter = XRPLTransactionAdapter(client: client)
                return try await adapter.fetch(address: address, limit: limit)

            case .tron:
                let adapter = TronTransactionAdapter(client: client)
                return try await adapter.fetch(address: address, limit: limit)

            case .stellar:
                let adapter = StellarTransactionAdapter(client: client)
                return try await adapter.fetch(address: address, limit: limit)

            case .aptos:
                return try await LongTailTransactionAdapters.fetchAptos(address: address, limit: limit, client: client)
            case .sui:
                return try await LongTailTransactionAdapters.fetchSui(address: address, limit: limit, client: client)
            case .near:
                return try await LongTailTransactionAdapters.fetchNear(address: address, limit: limit, client: client)
            case .ton:
                return try await LongTailTransactionAdapters.fetchTon(address: address, limit: limit, client: client)
            case .polkadot:
                return try await LongTailTransactionAdapters.fetchPolkadot(address: address, limit: limit, client: client)
            case .kava:
                return try await LongTailTransactionAdapters.fetchKava(address: address, limit: limit, client: client)
            }
        } catch {
            log.warning("Transaction fetch failed for \(chain.rawValue, privacy: .public) at \(address, privacy: .private): \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
