import CryptoKit
import Foundation
import OSLog

/// Transaction-history adapter for the Tron network. Uses TronGrid's
/// REST API (`/v1/accounts/{address}/transactions`) which returns
/// the most recent transactions for an address with sender / receiver
/// / amount / status decoded — no SDK needed.
///
/// **Scope.** Native TRX `TransferContract` transactions land
/// directly; TRC-20 token transfers come from the sibling endpoint
/// `/v1/accounts/{address}/transactions/trc20`. Both endpoints
/// return the same envelope shape, so the adapter unifies them.
struct TronTransactionAdapter: Sendable {
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "tron-tx-adapter")

    func fetch(address: String, limit: Int) async throws -> [TransactionEvent] {
        // Native + TRC-20 fan out in parallel. `try?` on each await
        // so a single failing endpoint doesn't cancel the other.
        async let nativeEventsRaw = fetchNative(address: address, limit: limit)
        async let trc20EventsRaw = fetchTRC20(address: address, limit: limit)
        let native = (try? await nativeEventsRaw) ?? []
        let trc20 = (try? await trc20EventsRaw) ?? []
        let combined = native + trc20
        return combined
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    private func fetchNative(address: String, limit: Int) async throws -> [TransactionEvent] {
        let path = "/v1/accounts/\(address)/transactions"
        let query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "only_confirmed", value: "true"),
        ]
        let data = try await client.callREST(chain: .tron, path: path, query: query)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let txs = root["data"] as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        events.reserveCapacity(txs.count)
        for tx in txs {
            guard let txID = tx["txID"] as? String,
                  let rawData = tx["raw_data"] as? [String: Any],
                  let contracts = rawData["contract"] as? [[String: Any]],
                  let firstContract = contracts.first,
                  let parameter = firstContract["parameter"] as? [String: Any],
                  let value = parameter["value"] as? [String: Any] else {
                continue
            }
            let contractType = (firstContract["type"] as? String) ?? ""
            // Skip non-transfer contract types (TriggerSmartContract
            // we capture via TRC-20 fetch; everything else is noise
            // for an activity feed).
            guard contractType == "TransferContract" else { continue }
            let from = Self.hexAddressToTron(value["owner_address"] as? String ?? "")
            let to = Self.hexAddressToTron(value["to_address"] as? String ?? "")
            let amountSun = (value["amount"] as? Int64) ?? 0
            let amount = Decimal(amountSun) / Self.sunPerTrx

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

            let timestamp = (rawData["timestamp"] as? Int64) ?? ((tx["block_timestamp"] as? Int64) ?? 0)
            // Tron timestamps are milliseconds since epoch.
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
            let blockNumber = (tx["blockNumber"] as? Int64)
            let ret = tx["ret"] as? [[String: Any]] ?? []
            let txStatus = (ret.first?["contractRet"] as? String) ?? "SUCCESS"
            let status: TransactionStatus = txStatus == "SUCCESS" ? .confirmed : .failed

            events.append(TransactionEvent(
                chain: .tron,
                address: address,
                txHash: txID,
                direction: direction,
                amount: amount,
                tokenSymbol: "TRX",
                tokenContract: nil,
                blockNumber: blockNumber,
                occurredAt: occurredAt,
                status: status,
                counterparty: counterparty,
                fee: nil
            ))
        }
        return events
    }

    private func fetchTRC20(address: String, limit: Int) async throws -> [TransactionEvent] {
        let path = "/v1/accounts/\(address)/transactions/trc20"
        let query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "only_confirmed", value: "true"),
        ]
        let data = try await client.callREST(chain: .tron, path: path, query: query)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let txs = root["data"] as? [[String: Any]] else {
            return []
        }
        var events: [TransactionEvent] = []
        for tx in txs {
            guard let txID = tx["transaction_id"] as? String,
                  let from = tx["from"] as? String,
                  let to = tx["to"] as? String,
                  let valueStr = tx["value"] as? String,
                  let tokenInfo = tx["token_info"] as? [String: Any] else {
                continue
            }
            // `token_info.symbol` is self-declared by the token
            // contract — scam airdrops on Tron routinely name
            // themselves "USDT". The display symbol (and decimals)
            // come from the curated registry keyed by CONTRACT
            // ADDRESS; unknown contracts get the neutral "TRC20"
            // label, mirroring the Solana adapter's unknown-mint
            // handling.
            let contract = tokenInfo["address"] as? String
            let registryEntry = contract.flatMap { c in
                TronTokenRegistry.tokens.first { $0.contract == c }
            }
            let symbol = registryEntry?.symbol ?? "TRC20"
            let decimals = registryEntry?.decimals ?? ((tokenInfo["decimals"] as? Int) ?? 0)
            let raw = Decimal(string: valueStr) ?? 0
            let amount = raw / Self.scale(decimals: decimals)

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
            let timestamp = (tx["block_timestamp"] as? Int64) ?? 0
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)

            events.append(TransactionEvent(
                chain: .tron,
                address: address,
                txHash: txID,
                direction: direction,
                amount: amount,
                tokenSymbol: symbol,
                tokenContract: contract,
                blockNumber: nil,
                occurredAt: occurredAt,
                status: .confirmed,
                counterparty: counterparty,
                fee: nil
            ))
        }
        return events
    }

    /// Tron raw addresses are hex with a `41` prefix; the user-facing
    /// form is Base58Check over the full 21-byte payload:
    /// `base58( payload ‖ first4( sha256( sha256( payload ) ) ) )`.
    /// The conversion must be real — direction classification above
    /// compares `from`/`to` against the caller's Base58Check address,
    /// so returning raw hex would drop every native TRX transaction.
    /// Verified against the TRON reference vectors
    /// (`41E552F6…32CD0` → `TWsm8HtU2A5eEzoT8ev8yaoFjHsXLLrckb`).
    /// Inputs that don't look like a 21-byte `41`-prefixed hex string
    /// (e.g. already Base58Check) are returned unchanged.
    private static func hexAddressToTron(_ hex: String) -> String {
        guard hex.count == 42,
              hex.lowercased().hasPrefix("41"),
              let payload = hexBytes(hex) else {
            return hex
        }
        let firstRound = SHA256.hash(data: Data(payload))
        let secondRound = SHA256.hash(data: Data(firstRound))
        let checksum = Array(secondRound.prefix(4))
        return Base58.encode(Data(payload + checksum))
    }

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
            result.append(byte)
            i = next
        }
        return result
    }

    private static let sunPerTrx: Decimal = {
        var result = Decimal(1)
        for _ in 0..<6 { result *= 10 }
        return result
    }()

    private static func scale(decimals: Int) -> Decimal {
        // For unknown contracts `decimals` is the indexer's copy of
        // attacker-controlled contract metadata — clamp so a negative
        // value can't trap the range and an absurd one can't spin
        // the loop. 77 ≈ Decimal's significand capacity.
        let clamped = max(0, min(decimals, 77))
        var result = Decimal(1)
        for _ in 0..<clamped { result *= 10 }
        return result
    }
}
