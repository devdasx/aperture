import Foundation
import WalletCore

/// Builds + signs Bitcoin-family transactions (BTC / LTC / BCH / DOGE)
/// from the draft's selected UTXOs, adapted from Stabro's proven
/// `signBitcoinTransactionMultiKey` (`TransactionSigner.swift`) onto
/// Aperture's `SendDraft` / `SelectedUTXO` / `FeeChoice`.
///
/// **What it produces.** A `SignedTransaction` whose `rawData` is the
/// full serialized signed tx, `rawHex` is the bare lowercase hex the
/// Esplora/BlockCypher/Blockchair broadcast endpoints want (no `0x`),
/// and `txHash` is wallet-core's `transactionID` (the txid). The
/// reference returns the same triple.
///
/// **wallet-core SigningInput (Bitcoin.proto, WalletCore 4.6.13 —
/// fields verified against the pinned checkout):**
/// `hashType` (per-coin, BCH OR's in SIGHASH_FORKID), `amount` (sats),
/// `byteFee` (sat/vB or sat/byte from the draft's `FeeChoice`),
/// `toAddress`, `changeAddress`, `coinType`, `useMaxAmount`,
/// `privateKey[]`, `utxo[]` (each `outPoint{hash=little-endian txid,
/// index, sequence}`, `amount`, `script`, `variant`), `scripts` map
/// (P2WPKH/P2SH redeem scripts), optional `outputOpReturn`, optional
/// `extraOutputs` (multi-recipient), `dustPolicy = .fixedDustThreshold`.
/// The planner (`AnySigner.plan`) computes fee/change/selection; the
/// signer then signs.
///
/// **Per-chain sighash + forks (matrix §G1, doc-grounded):**
/// - BTC/LTC: SegWit, BIP-143 sighash (`hashTypeForCoin`), RBF via
///   sequence ≤ 0xFFFFFFFD when the draft signals it.
/// - BCH: NO SegWit, BIP-143 + SIGHASH_FORKID (set by `hashTypeForCoin`
///   for `.bitcoinCash`), `coinType` required, sequence = 0xFFFFFFFF
///   (no RBF on BCH).
/// - DOGE: legacy sighash (no SegWit/forkid), `coinType` required,
///   sequence = 0xFFFFFFFF, soft-dust handled by the dust threshold.
///
/// Pure compute, `nonisolated` — runs in the executor's off-main task.
/// The `[PrivateKey]` come from `SigningKeyProvider.withBitcoinKeys`.
enum BitcoinTransactionSigner {

    /// Build + sign with the keys owning the selected UTXOs.
    ///
    /// `freshUTXOs` is the address's CURRENT unspent set, re-fetched
    /// immediately before signing (Rule #27 §C); when present it is
    /// preferred over the compose-time `draft.selectedUTXOs` so we never
    /// sign against an input spent between compose and sign. wallet-core's
    /// planner then selects + sizes change over whichever set we pass.
    static func sign(
        draft: SendDraft,
        privateKeys: [PrivateKey],
        freshUTXOs: [SelectedUTXO]? = nil
    ) throws -> SignedTransaction {
        guard draft.chain.family == .bitcoin else {
            throw SigningError.malformedDraft("Bitcoin signer used for \(draft.chain.rawValue)")
        }
        guard let coin = ChainCoinType.coinType(for: draft.chain) else {
            throw SigningError.unsupportedCoin(draft.chain)
        }
        guard !privateKeys.isEmpty else {
            throw SigningError.signingFailed("no signing keys for \(draft.chain.displayName)")
        }
        let candidateUTXOs = (freshUTXOs?.isEmpty == false) ? freshUTXOs! : draft.selectedUTXOs
        guard let utxos = candidateUTXOs, !utxos.isEmpty else {
            throw SigningError.malformedDraft("no UTXOs selected")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let byteFeeDec = draft.fee.byteFeeRate, byteFeeDec > 0 else {
            throw SigningError.malformedDraft("no fee rate")
        }
        let byteFee = NSDecimalNumber(decimal: byteFeeDec).int64Value
        let changeAddress = draft.changeAddress ?? draft.fromAddress

        // Primary recipient amount in sats (base units; Bitcoin family
        // uses 8 decimals — the matrix confirms satsPerCoin = 1e8).
        let primarySats = sats(recipient.amount, decimals: draft.chain.nativeDecimals)

        var input = BitcoinSigningInput()
        input.hashType = BitcoinScript.hashTypeForCoin(coinType: coin)
        input.amount = primarySats
        input.byteFee = byteFee
        input.toAddress = recipient.address
        input.changeAddress = changeAddress
        input.coinType = coin.rawValue
        input.useMaxAmount = draft.isMaxSend
        input.privateKey = privateKeys.map(\.data)

        // Multi-recipient → extra outputs beyond the primary to_address.
        if draft.recipients.count > 1 {
            for extra in draft.recipients.dropFirst() {
                var out = BitcoinOutputAddress()
                out.toAddress = extra.address
                out.amount = sats(extra.amount, decimals: draft.chain.nativeDecimals)
                input.extraOutputs.append(out)
            }
        }

        // OP_RETURN data anchoring (advanced; matrix §G1).
        if let opReturn = draft.opReturn, !opReturn.isEmpty {
            input.outputOpReturn = opReturn
        }

        // Each selected UTXO → UnspentTransaction. The outpoint hash is
        // the txid in LITTLE-ENDIAN (network byte order) — the provider
        // returns big-endian display hex, so reverse it (the reference
        // does the same).
        for utxo in utxos {
            var outPoint = BitcoinOutPoint()
            if let txidData = SigningNumeric.hexToData(utxo.txid) {
                outPoint.hash = Data(txidData.reversed())
            }
            outPoint.index = UInt32(utxo.vout)
            // RBF: BTC/LTC signal opt-in BIP-125 (sequence ≤ 0xFFFFFFFD)
            // when the draft requests it; BCH/DOGE are always final
            // (0xFFFFFFFF — no RBF) per the matrix.
            let signalsRBF = draft.signalsRBF && (draft.chain == .bitcoin || draft.chain == .litecoin)
            outPoint.sequence = signalsRBF ? 0xFFFFFFFD : 0xFFFFFFFF

            var unspent = BitcoinUnspentTransaction()
            unspent.outPoint = outPoint
            unspent.amount = utxo.valueSats

            // Locking script: derived from the owning address via
            // wallet-core's `lockScriptForAddress` — the exact proven
            // path from the reference's `signBitcoinTransactionMultiKey`
            // (it derives the lock script for every input's address
            // rather than trusting a provider-supplied pkscript, so the
            // script is always the canonical one for the address type).
            let addr = ownerAddress(of: utxo, fallback: draft.fromAddress)
            let script = BitcoinScript.lockScriptForAddress(address: addr, coin: coin)
            unspent.script = script.data

            // Variant + redeem scripts by address type (mirrors the
            // reference's address-prefix branch).
            if addr.hasPrefix("bc1q") || addr.hasPrefix("ltc1q") {
                unspent.variant = .p2Wpkh
                if let scriptHash = script.matchPayToWitnessPublicKeyHash() {
                    input.scripts[scriptHash.hexString] = BitcoinScript.buildPayToPublicKeyHash(hash: scriptHash).data
                }
            } else if addr.hasPrefix("bc1p") {
                unspent.variant = .p2Trkeypath
            } else if addr.hasPrefix("3") || addr.hasPrefix("M") {
                unspent.variant = .p2Wpkh
                if let scriptHash = script.matchPayToScriptHash() {
                    input.scripts[scriptHash.hexString] = BitcoinScript.buildPayToPublicKeyHash(hash: scriptHash).data
                }
            } else {
                // Legacy P2PKH — BTC(1…), LTC(L…), DOGE(D…), BCH(q…/legacy).
                unspent.variant = .p2Pkh
            }

            input.utxo.append(unspent)
        }

        // DOGE: enforce the SOFT dust threshold (0.01 DOGE = 1,000,000
        // koinu) so the planner folds any sub-soft-dust change into the
        // fee rather than emitting a change output in the soft-dust band
        // [100,000, 1,000,000) koinu. Dogecoin Core treats outputs in
        // that band as "too low fee" unless an extra 0.01 DOGE per output
        // is added; a change output the planner emits there would be
        // rejected by the network. Setting the dust cutoff to the soft
        // limit makes wallet-core drop such change into the fee instead.
        // Matches `.claude/send-compose-matrix.md` (DOGE §G1) and
        // `UTXOService.SizeModel.softDustThreshold` (1,000,000 koinu).
        // Doc: Dogecoin Core doc/fee-recommendation.md — "Hard dust
        // limit: 0.001 DOGE … invalid and rejected"; "Soft dust limit:
        // 0.01 DOGE … required to add 0.01 DOGE for each such output, or
        // else … too low fee and be rejected". The legacy SigningInput
        // exposes the `dust_policy` oneof's value as a direct
        // `fixedDustThreshold` setter (verified against WalletCore
        // 4.6.13's BitcoinTests: `$0.fixedDustThreshold = N`).
        if draft.chain == .dogecoin {
            input.fixedDustThreshold = 1_000_000
        }

        // Run the planner for fee/change/selection, then sign (reference
        // pattern). The planner returns the exact fee + change.
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: coin)
        input.plan = plan

        let output: BitcoinSigningOutput = AnySigner.sign(input: input, coin: coin)
        guard output.error == .ok else {
            throw SigningError.signingFailed(bitcoinErrorReason(output.error))
        }
        guard !output.encoded.isEmpty else {
            throw SigningError.signingFailed("\(draft.chain.displayName): empty AnySigner output")
        }

        let rawData = output.encoded
        return SignedTransaction(
            rawData: rawData,
            rawHex: SigningNumeric.hexString(rawData), // bare hex, no 0x
            txHash: output.transactionID
        )
    }

    // MARK: - Helpers

    /// The address owning a UTXO. `SelectedUTXO` doesn't carry the owner
    /// address (the UTXO set fetch keys by the queried address), so for
    /// a single-address own send we use `fromAddress`. When a future
    /// multi-address UTXO model adds per-UTXO owner addresses, thread it
    /// through here; the lock-script derivation depends on it.
    private static func ownerAddress(of utxo: SelectedUTXO, fallback: String) -> String {
        fallback
    }

    /// Display amount → sats (base units) at `decimals`.
    private static func sats(_ display: Decimal, decimals: Int) -> Int64 {
        let base = ComposeDecimal.toBaseUnits(display, decimals: decimals)
        return NSDecimalNumber(decimal: base).int64Value
    }

    /// Map wallet-core's `CommonSigningError` to an honest reason string
    /// (mirrors the reference's switch). Never includes key material.
    private static func bitcoinErrorReason(_ error: CommonSigningError) -> String {
        switch error {
        case .errorNotEnoughUtxos: return "insufficient funds"
        case .errorMissingPrivateKey: return "missing key for one or more inputs"
        case .errorMissingInputUtxos: return "missing UTXO data"
        case .errorInvalidUtxo: return "invalid UTXO"
        case .errorInvalidUtxoAmount: return "invalid UTXO amount"
        case .errorInvalidAddress: return "invalid address"
        case .errorWrongFee: return "fee calculation error"
        default: return "signing failed (code \(error.rawValue))"
        }
    }
}
