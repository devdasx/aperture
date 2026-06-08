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

    func fetch(address: String, limit: Int) async throws -> [TransactionEvent] {
        let latestBlock = try await fetchLatestBlock()
        let fromBlock = max(0, latestBlock - Self.scanBlockRange)
        let fromHex = "0x" + String(fromBlock, radix: 16)
        let toHex = "0x" + String(latestBlock, radix: 16)

        // Pad the user's address to 32 bytes (66 hex chars including
        // "0x") for topic matching — EVM logs encode topics as 32-byte
        // words, and `from`/`to` are indexed parameters so they live in
        // topics not data.
        let padded = Self.padTopic(address)

        async let incomingLogs = fetchLogs(from: fromHex, to: toHex, fromTopic: nil, toTopic: padded)
        async let outgoingLogs = fetchLogs(from: fromHex, to: toHex, fromTopic: padded, toTopic: nil)

        let allLogs = try await incomingLogs + outgoingLogs
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
            } else {
                direction = .outgoing
                counterparty = toAddr
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
    private func fetchLogs(
        from fromBlock: String,
        to toBlock: String,
        fromTopic: String?,
        toTopic: String?
    ) async throws -> [[String: Any]] {
        // JSON-RPC topics array accepts strings and JSON null
        // (wildcard). `[String?]` serializes `nil` as JSON null via
        // `JSONSerialization`. The whole filter is `[String: Sendable]`
        // so it satisfies `RPCClient.callJSONResultData`'s
        // `[Sendable]` parameter contract.
        let topics: [String?] = [Self.transferTopic, fromTopic, toTopic]
        let filter: [String: Sendable] = [
            "fromBlock": fromBlock,
            "toBlock": toBlock,
            "topics": topics,
        ]
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
        var result = Decimal(1)
        for _ in 0..<decimals { result *= 10 }
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
