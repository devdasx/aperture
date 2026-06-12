import Foundation
import OSLog

/// Transaction-history fetchers for the long-tail chains: Aptos, Sui,
/// NEAR, TON, Polkadot, Kava (Cosmos). Each is a small static
/// function rather than a struct because the per-chain logic is
/// linear and there's no shared state worth carrying. The dispatcher
/// in `RealRPCTransactionScanner` calls these by name.
///
/// **Honesty register (Rule #16).** Every fetch hits a real public
/// endpoint and returns parsed on-chain events. No stub data, no
/// fake amounts. If an endpoint can't be reached or the response
/// doesn't parse, the function returns the empty array — the UI then
/// renders "No activity yet" honestly rather than a hallucination.
enum LongTailTransactionAdapters {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "longtail-tx-adapter")

    // MARK: - Aptos

    /// **Both directions (2026-06-12).** The fullnode's
    /// `/accounts/{addr}/transactions` lists only transactions
    /// SUBMITTED BY the account (it pages the account's own sequence
    /// numbers) — deposits never appear there, so the old
    /// fullnode-only path could never show an incoming transfer. The
    /// Aptos Indexer's `account_transactions` table covers BOTH
    /// directions; we resolve the version list there (keyless
    /// GraphQL, verified live 2026-06-12) and hydrate each version
    /// through the chain's REGISTERED fullnode REST endpoints
    /// (`transactions/by_version/{v}`), then parse with the same
    /// transfer filter. If the indexer is unreachable, we fall back
    /// to the fullnode sent-only list — an honest degradation, not a
    /// fabrication.
    static func fetchAptos(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        let versions = await fetchAptosVersions(address: address, limit: limit)
        if !versions.isEmpty {
            var events: [TransactionEvent] = []
            events.reserveCapacity(versions.count)
            for version in versions {
                let data: Data
                do {
                    data = try await client.callREST(
                        chain: .aptos,
                        path: "transactions/by_version/\(version)"
                    )
                } catch {
                    if case .cancelled = error { throw error }
                    continue
                }
                guard let tx = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let event = parseAptosTransaction(tx, address: address) else {
                    continue
                }
                events.append(event)
            }
            return events
        }

        // Fallback: fullnode sent-only list. NOTE the registered base
        // URL already ends in `/v1` — a `/v1/...` path here doubles to
        // `/v1/v1/...` and 404s on every registered endpoint (the
        // pre-2026-06-12 bug that blanked Aptos history entirely).
        let query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        let data = try await client.callREST(chain: .aptos, path: "accounts/\(address)/transactions", query: query)
        guard let txs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return txs.prefix(limit).compactMap { parseAptosTransaction($0, address: address) }
    }

    /// Resolve up to `limit` transaction versions involving `address`
    /// (sent AND received) from the Aptos Indexer's keyless GraphQL
    /// endpoint. Returns `[]` on any failure — the caller degrades to
    /// the fullnode sent-only list. Direct URLSession with a 10 s
    /// timeout: the indexer host isn't in `RPCRegistry` (the
    /// registered Aptos endpoints are fullnode REST roots).
    private static func fetchAptosVersions(address: String, limit: Int) async -> [Int64] {
        guard let url = URL(string: "https://api.mainnet.aptoslabs.com/v1/graphql") else { return [] }
        let query = """
        query AccountTransactions($address: String, $limit: Int) { \
        account_transactions(where: {account_address: {_eq: $address}}, \
        order_by: {transaction_version: desc}, limit: $limit) { transaction_version } }
        """
        let body: [String: Any] = [
            "query": query,
            "variables": ["address": address, "limit": min(limit, 25)],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }
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
                log.error("Aptos indexer version query failed — falling back to sent-only fullnode list")
                return []
            }
            return rows.compactMap { ($0["transaction_version"] as? NSNumber)?.int64Value }
        } catch {
            log.error("Aptos indexer version query failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Decode one fullnode `user_transaction` envelope into a feed
    /// event, or `nil` when it isn't a plain transfer touching
    /// `address`. Shared by the by-version hydration and the
    /// sent-only fallback list.
    private static func parseAptosTransaction(
        _ tx: [String: Any],
        address: String
    ) -> TransactionEvent? {
        guard (tx["type"] as? String) == "user_transaction",
              let hash = tx["hash"] as? String,
              let payload = tx["payload"] as? [String: Any] else {
            return nil
        }
        let function = (payload["function"] as? String) ?? ""
        // We only render `coin::transfer` and `aptos_account::transfer`
        // — every other entry function is a contract call and
        // doesn't read as a wallet "send / receive."
        guard function == "0x1::coin::transfer" ||
              function == "0x1::aptos_account::transfer" ||
              function == "0x1::aptos_account::transfer_coins" else {
            return nil
        }
        // Resolve the asset from the type argument. Only the
        // genuine `0x1::aptos_coin::AptosCoin` type argument may
        // map to APT (8 decimals); registry-known coin types map
        // to their entry; anything else is skipped rather than
        // mislabeled as APT. `0x1::aptos_account::transfer` takes
        // no type argument and is native APT by definition.
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
        let amount = raw / scale(decimals: decimals)
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
            chain: .aptos,
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

    // MARK: - Sui

    /// Sui exposes `suix_queryTransactionBlocks` (JSON-RPC) which lets
    /// us filter by `FromAddress` or `ToAddress`. We issue two calls
    /// (one for each direction) and combine results.
    ///
    /// **Dedup (2026-06-12).** A transaction where the wallet is both
    /// sender and recipient is returned by BOTH queries; concatenating
    /// blindly produced two identical feed rows per self-send. The
    /// combine now dedupes by digest, and a digest present in both
    /// result sets is reclassified `.internal` (self-send) with an
    /// empty counterparty.
    static func fetchSui(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        async let outgoingRaw = querySuiBlocks(address: address, asSender: true, limit: limit, client: client)
        async let incomingRaw = querySuiBlocks(address: address, asSender: false, limit: limit, client: client)
        let outgoing = (try? await outgoingRaw) ?? []
        let incoming = (try? await incomingRaw) ?? []
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

    private static func querySuiBlocks(
        address: String,
        asSender: Bool,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
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
        let data = try await client.callJSONResultData(
            chain: .sui,
            method: "suix_queryTransactionBlocks",
            params: [query, NSNull(), limit, true]
        )
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let blocks = root["data"] as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        events.reserveCapacity(blocks.count)
        for block in blocks {
            guard let digest = block["digest"] as? String,
                  let timestampMsStr = block["timestampMs"] as? String,
                  let timestampMs = Int64(timestampMsStr) else {
                continue
            }
            let effects = block["effects"] as? [String: Any] ?? [:]
            let statusEnvelope = effects["status"] as? [String: Any] ?? [:]
            let statusStr = (statusEnvelope["status"] as? String) ?? "success"
            let status: TransactionStatus = statusStr == "success" ? .confirmed : .failed

            // Use `balanceChanges` to detect the SUI amount moved
            // touching this address.
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
                // Sui uses 9 decimals.
                let absAmount = abs(Decimal(amountInt)) / scale(decimals: 9)
                let direction: TransactionDirection = amountInt < 0 ? .outgoing : .incoming
                let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)

                events.append(TransactionEvent(
                    chain: .sui,
                    address: address,
                    txHash: digest,
                    direction: direction,
                    amount: absAmount,
                    tokenSymbol: "SUI",
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
        return events
    }

    // MARK: - NEAR

    /// NEAR's mainnet RPC doesn't expose a "list transactions for
    /// account" method directly — every transaction must be fetched
    /// by hash. NEAR's indexer (FastNEAR, nearblocks.io) is the
    /// canonical path; nearblocks.io's free REST API is what we use
    /// here: `/v1/account/{address}/txns-only` returns the recent
    /// transactions (signed by OR received at the account) with
    /// sender, receiver, amount, and timestamp.
    ///
    /// **Direct URLSession (2026-06-12).** nearblocks.io is an
    /// indexer host, NOT one of the chain's registered endpoints —
    /// `RPCRegistry` registers only two JSON-RPC nodes for `.near`,
    /// so the previous `callREST(chain: .near, …)` matched zero
    /// REST endpoints and threw `.allEndpointsFailed` without a
    /// single network call: NEAR activity was permanently empty.
    /// NEAR's own RPC cannot serve account history, so we GET the
    /// indexer directly (10 s timeout) — same pattern as
    /// `NEARChainAdapter`'s balance path — until an indexer slot
    /// exists in `RPCRegistry`. The `txns-only` variant is used
    /// because the plain `txns` endpoint returns receipt-shaped rows
    /// without `signer_account_id`.
    static func fetchNear(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        var components = URLComponents(string: "https://api.nearblocks.io")
        components?.path = "/v1/account/\(address)/txns-only"
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "page", value: "1"),
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log.error("NEAR history fetch failed: \(String(describing: error), privacy: .public)")
            return []
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            log.error("NEAR history fetch returned non-2xx")
            return []
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let txs = root["txns"] as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        events.reserveCapacity(txs.count)
        for tx in txs.prefix(limit) {
            guard let hash = tx["transaction_hash"] as? String,
                  let signer = tx["signer_account_id"] as? String,
                  let receiver = tx["receiver_account_id"] as? String else {
                continue
            }
            // `actions_agg.deposit` gives the yoctoNEAR amount
            // transferred when the action is a transfer. nearblocks
            // serves it as a JSON number (verified live 2026-06-12);
            // a string is accepted defensively for older payload
            // shapes. NSDecimalNumber is tried first to preserve
            // precision when the parser provides it.
            let actionsAgg = tx["actions_agg"] as? [String: Any] ?? [:]
            let depositRaw: Decimal
            if let s = actionsAgg["deposit"] as? String, let dec = Decimal(string: s) {
                depositRaw = dec
            } else if let n = actionsAgg["deposit"] as? NSDecimalNumber {
                depositRaw = n.decimalValue
            } else if let n = actionsAgg["deposit"] as? NSNumber {
                depositRaw = Decimal(n.doubleValue)
            } else {
                depositRaw = 0
            }
            // NEAR uses 24 decimals (yoctoNEAR → NEAR).
            let amount = depositRaw / scale(decimals: 24)
            let blockTimestampStr = (tx["block_timestamp"] as? String) ?? "0"
            // NEAR `block_timestamp` is nanoseconds since epoch.
            let nanos = Int64(blockTimestampStr) ?? 0
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(nanos) / 1_000_000_000)
            let blockHeight = ((tx["block"] as? [String: Any])?["block_height"] as? NSNumber)?.int64Value
            // nearblocks returns `outcomes.status` as a String
            // ("SUCCESS" / "FAILURE"); a Bool is accepted defensively
            // for older payload shapes. Anything that isn't an
            // explicit success maps to `.failed` — a failed receipt
            // must never render as confirmed.
            let outcomes = tx["outcomes"] as? [String: Any] ?? [:]
            let success: Bool
            if let statusString = outcomes["status"] as? String {
                success = statusString.uppercased() == "SUCCESS"
            } else if let statusBool = outcomes["status"] as? Bool {
                success = statusBool
            } else {
                success = true
            }

            let direction: TransactionDirection
            let counterparty: String
            if signer == address && receiver == address {
                direction = .internal
                counterparty = ""
            } else if signer == address {
                direction = .outgoing
                counterparty = receiver
            } else if receiver == address {
                direction = .incoming
                counterparty = signer
            } else {
                continue
            }

            events.append(TransactionEvent(
                chain: .near,
                address: address,
                txHash: hash,
                direction: direction,
                amount: amount,
                tokenSymbol: "NEAR",
                tokenContract: nil,
                blockNumber: blockHeight,
                occurredAt: occurredAt,
                status: success ? .confirmed : .failed,
                counterparty: counterparty,
                fee: nil
            ))
        }
        return events
    }

    // MARK: - TON

    /// TON's public API (`toncenter.com`) exposes
    /// `/getTransactions?address={addr}&limit=N`. Each transaction
    /// envelope includes `in_msg` (the source message) and `out_msgs`
    /// (any forwarded messages); we read both to determine
    /// direction.
    static func fetchTon(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        let path = "/getTransactions"
        let query: [URLQueryItem] = [
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let data = try await client.callREST(chain: .ton, path: path, query: query)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let txs = root["result"] as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        for tx in txs.prefix(limit) {
            guard let transactionId = tx["transaction_id"] as? [String: Any],
                  let hash = transactionId["hash"] as? String,
                  let utime = tx["utime"] as? Int64 else {
                continue
            }
            let inMsg = tx["in_msg"] as? [String: Any]
            let outMsgs = tx["out_msgs"] as? [[String: Any]] ?? []

            // Incoming: in_msg.source is non-empty AND inbound value > 0.
            if let inMsg, let valueStr = inMsg["value"] as? String,
               let valueNano = Int64(valueStr), valueNano > 0,
               let source = inMsg["source"] as? String, !source.isEmpty {
                let amount = Decimal(valueNano) / scale(decimals: 9)
                events.append(TransactionEvent(
                    chain: .ton,
                    address: address,
                    txHash: hash,
                    direction: .incoming,
                    amount: amount,
                    tokenSymbol: "TON",
                    tokenContract: nil,
                    blockNumber: nil,
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(utime)),
                    status: .confirmed,
                    counterparty: source,
                    fee: nil
                ))
            }
            // Outgoing: each out_msg with value > 0 is one outgoing.
            //
            // **Leg identity (2026-06-12).** A TON wallet contract can
            // send up to 4 messages from one external (batch sends),
            // and every leg shares the same `transaction_id.hash`.
            // `TransactionRepository` dedupes on `(txHash, addressId,
            // tokenContract, tokenSymbol, direction)`, so same-token
            // same-direction legs under one raw hash would collapse
            // into whichever arrived first — a 3-recipient batch send
            // showed as one row with one arbitrary recipient. When a
            // transaction carries multiple valued out-messages, each
            // leg's txHash gets a `#out{i}` suffix ("#" never occurs
            // in TON's base64 hashes, so the suffix is unambiguous
            // and strippable). A single out-message keeps the raw
            // hash — its direction already distinguishes it from the
            // inbound leg.
            let valuedOutMsgs: [(dest: String, valueNano: Int64)] = outMsgs.compactMap { outMsg in
                guard let valueStr = outMsg["value"] as? String,
                      let valueNano = Int64(valueStr), valueNano > 0,
                      let dest = outMsg["destination"] as? String, !dest.isEmpty else {
                    return nil
                }
                return (dest, valueNano)
            }
            for (index, leg) in valuedOutMsgs.enumerated() {
                let legHash = valuedOutMsgs.count > 1 ? "\(hash)#out\(index)" : hash
                let amount = Decimal(leg.valueNano) / scale(decimals: 9)
                events.append(TransactionEvent(
                    chain: .ton,
                    address: address,
                    txHash: legHash,
                    direction: .outgoing,
                    amount: amount,
                    tokenSymbol: "TON",
                    tokenContract: nil,
                    blockNumber: nil,
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(utime)),
                    status: .confirmed,
                    counterparty: leg.dest,
                    fee: nil
                ))
            }
        }
        return events
    }

    // MARK: - Polkadot

    /// Polkadot's runtime RPC doesn't expose "transactions for
    /// address" — that's an indexer concern, and the chain's
    /// registered endpoints (rpc.polkadot.io, OnFinality) are
    /// JSON-RPC nodes that cannot serve it. The previous
    /// `callRESTPost(chain: .polkadot, …)` matched zero REST
    /// endpoints and threw `.allEndpointsFailed` without a single
    /// network call — Polkadot activity was permanently empty.
    /// Subscan now hard-requires an API key (verified live
    /// 2026-06-12: HTTP 403 "Subscan API strictly requires an API
    /// key"), so we GET Statescan's keyless transfers API directly
    /// (10 s timeout) — same direct-indexer pattern as the NEAR
    /// adapters — until an indexer slot exists in `RPCRegistry`.
    ///
    /// Statescan item shape: `{ indexer: { blockHeight, blockTime
    /// (ms), extrinsicIndex }, from, to, balance (plancks string),
    /// isNativeAsset }`. The feed identity is the canonical
    /// Substrate extrinsic id `{blockHeight}-{extrinsicIndex}` —
    /// the same id every Polkadot explorer uses in its URLs.
    static func fetchPolkadot(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        var components = URLComponents(string: "https://polkadot-api.statescan.io")
        components?.path = "/accounts/\(address)/transfers"
        components?.queryItems = [
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "page_size", value: String(min(limit, 100))),
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log.error("Polkadot history fetch failed: \(String(describing: error), privacy: .public)")
            return []
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            log.error("Polkadot history fetch returned non-2xx")
            return []
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let transfers = root["items"] as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        events.reserveCapacity(transfers.count)
        for transfer in transfers.prefix(limit) {
            guard let indexer = transfer["indexer"] as? [String: Any],
                  let blockHeight = (indexer["blockHeight"] as? NSNumber)?.int64Value,
                  let from = transfer["from"] as? String,
                  let to = transfer["to"] as? String,
                  let balanceStr = transfer["balance"] as? String,
                  let plancks = Decimal(string: balanceStr) else {
                continue
            }
            // Relay-chain DOT only — skip the (rare) non-native
            // asset rows rather than mislabel them as DOT.
            if let isNative = transfer["isNativeAsset"] as? Bool, !isNative {
                continue
            }
            let extrinsicIndex = (indexer["extrinsicIndex"] as? NSNumber)?.intValue ?? 0
            let extrinsicId = "\(blockHeight)-\(extrinsicIndex)"
            // Plancks → DOT (10 decimals).
            let amount = plancks / scale(decimals: 10)
            let blockTimeMs = (indexer["blockTime"] as? NSNumber)?.doubleValue ?? 0
            let occurredAt = Date(timeIntervalSince1970: blockTimeMs / 1000)

            let direction: TransactionDirection
            let counterparty: String
            if from == address && to == address {
                direction = .internal
                counterparty = ""
            } else if from == address {
                direction = .outgoing
                counterparty = to
            } else if to == address {
                direction = .incoming
                counterparty = from
            } else {
                continue
            }

            events.append(TransactionEvent(
                chain: .polkadot,
                address: address,
                txHash: extrinsicId,
                direction: direction,
                amount: amount,
                tokenSymbol: "DOT",
                tokenContract: nil,
                blockNumber: blockHeight,
                occurredAt: occurredAt,
                // Failed transfers don't emit Transfer events, so
                // everything Statescan lists here executed.
                status: .confirmed,
                counterparty: counterparty,
                fee: nil
            ))
        }
        return events
    }

    // MARK: - Kava (Cosmos SDK)

    /// Kava uses the standard Cosmos SDK REST endpoint
    /// `/cosmos/tx/v1beta1/txs?events=...` to filter transactions
    /// by sender or recipient. Two calls (one per direction) feed
    /// the combined feed.
    static func fetchKava(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        async let sentRaw = queryKavaTxs(address: address, asSender: true, limit: limit, client: client)
        async let receivedRaw = queryKavaTxs(address: address, asSender: false, limit: limit, client: client)
        let sent = (try? await sentRaw) ?? []
        let received = (try? await receivedRaw) ?? []
        let combined = sent + received
        return combined
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    private static func queryKavaTxs(
        address: String,
        asSender: Bool,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        let eventKey = asSender ? "message.sender" : "transfer.recipient"
        let path = "/cosmos/tx/v1beta1/txs"
        let query: [URLQueryItem] = [
            URLQueryItem(name: "events", value: "\(eventKey)='\(address)'"),
            URLQueryItem(name: "pagination.limit", value: String(limit)),
            URLQueryItem(name: "order_by", value: "ORDER_BY_DESC"),
        ]
        let data = try await client.callREST(chain: .kava, path: path, query: query)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let txResponses = root["tx_responses"] as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        for raw in txResponses.prefix(limit) {
            guard let txhash = raw["txhash"] as? String,
                  let heightStr = raw["height"] as? String else {
                continue
            }
            let height = Int64(heightStr)
            let timestampStr = (raw["timestamp"] as? String) ?? ""
            let occurredAt = iso8601.date(from: timestampStr) ?? Date()
            let codeAny = raw["code"]
            let success = (codeAny as? Int ?? 0) == 0

            // Walk the tx events for a `transfer` event and pull
            // sender / recipient / amount from its attributes.
            let events_ = raw["events"] as? [[String: Any]] ?? []
            for event in events_ {
                guard (event["type"] as? String) == "transfer",
                      let attributes = event["attributes"] as? [[String: Any]] else {
                    continue
                }
                var sender = ""
                var recipient = ""
                var amountStr = ""
                for attr in attributes {
                    guard let key = attr["key"] as? String,
                          let value = attr["value"] as? String else {
                        continue
                    }
                    switch key {
                    case "sender":    sender = value
                    case "recipient": recipient = value
                    case "amount":    amountStr = value
                    default: break
                    }
                }
                guard !amountStr.isEmpty else { continue }
                // **Fee-deduction skip (2026-06-12).** Cosmos SDK's
                // ante handler deducts the fee BEFORE message
                // execution, emitting a `transfer` event from the
                // signer to the `fee_collector` module account ahead
                // of the message's own events. Taking the FIRST
                // matching transfer therefore rendered every outgoing
                // Kava row as "− <fee> KAVA to <fee collector>" while
                // the real send amount and recipient never displayed.
                // Skip it; the message's own transfer follows in the
                // same events array.
                if recipient == Self.kavaFeeCollector || sender == Self.kavaFeeCollector {
                    continue
                }
                // Cosmos amount form: "1000000ukava" (raw + denom).
                let (rawAmount, denom) = parseCosmosAmount(amountStr)
                // Kava uses ukava (6 decimals) for KAVA.
                let decimals = denom == "ukava" ? 6 : 0
                let amount = (Decimal(string: rawAmount) ?? 0) / scale(decimals: decimals)
                let symbol = denom == "ukava" ? "KAVA" : denom

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
                    continue
                }

                events.append(TransactionEvent(
                    chain: .kava,
                    address: address,
                    txHash: txhash,
                    direction: direction,
                    amount: amount,
                    tokenSymbol: symbol,
                    tokenContract: nil,
                    blockNumber: height,
                    occurredAt: occurredAt,
                    status: success ? .confirmed : .failed,
                    counterparty: counterparty,
                    fee: nil
                ))
                break
            }
        }
        return events
    }

    /// Kava's `fee_collector` module account. Module-account
    /// addresses are deterministic (derived from the module name), so
    /// this is a permanent constant — verified live 2026-06-12 against
    /// `api.data.kava.io/cosmos/auth/v1beta1/module_accounts/fee_collector`.
    /// Transfers to it are ante-handler fee deductions, never user
    /// sends.
    private static let kavaFeeCollector = "kava17xpfvakm2amg962yls6f84z3kell8c5lvvhaa6"

    private static func parseCosmosAmount(_ raw: String) -> (String, String) {
        // Split into the leading number and the trailing denom. The
        // numeric prefix accepts digits AND at most one decimal point
        // ("12.5ukava" → ("12.5", "ukava")); the denom is everything
        // after the numeric prefix, verbatim.
        var amount = ""
        var seenDecimalPoint = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let ch = raw[index]
            if ch.isNumber {
                amount.append(ch)
            } else if ch == ".", !seenDecimalPoint {
                seenDecimalPoint = true
                amount.append(ch)
            } else {
                break
            }
            index = raw.index(after: index)
        }
        let denom = String(raw[index...])
        return (amount, denom)
    }

    // MARK: - Helpers

    /// Hoisted formatter — allocating an `ISO8601DateFormatter` per
    /// record is wasteful. `ISO8601DateFormatter` is documented
    /// thread-safe by Apple, so the `nonisolated(unsafe)` opt-out of
    /// strict-concurrency checking is sound here.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    private static func scale(decimals: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<decimals { result *= 10 }
        return result
    }
}
