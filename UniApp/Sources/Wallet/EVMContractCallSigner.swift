import Foundation
import WalletCore

/// EVM transaction signing for the **dApp browser's `eth_sendTransaction`**.
///
/// Signs an ARBITRARY EVM transaction — the dApp's calldata to any contract —
/// which `EVMTransactionSigner` can't do (it only encodes a native / ERC-20
/// `transfer` from a `SendDraft`). It also bundles the two small RPC reads the
/// dApp signer needs (pending nonce, gas price) and the hex helpers it uses.
///
/// Shared by the dApp browser (`EVMDAppSigner`) and the Token Approvals
/// revoke flow (`ApprovalRevocationService`) — a self-contained EVM
/// contract-call signer with no dependency on any other feature.
///
/// **Legacy fee mode, on purpose.** Signs as a Type-0 (legacy) tx with a
/// single `gasPrice` — valid + accepted on every EVM chain (including
/// EIP-1559 chains), which keeps signing robust without per-chain base-fee
/// estimation. The gas PRICE is a fresh `eth_gasPrice`; the gas LIMIT comes
/// from the dApp (+ a safe ceiling fallback). Pure compute, `nonisolated`.
enum EVMContractCallSigner {

    // MARK: - Live RPC reads

    /// Live pending nonce for `address` on `chain`
    /// (`eth_getTransactionCount` with the `"pending"` tag, matching the Send
    /// signer). `nil` on any RPC/parse failure.
    static func pendingNonce(address: String, chain: SupportedChain) async -> UInt64? {
        guard let hex = try? await RPCClient.shared.callJSONString(
            chain: chain, method: "eth_getTransactionCount", params: [address, "pending"]
        ) else { return nil }
        return quantityToUInt64(hex)
    }

    /// `eth_gasPrice` → wei. `nil` on failure (the caller then refuses
    /// honestly rather than sign with a guessed price).
    static func gasPriceWei(chain: SupportedChain) async -> UInt64? {
        guard let hex = try? await RPCClient.shared.callJSONString(
            chain: chain, method: "eth_gasPrice", params: []
        ) else { return nil }
        return quantityToUInt64(hex)
    }

    // MARK: - Hex helpers

    /// Strip an optional `0x`/`0X` prefix; lowercase.
    static func strip0x(_ s: String) -> String {
        let lower = s.lowercased()
        return lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
    }

    /// A hex-quantity string (`"0x.."`, possibly odd-length or `"0x0"`) →
    /// big-endian `Data` for a wallet-core amount/value field. Zero / empty →
    /// `Data([0])`. Leading zeros trimmed (wallet-core wants the minimal
    /// big-endian representation).
    static func quantityToData(_ hex: String) -> Data {
        let bytes = trimLeadingZeros(hexToBytes(strip0x(hex)))
        return bytes.isEmpty ? Data([0]) : Data(bytes)
    }

    /// Parse a hex-quantity string to `UInt64` (gas limit / gas price —
    /// comfortably within 64 bits). `nil` if it overflows or is malformed.
    static func quantityToUInt64(_ hex: String) -> UInt64? {
        UInt64(strip0x(hex), radix: 16)
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        let clean = hex.count % 2 == 0 ? hex : "0" + hex
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return [] }
            out.append(b)
            i = j
        }
        return out
    }

    private static func trimLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes
        while result.first == 0 { result.removeFirst() }
        return result
    }

    // MARK: - Signing

    /// A ready-to-sign EVM transaction. The nonce / gas are resolved by the
    /// caller (live nonce + gas price); the calldata + value come from the
    /// dApp request.
    struct UnsignedTx: Sendable {
        let chain: SupportedChain
        let nonce: UInt64
        /// The destination contract (or EOA) address.
        let to: String
        /// Native value in hex (`"0x.."`); `"0x0"` for a token-only call.
        let valueHex: String
        /// ABI-encoded calldata supplied by the dApp.
        let data: Data
        let gasLimit: UInt64
        let gasPriceWei: UInt64
    }

    static func sign(_ tx: UnsignedTx, privateKey: PrivateKey) throws -> SignedTransaction {
        guard tx.chain.family == .evm else {
            throw SigningError.malformedDraft("EVMContractCallSigner used for \(tx.chain.rawValue)")
        }
        guard let chainId = EVMChainIdentity.chainId(for: tx.chain) else {
            throw SigningError.unsupportedCoin(tx.chain)
        }
        guard let coin = ChainCoinType.coinType(for: tx.chain) else {
            throw SigningError.unsupportedCoin(tx.chain)
        }

        var input = EthereumSigningInput()
        input.chainID = SigningNumeric.bigEndianData(fromUInt64: UInt64(chainId))
        input.nonce = SigningNumeric.bigEndianData(fromUInt64: tx.nonce)
        input.privateKey = privateKey.data
        input.toAddress = tx.to
        input.gasLimit = SigningNumeric.bigEndianData(fromUInt64: tx.gasLimit)
        input.txMode = .legacy
        input.gasPrice = SigningNumeric.bigEndianData(fromUInt64: tx.gasPriceWei)

        var transfer = EthereumTransaction.Transfer()
        transfer.amount = quantityToData(tx.valueHex)
        transfer.data = tx.data
        var transaction = EthereumTransaction()
        transaction.transfer = transfer
        input.transaction = transaction

        let output: EthereumSigningOutput = AnySigner.sign(input: input, coin: coin)
        guard !output.encoded.isEmpty else {
            throw SigningError.signingFailed("\(tx.chain.displayName): empty EVM signer output")
        }
        let rawData = output.encoded
        let txHash = "0x" + Hash.keccak256(data: rawData).map { String(format: "%02x", $0) }.joined()
        return SignedTransaction(
            rawData: rawData,
            rawHex: SigningNumeric.hexString0x(rawData),
            txHash: txHash
        )
    }
}
