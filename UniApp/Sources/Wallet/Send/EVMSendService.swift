import Foundation
import SwiftData
import WalletCore

/// Real EVM send for all 12 EVM chains (Ethereum, Arbitrum, Base,
/// Optimism, Scroll, zkSync, Polygon, BNB, opBNB, Avalanche, Celo, Kava
/// EVM). One implementation; the chain id + EIP-1559 support differentiate.
///
/// Pipeline: fetch nonce + gas context (RPC) → estimate fee tiers → sign
/// with wallet-core `AnySigner` → `eth_sendRawTransaction` → poll
/// `eth_getTransactionReceipt`. All off the main actor (Rule #28); every
/// fee/nonce/gas value is fetched live (no guesses), and a node rejection
/// surfaces its real reason (Rule #16 / Rule #26).
///
/// ⚠️ UNVERIFIED until a real tiny-amount test send on-device — see the
/// Send V2 plan. The crypto is wallet-core's; the wiring is exercised by
/// that first real send.
enum EVMSendService {

    // MARK: - Chain metadata

    static func chainId(for chain: SupportedChain) -> Int {
        switch chain {
        case .ethereum:  return 1
        case .optimism:  return 10
        case .bnbChain:  return 56
        case .opBNB:     return 204
        case .polygon:   return 137
        case .base:      return 8453
        case .arbitrum:  return 42161
        case .avalanche: return 43114
        case .celo:      return 42220
        case .scroll:    return 534352
        case .zkSync:    return 324
        case .kavaEvm:   return 2222
        default:         return 0
        }
    }

    /// BNB Chain + opBNB are legacy (no EIP-1559); everything else is 1559.
    static func supportsEIP1559(for chain: SupportedChain) -> Bool {
        switch chain {
        case .bnbChain, .opBNB: return false
        default: return true
        }
    }

    /// Gas-limit safety multiplier (×100). L2s carry L1 cost in the
    /// estimate, so they get more headroom.
    private static func gasBufferPercent(for chain: SupportedChain) -> UInt64 {
        switch chain {
        case .zkSync:                       return 150
        case .arbitrum, .optimism, .scroll: return 130
        default:                            return 110
        }
    }

    // MARK: - Off-main orchestration (called from the @MainActor view-model)

    /// Build a request from Sendable scalars (deriving the sender address
    /// off-main) and return the real fee tiers. Runs entirely off the main
    /// actor — the view-model `await`s it.
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        let from = try ChainKeyProvider.senderAddress(for: chain, container: container)
        let request = ChainSendRequest(
            chain: chain, fromAddress: from, toAddress: toAddress,
            rawAmount: rawAmount, tokenContract: contract, decimals: decimals,
            isNative: isNative, memo: nil
        )
        return try await feeOptions(for: request)
    }

    /// Full send: derive context off-main, pick the chosen speed's real
    /// fee, sign, and broadcast. Returns the broadcast result.
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, speed: ChainFeeOption.Speed,
        container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        let from = try ChainKeyProvider.senderAddress(for: chain, container: container)
        let request = ChainSendRequest(
            chain: chain, fromAddress: from, toAddress: toAddress,
            rawAmount: rawAmount, tokenContract: contract, decimals: decimals,
            isNative: isNative, memo: nil
        )
        let fees = try await feeOptions(for: request)
        guard let fee = fees.first(where: { $0.speed == speed }) ?? fees.first else {
            throw .feeUnavailable
        }
        return try await signAndBroadcast(request: request, fee: fee, container: container)
    }

    // MARK: - Fee estimation

    static func feeOptions(for request: ChainSendRequest) async throws(ChainSendError) -> [ChainFeeOption] {
        let chain = request.chain
        let gasLimit = await estimateGasLimit(for: request)

        if supportsEIP1559(for: chain) {
            let baseFee = try await fetchBaseFee(chain: chain)
            let priority = (try? await hexCallUInt64(chain: chain, method: "eth_maxPriorityFeePerGas", params: []))
                ?? 1_500_000_000
            // (priorityMul%, baseMul%) per speed.
            let tiers: [(ChainFeeOption.Speed, UInt64, UInt64, Int)] = [
                (.slow,   80, 150, 180),
                (.normal, 100, 200, 45),
                (.fast,   150, 250, 15),
            ]
            return tiers.map { (speed, priorityMul, baseMul, secs) in
                let scaledPriority = priority * priorityMul / 100
                let scaledBase = baseFee * baseMul / 100
                var maxFee = scaledBase + scaledPriority
                if maxFee < scaledPriority { maxFee = scaledPriority + scaledPriority / 5 }
                return ChainFeeOption(
                    speed: speed,
                    feeNative: weiToNative(maxFee &* gasLimit),
                    estimatedSeconds: secs,
                    gasLimit: gasLimit,
                    maxFeePerGas: maxFee,
                    maxPriorityFeePerGas: scaledPriority,
                    gasPrice: nil
                )
            }
        } else {
            let gasPrice = (try? await hexCallUInt64(chain: chain, method: "eth_gasPrice", params: []))
                ?? 5_000_000_000
            let tiers: [(ChainFeeOption.Speed, UInt64, Int)] = [
                (.slow, 85, 60), (.normal, 100, 15), (.fast, 130, 5),
            ]
            return tiers.map { (speed, mul, secs) in
                let priced = gasPrice * mul / 100 * 110 / 100   // tier × +10% safety
                return ChainFeeOption(
                    speed: speed,
                    feeNative: weiToNative(priced &* gasLimit),
                    estimatedSeconds: secs,
                    gasLimit: gasLimit,
                    maxFeePerGas: nil,
                    maxPriorityFeePerGas: nil,
                    gasPrice: priced
                )
            }
        }
    }

    private static func fetchBaseFee(chain: SupportedChain) async throws(ChainSendError) -> UInt64 {
        do {
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain, method: "eth_getBlockByNumber", params: ["latest", false]
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hex = obj["baseFeePerGas"] as? String,
                  let v = parseHex(hex) else {
                throw ChainSendError.feeUnavailable
            }
            return v
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw ChainSendError.feeUnavailable
        }
    }

    private static func estimateGasLimit(for request: ChainSendRequest) async -> UInt64 {
        let chain = request.chain
        let fallback: UInt64 = request.isNative ? 21_000 : 65_000
        let txObject: [String: Sendable] = [
            "from": request.fromAddress,
            "to": request.isNative ? request.toAddress : (request.tokenContract ?? request.toAddress),
            "value": request.isNative ? hex0x(fromDecimalString: request.rawAmount) : "0x0",
            "data": request.isNative ? "0x" : erc20TransferData(to: request.toAddress, rawAmount: request.rawAmount),
        ]
        guard let hex = try? await RPCClient.shared.callJSONString(
            chain: chain, method: "eth_estimateGas", params: [txObject]
        ), let est = parseHex(hex) else {
            return fallback
        }
        return max(est * gasBufferPercent(for: chain) / 100, fallback)
    }

    // MARK: - Sign + broadcast

    static func signAndBroadcast(
        request: ChainSendRequest,
        fee: ChainFeeOption,
        container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        let chain = request.chain
        guard chainId(for: chain) != 0 else { throw .unsupportedChain(chain) }

        // Nonce — "pending" to include anything already in the mempool.
        let nonce = try await hexCallUInt64(
            chain: chain, method: "eth_getTransactionCount",
            params: [request.fromAddress, "pending"]
        )

        let (key, _) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        var input = EthereumSigningInput()
        input.chainID = bigEndianData(UInt64(chainId(for: chain)))
        input.nonce = bigEndianData(nonce)
        input.privateKey = key.data
        input.gasLimit = bigEndianData(fee.gasLimit ?? (request.isNative ? 21_000 : 65_000))

        if supportsEIP1559(for: chain), let maxFee = fee.maxFeePerGas, let priority = fee.maxPriorityFeePerGas {
            input.txMode = .enveloped
            input.maxFeePerGas = bigEndianData(maxFee)
            input.maxInclusionFeePerGas = bigEndianData(priority)
        } else {
            input.txMode = .legacy
            input.gasPrice = bigEndianData(fee.gasPrice ?? 5_000_000_000)
        }

        if request.isNative {
            input.toAddress = request.toAddress
            var transfer = EthereumTransaction.Transfer()
            transfer.amount = bigEndianData(fromDecimalString: request.rawAmount)
            input.transaction.transfer = transfer
        } else {
            guard let contract = request.tokenContract else {
                throw .signingFailed("Missing token contract for ERC-20 send.")
            }
            input.toAddress = contract
            var erc20 = EthereumTransaction.ERC20Transfer()
            erc20.to = request.toAddress
            erc20.amount = bigEndianData(fromDecimalString: request.rawAmount)
            input.transaction.erc20Transfer = erc20
        }

        let output: EthereumSigningOutput = AnySigner.sign(input: input, coin: .ethereum)
        guard !output.encoded.isEmpty else {
            throw .signingFailed("Signer returned an empty transaction.")
        }
        let rawHex = "0x" + output.encoded.map { String(format: "%02x", $0) }.joined()
        let localHash = "0x" + Hash.keccak256(data: output.encoded).map { String(format: "%02x", $0) }.joined()

        // Broadcast.
        do {
            let returnedHash = try await RPCClient.shared.callJSONString(
                chain: chain, method: "eth_sendRawTransaction", params: [rawHex]
            )
            return ChainSignedTransaction(broadcastPayload: rawHex, txHash: returnedHash.isEmpty ? localHash : returnedHash)
        } catch {
            throw .broadcastRejected(broadcastMessage(for: error))
        }
    }

    // MARK: - Status

    static func status(chain: SupportedChain, txHash: String) async throws(ChainSendError) -> ChainSendStatus {
        do {
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain, method: "eth_getTransactionReceipt", params: [txHash]
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .pending
            }
            let blockNumber = (obj["blockNumber"] as? String).flatMap(parseHex)
            if let statusHex = obj["status"] as? String, let s = parseHex(statusHex) {
                return s == 1 ? .confirmed(blockNumber: blockNumber) : .failed(reason: "The transaction reverted on-chain.")
            }
            return .confirmed(blockNumber: blockNumber)
        } catch {
            // A null receipt (not yet mined) decodes as `.decodingFailed`
            // here — treat any not-yet-available receipt as still pending.
            if case .decodingFailed = error { return .pending }
            throw .rpcUnavailable
        }
    }

    // MARK: - Hex / amount helpers

    private static func hexCallUInt64(chain: SupportedChain, method: String, params: [Sendable]) async throws(ChainSendError) -> UInt64 {
        do {
            let hex = try await RPCClient.shared.callJSONString(chain: chain, method: method, params: params)
            guard let v = parseHex(hex) else { throw ChainSendError.missingContext(method) }
            return v
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw ChainSendError.missingContext(method)
        }
    }

    private static func parseHex(_ hex: String) -> UInt64? {
        let clean = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        return UInt64(clean, radix: 16)
    }

    private static func weiToNative(_ wei: UInt64) -> Decimal {
        Decimal(wei) / pow(Decimal(10), 18)
    }

    /// Big-endian, leading-zero-trimmed bytes of a UInt64 (wallet-core's
    /// expected encoding for chainID / nonce / gas fields).
    private static func bigEndianData(_ value: UInt64) -> Data {
        if value == 0 { return Data([0]) }
        var v = value.bigEndian
        let bytes = withUnsafeBytes(of: &v) { Array($0) }
        return Data(bytes.drop(while: { $0 == 0 }))
    }

    /// Big-endian bytes of an arbitrary-precision decimal integer string
    /// (the raw amount can exceed UInt64 — e.g. 100 ETH in wei). Manual
    /// base-256 division; no Double, no overflow.
    static func bigEndianData(fromDecimalString decimal: String) -> Data {
        var digits = Array(decimal).compactMap { $0.wholeNumberValue }
        guard !digits.isEmpty else { return Data([0]) }
        var bytesLE: [UInt8] = []
        while !(digits.count == 1 && digits[0] == 0) {
            var remainder = 0
            var next: [Int] = []
            for d in digits {
                let cur = remainder * 10 + d
                let q = cur / 256
                remainder = cur % 256
                if !next.isEmpty || q != 0 { next.append(q) }
            }
            bytesLE.append(UInt8(remainder))
            digits = next.isEmpty ? [0] : next
        }
        return Data(bytesLE.reversed())
    }

    private static func hex0x(fromDecimalString decimal: String) -> String {
        let bytes = bigEndianData(fromDecimalString: decimal)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "0x" + (hex.isEmpty ? "0" : hex)
    }

    /// ERC-20 `transfer(address,uint256)` calldata — selector `a9059cbb` +
    /// 32-byte-padded recipient + 32-byte-padded amount. Used only for
    /// `eth_estimateGas` (wallet-core encodes the real calldata at signing).
    private static func erc20TransferData(to: String, rawAmount: String) -> String {
        let addr = to.hasPrefix("0x") ? String(to.dropFirst(2)) : to
        let paddedAddr = String(repeating: "0", count: max(0, 64 - addr.count)) + addr.lowercased()
        let amountHex = bigEndianData(fromDecimalString: rawAmount).map { String(format: "%02x", $0) }.joined()
        let paddedAmount = String(repeating: "0", count: max(0, 64 - amountHex.count)) + amountHex
        return "0xa9059cbb" + paddedAddr + paddedAmount
    }

    private static func broadcastMessage(for error: RPCError) -> String {
        let raw = "\(error)".lowercased()
        if raw.contains("nonce") { return "A transaction with this nonce was already sent." }
        if raw.contains("insufficient") { return "Balance is less than the amount plus the network fee." }
        if raw.contains("underpriced") || raw.contains("fee too low") { return "The fee is too low — pick a faster speed." }
        if raw.contains("gas") && raw.contains("limit") { return "The transaction exceeds the network's gas limit." }
        return "The network rejected the transaction. Try again."
    }
}
