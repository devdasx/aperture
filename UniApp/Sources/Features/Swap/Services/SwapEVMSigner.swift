import Foundation
import WalletCore

/// Signs an ARBITRARY EVM transaction (router swap calldata or an ERC-20
/// `approve`) — the piece `EVMTransactionSigner` can't do (it only encodes
/// a native or ERC-20 `transfer` from a `SendDraft`). Mirrors that signer's
/// proven shape (and Stabro's `signRawEVM`): a wallet-core
/// `EthereumTransaction.Transfer` with `amount = value` and `data =
/// calldata` to an arbitrary `toAddress` — which is exactly a generic
/// contract call.
///
/// **Legacy fee mode, on purpose.** Swaps sign as a Type-0 (legacy) tx with
/// a single `gasPrice`. Legacy txs are valid and accepted on every EVM
/// chain (including EIP-1559 chains), which keeps execution robust without
/// per-chain 1559 base-fee estimation — the gas PRICE comes from Li.Fi's
/// `transactionRequest.gasPrice` (or a fresh `eth_gasPrice` for the
/// self-built approve tx), and the gas LIMIT from Li.Fi (+ buffer) or a
/// safe approve default.
///
/// Pure compute, `nonisolated` — runs inside the executor's off-main task
/// (Rule #28). The `PrivateKey` is supplied by `SigningKeyProvider` and
/// lives only for this call's scope.
enum SwapEVMSigner {

    /// A ready-to-sign EVM transaction. All values already resolved by the
    /// executor (nonce fetched live, gas resolved, calldata from Li.Fi or
    /// the approve encoder).
    struct UnsignedTx: Sendable {
        let chain: SupportedChain
        let nonce: UInt64
        /// Router (swap) or token contract (approve).
        let to: String
        /// Native value in hex (`"0x.."`); `"0x0"` for an ERC-20 approve
        /// and for ERC-20-input swaps.
        let valueHex: String
        /// ABI-encoded calldata (the router swap call, or `approve(...)`).
        let data: Data
        let gasLimit: UInt64
        let gasPriceWei: UInt64
    }

    static func sign(_ tx: UnsignedTx, privateKey: PrivateKey) throws -> SignedTransaction {
        guard tx.chain.family == .evm else {
            throw SigningError.malformedDraft("SwapEVMSigner used for \(tx.chain.rawValue)")
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
        transfer.amount = SwapEVMABI.quantityToData(tx.valueHex)
        transfer.data = tx.data
        var transaction = EthereumTransaction()
        transaction.transfer = transfer
        input.transaction = transaction

        let output: EthereumSigningOutput = AnySigner.sign(input: input, coin: coin)
        guard !output.encoded.isEmpty else {
            throw SigningError.signingFailed("\(tx.chain.displayName): empty swap signer output")
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
