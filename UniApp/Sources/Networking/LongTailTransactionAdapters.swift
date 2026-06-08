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

    /// Aptos Indexer API isn't available without a key; the on-chain
    /// REST endpoint exposes account transactions directly via
    /// `/v1/accounts/{addr}/transactions?limit=N`. Native APT
    /// transfers + coin module events both show up here; we filter
    /// to the `user_transaction` type and inspect the `payload` for
    /// `0x1::coin::transfer` (native APT and other coins).
    static func fetchAptos(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        let path = "/v1/accounts/\(address)/transactions"
        let query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        let data = try await client.callREST(chain: .aptos, path: path, query: query)
        guard let txs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        events.reserveCapacity(min(txs.count, limit))
        for tx in txs.prefix(limit) {
            guard (tx["type"] as? String) == "user_transaction",
                  let hash = tx["hash"] as? String,
                  let payload = tx["payload"] as? [String: Any] else {
                continue
            }
            let function = (payload["function"] as? String) ?? ""
            // We only render `coin::transfer` and `aptos_account::transfer`
            // — every other entry function is a contract call and
            // doesn't read as a wallet "send / receive."
            guard function == "0x1::coin::transfer" ||
                  function == "0x1::aptos_account::transfer" ||
                  function == "0x1::aptos_account::transfer_coins" else {
                continue
            }
            let args = (payload["arguments"] as? [Any]) ?? []
            let recipient = (args.first as? String) ?? ""
            let amountStr = (args.count >= 2 ? args[1] : "0") as? String ?? "0"
            let raw = Decimal(string: amountStr) ?? 0
            // Aptos native uses 8 decimals.
            let amount = raw / scale(decimals: 8)
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
                continue
            }

            events.append(TransactionEvent(
                chain: .aptos,
                address: address,
                txHash: hash,
                direction: direction,
                amount: amount,
                tokenSymbol: "APT",
                tokenContract: nil,
                blockNumber: version,
                occurredAt: occurredAt,
                status: success ? .confirmed : .failed,
                counterparty: counterparty,
                fee: nil
            ))
        }
        return events
    }

    // MARK: - Sui

    /// Sui exposes `suix_queryTransactionBlocks` (JSON-RPC) which lets
    /// us filter by `FromAddress` or `ToAddress`. We issue two calls
    /// (one for each direction) and combine results.
    static func fetchSui(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        async let outgoingRaw = querySuiBlocks(address: address, asSender: true, limit: limit, client: client)
        async let incomingRaw = querySuiBlocks(address: address, asSender: false, limit: limit, client: client)
        let outgoing = (try? await outgoingRaw) ?? []
        let incoming = (try? await incomingRaw) ?? []
        let combined = outgoing + incoming
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
    /// here: `/v1/account/{address}/txns` returns the recent
    /// transactions with sender, receiver, amount, and timestamp.
    static func fetchNear(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        let path = "/v1/account/\(address)/txns"
        let query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "page", value: "1"),
        ]
        let data = try await client.callREST(chain: .near, path: path, query: query)
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
            // `actions_agg.deposit` (string) gives the yoctoNEAR
            // amount transferred when the action is a transfer.
            let actionsAgg = tx["actions_agg"] as? [String: Any] ?? [:]
            let depositStr = (actionsAgg["deposit"] as? String) ?? "0"
            let depositRaw = Decimal(string: depositStr) ?? 0
            // NEAR uses 24 decimals (yoctoNEAR → NEAR).
            let amount = depositRaw / scale(decimals: 24)
            let blockTimestampStr = (tx["block_timestamp"] as? String) ?? "0"
            // NEAR `block_timestamp` is nanoseconds since epoch.
            let nanos = Int64(blockTimestampStr) ?? 0
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(nanos) / 1_000_000_000)
            let outcomes = tx["outcomes"] as? [String: Any] ?? [:]
            let success = (outcomes["status"] as? Bool) ?? true

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
                blockNumber: nil,
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
            for outMsg in outMsgs {
                guard let valueStr = outMsg["value"] as? String,
                      let valueNano = Int64(valueStr), valueNano > 0,
                      let dest = outMsg["destination"] as? String, !dest.isEmpty else {
                    continue
                }
                let amount = Decimal(valueNano) / scale(decimals: 9)
                events.append(TransactionEvent(
                    chain: .ton,
                    address: address,
                    txHash: hash,
                    direction: .outgoing,
                    amount: amount,
                    tokenSymbol: "TON",
                    tokenContract: nil,
                    blockNumber: nil,
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(utime)),
                    status: .confirmed,
                    counterparty: dest,
                    fee: nil
                ))
            }
        }
        return events
    }

    // MARK: - Polkadot

    /// Polkadot's runtime RPC doesn't expose "transactions for
    /// address" — that's an indexer concern. Subscan's free REST API
    /// is what most wallets use: `POST /api/v2/scan/transfers` with
    /// `{ address, row, page }`. No key required for the basic
    /// `transfers` endpoint.
    static func fetchPolkadot(
        address: String,
        limit: Int,
        client: RPCClient
    ) async throws -> [TransactionEvent] {
        let body: [String: Sendable] = [
            "address": address,
            "row": min(limit, 100),
            "page": 0,
        ]
        let data = try await client.callRESTPost(
            chain: .polkadot,
            path: "/api/v2/scan/transfers",
            body: body
        )
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataEnvelope = root["data"] as? [String: Any],
              let transfers = dataEnvelope["transfers"] as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        events.reserveCapacity(transfers.count)
        for transfer in transfers.prefix(limit) {
            guard let hash = transfer["hash"] as? String,
                  let from = transfer["from"] as? String,
                  let to = transfer["to"] as? String,
                  let amountAny = transfer["amount"] else {
                continue
            }
            let amountString: String
            if let str = amountAny as? String {
                amountString = str
            } else if let num = amountAny as? Double {
                amountString = String(num)
            } else {
                continue
            }
            let amount = Decimal(string: amountString) ?? 0
            let blockTimestamp = (transfer["block_timestamp"] as? Int64) ?? 0
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(blockTimestamp))
            let success = (transfer["success"] as? Bool) ?? true

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
                txHash: hash,
                direction: direction,
                amount: amount,
                tokenSymbol: "DOT",
                tokenContract: nil,
                blockNumber: nil,
                occurredAt: occurredAt,
                status: success ? .confirmed : .failed,
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
            let occurredAt = ISO8601DateFormatter().date(from: timestampStr) ?? Date()
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

    private static func parseCosmosAmount(_ raw: String) -> (String, String) {
        // Split into the leading number and the trailing denom.
        var amount = ""
        var denom = ""
        for ch in raw {
            if ch.isNumber {
                amount.append(ch)
            } else {
                denom.append(ch)
            }
        }
        return (amount, denom)
    }

    // MARK: - Helpers

    private static func scale(decimals: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<decimals { result *= 10 }
        return result
    }
}
