import Foundation
import WalletCore

/// Builds + signs XRP Ledger transactions (native XRP `Payment` with a
/// destination tag, or an issued-currency/IOU payment) from `SendDraft` +
/// just-in-time data, adapted from Stabro's proven `signRippleTransaction`
/// onto Aperture's contracts.
///
/// **wallet-core SigningInput (Ripple.proto, WalletCore 4.6.13 — field
/// names verified against the pinned `arm64.swiftinterface`):**
/// `fee` (Int64 drops), `sequence` (UInt32 account sequence, JIT),
/// `lastLedgerSequence` (UInt32 = current ledger + buffer, JIT; tx
/// expiry), `account` (sender r…), `sourceTag`, `privateKey`, and the
/// operation oneof `opPayment = RippleOperationPayment{amountOneof
/// (amount Int64 drops | currencyAmount {currency,value,issuer}),
/// destination, destinationTag}`.
///
/// **Fee model (matrix §G8, doc-grounded — transaction-cost):** fixed
/// burned drops (base 10), scaled by load. `FeeChoice.xrpDrops` resolves
/// the bid; clamp to ≥10 drops.
///
/// **Destination tag (matrix §G8):** the single most important non-amount
/// field — exchanges require it; carried in the draft's memo as
/// `.destinationTag(uint32)`.
///
/// Output: `output.encoded` is the signed binary tx; the broadcast wire
/// form is its hex; the txid is sha512_256(encoded) uppercased (XRPL
/// hashes the signed blob with SHA-512Half).
enum RippleTransactionSigner {

    /// Minimum reference cost (drops) for a standard Payment (matrix §G8).
    private static let minFeeDrops: Int64 = 10

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .ripple else {
            throw SigningError.malformedDraft("XRP signer used for \(draft.chain.rawValue)")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let sequence = jit.xrpSequence else {
            throw SigningError.justInTimeRefreshFailed("XRP account sequence not refreshed")
        }

        var payment = RippleOperationPayment()
        payment.destination = recipient.address
        if case .destinationTag(let tag) = draft.memo {
            payment.destinationTag = tag
        }

        if draft.isTokenSend {
            // Issued-currency (IOU) payment: {currency, value, issuer}.
            // The token contract carries "CODE:ISSUER" (the compose form).
            guard let (currency, issuer) = parseAsset(draft.tokenContract) else {
                throw SigningError.malformedDraft("XRP token send needs CODE:ISSUER")
            }
            // IOU value is a decimal string (up to 15 sig digits) in the
            // token's display units — XRPL amounts for issued currencies
            // are decimal, not drops.
            payment.currencyAmount = RippleCurrencyAmount.with {
                $0.currency = currency
                $0.value = NSDecimalNumber(decimal: recipient.amount).stringValue
                $0.issuer = issuer
            }
        } else {
            guard let drops = SigningAmount.int64(display: recipient.amount, decimals: draft.chain.nativeDecimals) else {
                throw SigningError.malformedDraft("invalid XRP amount")
            }
            payment.amount = drops
        }

        var input = RippleSigningInput()
        input.account = draft.fromAddress
        input.fee = resolveFee(draft.fee.xrpDrops)
        input.sequence = sequence
        input.privateKey = privateKey.data
        input.opPayment = payment
        if let lastLedger = jit.xrpLastLedgerSequence {
            input.lastLedgerSequence = lastLedger
        }

        let output: RippleSigningOutput = AnySigner.sign(input: input, coin: .xrp)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "XRP: empty AnySigner output" : output.errorMessage)
        }

        let rawData = output.encoded
        // XRPL transaction id = SHA-512Half (first 32 bytes of SHA-512) of
        // the TransactionID-prefixed signed blob, uppercase hex. XRPL
        // namespace-biases every hash with a 4-byte big-endian prefix; the
        // signed-transaction hash uses the "TXN\0" prefix 0x54584E00. The
        // prefix MUST be prepended before hashing — hashing `output.encoded`
        // alone yields a value that does not match the on-ledger tx hash.
        // Doc: xrpl.org Basic Data Types → Hash Prefixes ("Signed
        // Transaction … 0x54584E00 / TXN\0"); corroborated by
        // XRPLF/xrpl.js ripple-binary-codec hash-prefixes.ts
        // (`transactionID = 0x54584e00`, written big-endian).
        let transactionIDPrefix = Data([0x54, 0x58, 0x4E, 0x00])
        let txHash = Hash.sha512_256(data: transactionIDPrefix + rawData)
            .map { String(format: "%02X", $0) }.joined()
        return SignedTransaction(
            rawData: rawData,
            rawHex: SigningNumeric.hexString(rawData), // bare hex for `submit` tx_blob
            txHash: txHash
        )
    }

    // MARK: - Helpers

    private static func resolveFee(_ value: Decimal?) -> Int64 {
        let raw = value.flatMap { SigningAmount.int64($0) } ?? minFeeDrops
        return max(raw, minFeeDrops)
    }

    private static func parseAsset(_ contract: String?) -> (currency: String, issuer: String)? {
        guard let contract else { return nil }
        let parts = contract.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
