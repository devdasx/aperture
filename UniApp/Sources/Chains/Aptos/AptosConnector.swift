import Foundation
import OSLog

/// **Aptos connector — a Move-VM (`other`-kind) reference implementation.**
///
/// A FULLY INDEPENDENT module for `.aptos`: its own `0x1::coin::balance`
/// view-function native read, its own `0x1::primary_fungible_store::balance`
/// view-function token reads, and its own two-stage history pipeline
/// (Aptos Indexer GraphQL version list → fullnode `transactions/by_version`
/// hydration, with a fullnode sent-only fallback). It owns its request
/// shapes + parsing end-to-end and dispatches every fullnode call through
/// the shared `RPCClient` actor via `callRESTPost` / `callREST` (rotation +
/// rate-limit + circuit-breaking + ConcurrencyGate) against the registered
/// endpoints `RPCRegistry.endpoints(for: .aptos)` (fullnode.mainnet.aptoslabs.com
/// primary, api.mainnet.aptoslabs.com fallback — both Aptos Labs fullnodes,
/// `/v1`-rooted REST). Never a raw `URLSession` for the fullnode paths.
///
/// **The one documented exception** mirrors `LongTailTransactionAdapters`:
/// the Aptos Indexer GraphQL host (`api.mainnet.aptoslabs.com/v1/graphql`)
/// is NOT a registered `RPCRegistry` endpoint — the registered Aptos
/// endpoints are fullnode REST roots — so the version-list query GETs/POSTs
/// that indexer directly (10 s timeout), exactly as the existing adapter
/// does, until an indexer slot exists in `RPCRegistry`. The fullnode
/// hydration that follows it goes back through `RPCClient`.
///
/// **Ported verbatim-faithful** from `AptosChainAdapter.fetchAccountSummary`
/// (native balance), `RealRPCBalanceScanner.fetchAptosTokenBalance` +
/// `AptosTokenRegistry` (token balances), and
/// `LongTailTransactionAdapters.fetchAptos` / `fetchAptosVersions` /
/// `parseAptosTransaction` (history): same `view` function calls, same
/// octas/FA-unit math (APT 10^8, USDC/USDT 10^6), same indexer
/// `account_transactions` GraphQL paging, same `by_version` hydration, same
/// transfer-function allowlist + direction classification, same FA-vs-CoinStore
/// agnostic view path that survived Aptos's 2024 fungible-asset migration.
struct AptosConnector: ChainConnector {
    let chain: SupportedChain = .aptos
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "aptos-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native APT balance + used-address flag via the
    /// `0x1::coin::balance` view function. Ported from
    /// `AptosChainAdapter.fetchAccountSummary`.
    ///
    /// The view function works against BOTH the legacy `CoinStore`
    /// resource AND the new fungible-asset (FA) model Aptos migrated to
    /// in 2024 — the previous direct `resource/CoinStore` path returned
    /// `resource_not_found` for any account already on the FA model
    /// (every recently-active account), so the view path is canonical.
    /// The view returns a JSON array with one string element (the
    /// balance in octas, 10^8 per APT). A genuinely-unfunded account is
    /// reported by the fullnode as `2xx` with `0` (or no resource), which
    /// decodes to a clean zero — there is no 404 to map here, but the
    /// `RPCError.isHTTPNotFound` mapping is kept defensively in line with
    /// the other account-based connectors (Stellar, Tron).
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let body: [String: Sendable] = [
            "function": "0x1::coin::balance",
            "type_arguments": ["0x1::aptos_coin::AptosCoin"],
            "arguments": [address],
        ]
        let data: Data
        do {
            data = try await client.callRESTPost(chain: chain, path: "view", body: body)
        } catch {
            if case .cancelled = error { throw error }
            // A 404 on an account path = the account has never been
            // funded — the normal zero-balance state, not a failure.
            if RPCError.isHTTPNotFound(error) {
                Self.log.debug("Aptos account unfunded (404) — treating as 0 balance")
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            throw error
        }
        // Array with one string element (balance in octas). A
        // missing-resource view reply also degrades to zero here.
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let valueStr = arr.first as? String,
              let octas = Decimal(string: valueStr) else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        let apt = octas / Self.octasPerApt
        return ChainAccountSummary(nativeBalance: apt, isUsed: apt > 0)
    }

    // MARK: - Token balances

    /// Fungible-asset balances for the chain's registry tokens
    /// (`AptosTokenRegistry`) plus the user's `customContracts`, each via
    /// the `0x1::primary_fungible_store::balance` view function. Ported
    /// from `RealRPCBalanceScanner.fetchAptosTokenBalance` — same
    /// `type_arguments: ["0x1::fungible_asset::Metadata"]`, same
    /// `arguments: [holder, metadata]` shape, same one-string-element
    /// array decode.
    ///
    /// Reads run in parallel (`withTaskGroup`), each token written back at
    /// its input index so order is deterministic. Non-throwing per the
    /// `ChainConnector` contract: a per-token failure degrades that token
    /// to "no row" (cancellation aborts the whole fan-out). Only
    /// POSITIVE-balance rows are returned; `fiatBalance` is `nil` (pricing
    /// stays in the coordinator).
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        // Registry tokens first, then deduplicated custom metadata
        // objects. Custom FA contracts ship without registry metadata
        // here; the coordinator's custom-token pass owns symbol/name/
        // decimals — the connector still reads the balance so a
        // user-added FA surfaces. Decimals default to 8 (APT-native FA
        // standard); the canonical amount is re-derived downstream if the
        // true decimals differ.
        var specs: [TokenSpec] = AptosTokenRegistry.tokens.map {
            TokenSpec(contract: $0.contract, symbol: $0.symbol, name: $0.name, decimals: $0.decimals)
        }
        let known = Set(AptosTokenRegistry.tokens.map { $0.contract.lowercased() })
        for contract in customContracts where !known.contains(contract.lowercased()) {
            specs.append(TokenSpec(contract: contract, symbol: Self.shortMetadata(contract), name: contract, decimals: 8))
        }
        guard !specs.isEmpty else { return [] }

        var slots: [Decimal?] = Array(repeating: nil, count: specs.count)
        await withTaskGroup(of: (Int, Decimal?).self) { group in
            for (index, spec) in specs.enumerated() {
                group.addTask {
                    let raw = await self.fetchFungibleAssetBalance(holder: address, metadata: spec.contract)
                    return (index, raw)
                }
            }
            for await (index, raw) in group {
                slots[index] = raw
            }
        }

        let now = Date()
        var rows: [TokenBalance] = []
        rows.reserveCapacity(specs.count)
        for (i, spec) in specs.enumerated() {
            let rawAmount = slots[i] ?? 0
            let amount = rawAmount / Self.pow10(spec.decimals)
            guard amount > 0 else { continue }
            rows.append(TokenBalance(
                chain: chain,
                address: address,
                contract: spec.contract,
                symbol: spec.symbol,
                name: spec.name,
                decimals: spec.decimals,
                amount: amount,
                fiatBalance: nil,           // pricing stays in the coordinator
                fiatCurrencyCode: "",       // coordinator stamps the active currency
                lastUpdated: now
            ))
        }
        return rows
    }

    /// One FA's discovered metadata + the metadata object address — the
    /// connector's internal work item before a balance lands.
    private struct TokenSpec: Sendable {
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    /// Single `0x1::primary_fungible_store::balance` view read for one FA
    /// metadata object. Raw integer balance (base units); `nil` when the
    /// view fails / returns no parseable value (the holder has no store
    /// for that asset). Ported from
    /// `RealRPCBalanceScanner.fetchAptosTokenBalance`.
    private func fetchFungibleAssetBalance(holder: String, metadata: String) async -> Decimal? {
        do {
            let body: [String: Sendable] = [
                "function": "0x1::primary_fungible_store::balance",
                "type_arguments": ["0x1::fungible_asset::Metadata"],
                "arguments": [holder, metadata],
            ]
            let data = try await client.callRESTPost(chain: chain, path: "view", body: body)
            guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
                  let valueStr = arr.first as? String,
                  let raw = Decimal(string: valueStr) else {
                return nil
            }
            return raw
        } catch {
            return nil
        }
    }

    // MARK: - Transaction history

    /// Aptos Indexer GraphQL endpoint — keyless `account_transactions`
    /// table covering BOTH directions. NOT in `RPCRegistry` (the
    /// registered Aptos endpoints are fullnode REST roots), so this one
    /// host is reached directly, exactly as `LongTailTransactionAdapters`
    /// does.
    private static let indexerGraphQLURL = "https://api.mainnet.aptoslabs.com/v1/graphql"

    /// The fullnode caps `/accounts/{addr}/transactions` page size at 100.
    private static let fullnodeMaxPage = 100

    /// History = the Aptos Indexer's `account_transactions` version list
    /// (sent AND received), hydrated through the fullnode's
    /// `transactions/by_version/{v}`; with a fullnode sent-only fallback
    /// when the indexer is unreachable. Ported from
    /// `LongTailTransactionAdapters.fetchAptos`.
    ///
    /// The fullnode's `/accounts/{addr}/transactions` lists only
    /// transactions SUBMITTED BY the account (it pages the account's own
    /// sequence numbers) — deposits never appear there, so the indexer
    /// path is the only one that shows incoming transfers. The fallback
    /// is therefore an honest "newest ≤100 sent" degradation, not full
    /// history.
    ///
    /// `customContracts` is unused for Aptos history (the transfer-function
    /// allowlist already gates token rows to registry coin types) but kept
    /// for the uniform `ChainConnector` signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let versions = await fetchVersions(address: address, limit: limit)
        if !versions.isEmpty {
            var events: [TransactionEvent] = []
            events.reserveCapacity(versions.count)
            for version in versions {
                let data: Data
                do {
                    data = try await client.callREST(chain: chain, path: "transactions/by_version/\(version)")
                } catch {
                    if case .cancelled = error { throw error }
                    continue
                }
                guard let tx = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let event = parseTransaction(tx, address: address) else {
                    continue
                }
                events.append(event)
            }
            return events
        }

        // Fallback: fullnode sent-only list. NOTE the registered base URL
        // already ends in `/v1` — a `/v1/...` path here doubles to
        // `/v1/v1/...` and 404s on every registered endpoint, so the path
        // is bare (`accounts/...`).
        let query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(limit, Self.fullnodeMaxPage)))]
        let data = try await client.callREST(chain: chain, path: "accounts/\(address)/transactions", query: query)
        guard let txs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return txs.prefix(limit).compactMap { parseTransaction($0, address: address) }
    }

    /// Resolve up to `limit` transaction versions involving `address`
    /// (sent AND received) from the keyless Aptos Indexer GraphQL
    /// endpoint. Returns `[]` on a first-page failure — the caller
    /// degrades to the fullnode sent-only list. Direct `URLSession` with a
    /// 10 s timeout (the indexer host isn't in `RPCRegistry`). Pages with
    /// GraphQL `limit`/`offset` (100 per page), sequentially, until
    /// `limit` versions, a short page (history exhausted), or a
    /// mid-pagination failure — which keeps the versions already listed.
    /// Ported from `LongTailTransactionAdapters.fetchAptosVersions`.
    private func fetchVersions(address: String, limit: Int) async -> [Int64] {
        guard let url = URL(string: Self.indexerGraphQLURL) else { return [] }
        let query = """
        query AccountTransactions($address: String, $limit: Int, $offset: Int) { \
        account_transactions(where: {account_address: {_eq: $address}}, \
        order_by: {transaction_version: desc}, limit: $limit, offset: $offset) { transaction_version } }
        """
        let pageSize = min(limit, 100)
        var versions: [Int64] = []
        var offset = 0
        while versions.count < limit {
            if Task.isCancelled { return versions }
            let body: [String: Any] = [
                "query": query,
                "variables": ["address": address, "limit": pageSize, "offset": offset],
            ]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return versions }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let dataEnvelope = root["data"] as? [String: Any],
                      let rows = dataEnvelope["account_transactions"] as? [[String: Any]] else {
                    Self.log.error("Aptos indexer version query failed at offset \(offset, privacy: .public) — keeping \(versions.count, privacy: .public) versions")
                    return versions
                }
                if rows.isEmpty { break }
                versions.append(contentsOf: rows.compactMap { ($0["transaction_version"] as? NSNumber)?.int64Value })
                if rows.count < pageSize { break } // history exhausted
                offset += rows.count
            } catch let urlError as URLError where urlError.code == .cancelled {
                return versions
            } catch {
                Self.log.error("Aptos indexer version query failed: \(String(describing: error), privacy: .public)")
                return versions
            }
        }
        return Array(versions.prefix(limit))
    }

    /// The transfer entry functions this connector renders. Every other
    /// entry function is a contract call and doesn't read as a wallet
    /// "send / receive." Ported verbatim from `parseAptosTransaction`.
    private static let transferFunctions: Set<String> = [
        "0x1::coin::transfer",
        "0x1::aptos_account::transfer",
        "0x1::aptos_account::transfer_coins",
    ]

    /// Decode one fullnode `user_transaction` envelope into a feed event,
    /// or `nil` when it isn't a plain transfer touching `address`. Shared
    /// by the by-version hydration and the sent-only fallback list. Ported
    /// verbatim from `LongTailTransactionAdapters.parseAptosTransaction`.
    private func parseTransaction(_ tx: [String: Any], address: String) -> TransactionEvent? {
        guard (tx["type"] as? String) == "user_transaction",
              let hash = tx["hash"] as? String,
              let payload = tx["payload"] as? [String: Any] else {
            return nil
        }
        let function = (payload["function"] as? String) ?? ""
        guard Self.transferFunctions.contains(function) else { return nil }

        // Resolve the asset from the type argument. Only the genuine
        // `0x1::aptos_coin::AptosCoin` type argument may map to APT
        // (8 decimals); registry-known coin types map to their entry;
        // anything else is skipped rather than mislabeled as APT.
        // `0x1::aptos_account::transfer` takes no type argument and is
        // native APT by definition.
        let typeArguments = (payload["type_arguments"] as? [String]) ?? []
        let symbol: String
        let decimals: Int
        let tokenContract: String?
        if function == "0x1::aptos_account::transfer" {
            symbol = "APT"
            decimals = 8
            tokenContract = nil
        } else if let coinType = typeArguments.first {
            if coinType == "0x1::aptos_coin::AptosCoin" {
                symbol = "APT"
                decimals = 8
                tokenContract = nil
            } else if let entry = AptosTokenRegistry.tokens.first(where: {
                coinType == $0.contract || coinType.hasPrefix($0.contract + "::")
            }) {
                symbol = entry.symbol
                decimals = entry.decimals
                tokenContract = entry.contract
            } else {
                return nil
            }
        } else {
            return nil
        }

        let args = (payload["arguments"] as? [Any]) ?? []
        let recipient = (args.first as? String) ?? ""
        let amountStr = (args.count >= 2 ? args[1] : "0") as? String ?? "0"
        let raw = Decimal(string: amountStr) ?? 0
        let amount = raw / Self.scale(decimals: decimals)
        let sender = (tx["sender"] as? String) ?? ""
        let success = (tx["success"] as? Bool) ?? true
        let timestampStr = (tx["timestamp"] as? String) ?? "0"
        let timestampMicros = Int64(timestampStr) ?? 0
        let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestampMicros) / 1_000_000)
        let version = (tx["version"] as? String).flatMap { Int64($0) }

        let direction: TransactionDirection
        let counterparty: String
        if sender == address && recipient == address {
            direction = .internal
            counterparty = ""
        } else if sender == address {
            direction = .outgoing
            counterparty = recipient
        } else if recipient == address {
            direction = .incoming
            counterparty = sender
        } else {
            return nil
        }

        return TransactionEvent(
            chain: chain,
            address: address,
            txHash: hash,
            direction: direction,
            amount: amount,
            tokenSymbol: symbol,
            tokenContract: tokenContract,
            blockNumber: version,
            occurredAt: occurredAt,
            status: success ? .confirmed : .failed,
            counterparty: counterparty,
            fee: nil
        )
    }

    // MARK: - Decimal helpers

    /// 10^8 — APT's smallest unit is the octa.
    private static let octasPerApt: Decimal = 100_000_000

    private static func scale(decimals: Int) -> Decimal {
        let clamped = min(max(decimals, 0), 38)
        var result = Decimal(1)
        for _ in 0..<clamped { result *= 10 }
        return result
    }

    private static func pow10(_ n: Int) -> Decimal {
        let clamped = min(max(n, 0), 38)
        var r = Decimal(1)
        for _ in 0..<clamped { r *= 10 }
        return r
    }

    /// Short label for a custom FA metadata object address (no registry
    /// metadata) — `0x1234…cdef`.
    private static func shortMetadata(_ addr: String) -> String {
        let stripped = addr.hasPrefix("0x") ? String(addr.dropFirst(2)) : addr
        if stripped.count >= 10 { return "0x" + String(stripped.prefix(4)) + "…" + String(stripped.suffix(4)) }
        return addr
    }
}
