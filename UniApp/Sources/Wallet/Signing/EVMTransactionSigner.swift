import Foundation
import WalletCore

/// Builds + signs EVM transactions (native coin + ERC-20 transfer) for
/// all 12 EVM chains, adapted from Stabro's proven `signEVMTransaction`
/// (`TransactionSigner.swift`) onto Aperture's `SendDraft` / `FeeChoice`.
///
/// **What it produces.** A `SignedTransaction` whose `rawHex` is the
/// `0x`-prefixed RLP ready for `eth_sendRawTransaction`, and whose
/// `txHash` is `0x` + keccak256(rawData) — the canonical EVM tx hash
/// (the reference computes the hash the same way).
///
/// **Fee model (matrix §G2, doc-grounded).**
/// - EIP-1559 (every EVM chain except BNB): `txMode = .enveloped`, set
///   `maxFeePerGas` + `maxInclusionFeePerGas` (the tip) from the draft's
///   `FeeChoice`; leave `gasPrice` empty. Invariant enforced:
///   `maxFeePerGas >= maxPriorityFeePerGas` (else the tx is invalid) —
///   the reference applies the same +20% headroom clamp.
/// - Legacy (BNB): `txMode = .legacy`, set `gasPrice` only.
/// - OP-stack L2s + zkSync + Arbitrum: sign a STANDARD Type-2 tx — the
///   L1/pubdata surcharge is charged by the sequencer, NOT a tx field
///   (matrix §G2 L2 addendum). Arbitrum's L1 cost is already folded into
///   the gasLimit the estimator returned.
///
/// **Native vs token.** Native: `to = recipient`, `value = amount`, no
/// data. ERC-20: `to = contract`, `value = 0`, `data = transfer(to,amt)`
/// (matrix §G2 — the user's amount rides in the calldata, not `value`).
///
/// Pure compute, `nonisolated` — runs inside the executor's off-main
/// task (Rule #28). The `PrivateKey` is supplied by `SigningKeyProvider`
/// and lives only for this call's scope.
enum EVMTransactionSigner {

    /// Just-in-time chain data the signer needs, refreshed immediately
    /// before building the SigningInput (Rule #27 §C). Carries the live
    /// pending nonce so consecutive sends don't collide.
    struct JustInTime: Sendable {
        /// `eth_getTransactionCount(addr, "pending")` — live nonce.
        let nonce: UInt64
    }

    /// Build + sign. `draft` is the validated compose output; `jit` is
    /// the freshly-refreshed nonce; `privateKey` is the live signing key
    /// (parity already enforced by the provider).
    static func sign(
        draft: SendDraft,
        jit: JustInTime,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain.family == .evm else {
            throw SigningError.malformedDraft("EVM signer used for \(draft.chain.rawValue)")
        }
        guard let chainId = EVMChainIdentity.chainId(for: draft.chain) else {
            throw SigningError.unsupportedCoin(draft.chain)
        }
        guard let coin = ChainCoinType.coinType(for: draft.chain) else {
            throw SigningError.unsupportedCoin(draft.chain)
        }
        // EVM is single-recipient in Aperture's compose (matrix §G2 —
        // multi-recipient needs a disperse contract, out of scope).
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }

        var input = EthereumSigningInput()
        input.chainID = SigningNumeric.bigEndianData(fromUInt64: UInt64(chainId))
        input.nonce = SigningNumeric.bigEndianData(fromUInt64: jit.nonce)
        input.privateKey = privateKey.data

        // Gas limit (units) from the resolved fee. Defaults are the
        // matrix's doc-grounded floors (native 21,000; ERC-20 100,000).
        let gasLimit = uint64(from: draft.fee.gasLimit) ?? (draft.isTokenSend ? 100_000 : 21_000)
        input.gasLimit = SigningNumeric.bigEndianData(fromUInt64: gasLimit)

        // Fee fields per model.
        if EVMChainIdentity.usesEIP1559(draft.chain) {
            input.txMode = .enveloped
            var maxFee = uint64(from: draft.fee.maxFeePerGasWei) ?? 30_000_000_000
            let tip = uint64(from: draft.fee.maxPriorityFeePerGasWei) ?? 1_500_000_000
            // EIP-1559 invariant: maxFeePerGas >= maxPriorityFeePerGas.
            if maxFee < tip { maxFee = tip + (tip / 5) } // +20% headroom
            input.maxFeePerGas = SigningNumeric.bigEndianData(fromUInt64: maxFee)
            input.maxInclusionFeePerGas = SigningNumeric.bigEndianData(fromUInt64: tip)
        } else {
            input.txMode = .legacy
            let gasPrice = uint64(from: draft.fee.gasPriceWei) ?? 5_000_000_000
            input.gasPrice = SigningNumeric.bigEndianData(fromUInt64: gasPrice)
        }

        // Recipient + value/data per native-vs-token.
        var transfer = EthereumTransaction.Transfer()
        if draft.isTokenSend {
            guard let contract = draft.tokenContract else {
                throw SigningError.malformedDraft("token send missing contract")
            }
            input.toAddress = contract
            let amountBase = baseUnitsString(recipient.amount, decimals: draft.effectiveDecimals)
            guard let callData = SigningNumeric.erc20TransferCallData(
                to: recipient.address, amountBaseUnits: amountBase
            ) else {
                throw SigningError.malformedDraft("could not encode ERC-20 transfer calldata")
            }
            transfer.amount = Data([0]) // 0 native value for a token send
            transfer.data = callData
        } else {
            input.toAddress = recipient.address
            let amountBase = baseUnitsString(recipient.amount, decimals: draft.effectiveDecimals)
            guard let amountData = SigningNumeric.bigEndianData(fromBaseUnitsString: amountBase) else {
                throw SigningError.malformedDraft("invalid native amount")
            }
            transfer.amount = amountData
            transfer.data = Data()
        }

        var transaction = EthereumTransaction()
        transaction.transfer = transfer
        input.transaction = transaction

        let output: EthereumSigningOutput = AnySigner.sign(input: input, coin: coin)
        guard !output.encoded.isEmpty else {
            throw SigningError.signingFailed("\(draft.chain.displayName): empty AnySigner output")
        }

        let rawData = output.encoded
        let txHash = "0x" + Hash.keccak256(data: rawData).map { String(format: "%02x", $0) }.joined()
        return SignedTransaction(
            rawData: rawData,
            rawHex: SigningNumeric.hexString0x(rawData),
            txHash: txHash
        )
    }

    // MARK: - Helpers

    /// Convert a whole-base-units `Decimal` (≤ UInt64) to `UInt64`.
    /// `nil` when absent or out of range. Used for the gas/fee fields,
    /// which are comfortably within 64 bits (max realistic maxFeePerGas
    /// ~10^12 wei, gasLimit ~10^7).
    private static func uint64(from value: Decimal?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        var rounded = Decimal.zero
        var input = value
        NSDecimalRound(&rounded, &input, 0, .down)
        let n = NSDecimalNumber(decimal: rounded)
        guard n.compare(NSDecimalNumber(value: UInt64.max)) != .orderedDescending else { return nil }
        return n.uint64Value
    }

    /// Display amount (`Decimal`, e.g. 1.5) → base-units integer string
    /// (e.g. "1500000000000000000") at `decimals`. Money math stays in
    /// `Decimal` end-to-end (Rule); the string is the exact wire form
    /// `SigningNumeric` consumes for full u256 precision.
    private static func baseUnitsString(_ display: Decimal, decimals: Int) -> String {
        let base = ComposeDecimal.toBaseUnits(display, decimals: decimals)
        // toBaseUnits already rounds to an integer; render without a
        // decimal point or exponent via NSDecimalNumber.
        return NSDecimalNumber(decimal: base).stringValue
    }
}
