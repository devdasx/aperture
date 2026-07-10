import Foundation
import WalletCore

/// Builds + signs Sui transactions (native SUI transfer / send-all, or a
/// `Coin<T>` token transfer) from `SendDraft` + just-in-time data.
///
/// **Multi-recipient (BUG-001):** `Pay` / `PaySui` take parallel
/// `recipients[]` + `amounts[]` arrays. Every draft recipient is included
/// — never only the first. `PayAllSui` remains single-recipient max only.
enum SuiTransactionSigner {

    private static let minGasBudget: UInt64 = 2_000
    private static let maxGasBudget: UInt64 = 50_000_000_000
    private static let defaultNativeBudget: UInt64 = 4_000_000
    private static let defaultTokenBudget: UInt64 = 5_000_000

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .sui else {
            throw SigningError.malformedDraft("Sui signer used for \(draft.chain.rawValue)")
        }
        let recipients = try SendRecipientSigning.requireRecipients(draft)
        guard let coins = jit.suiInputCoins, !coins.isEmpty else {
            throw SigningError.justInTimeRefreshFailed("Sui input coins not refreshed")
        }
        let rgp = jit.suiReferenceGasPrice
            ?? (draft.fee.suiGasPriceMist.flatMap { SigningAmount.uint64($0) })
        guard let referenceGasPrice = rgp, referenceGasPrice > 0 else {
            throw SigningError.justInTimeRefreshFailed("Sui reference gas price not refreshed")
        }

        let inputRefs = coins.map { ref in
            SuiObjectRef.with {
                $0.objectID = ref.objectId
                $0.version = ref.version
                $0.objectDigest = ref.digest
            }
        }

        var addresses: [String] = []
        var amounts: [UInt64] = []
        addresses.reserveCapacity(recipients.count)
        amounts.reserveCapacity(recipients.count)
        let amountDecimals = draft.isTokenSend ? draft.effectiveDecimals : draft.chain.nativeDecimals
        for r in recipients {
            guard let amount = SigningAmount.uint64(display: r.amount, decimals: amountDecimals) else {
                throw SigningError.malformedDraft(draft.isTokenSend ? "invalid Sui token amount" : "invalid SUI amount")
            }
            addresses.append(r.address)
            amounts.append(amount)
        }

        var input = SuiSigningInput()
        input.privateKey = privateKey.data
        input.referenceGasPrice = referenceGasPrice
        input.gasBudget = resolveBudget(draft: draft, isToken: draft.isTokenSend, recipientCount: recipients.count)

        if draft.isTokenSend {
            guard let gas = jit.suiGasCoin else {
                throw SigningError.justInTimeRefreshFailed("Sui gas coin not refreshed for token send")
            }
            input.pay = SuiPay.with {
                $0.inputCoins = inputRefs
                $0.recipients = addresses
                $0.amounts = amounts
                $0.gas = SuiObjectRef.with {
                    $0.objectID = gas.objectId
                    $0.version = gas.version
                    $0.objectDigest = gas.digest
                }
            }
        } else if draft.isMaxSend {
            // Single-recipient only (enforced by requireRecipients).
            guard let only = recipients.first else {
                throw SigningError.malformedDraft("no recipient")
            }
            input.payAllSui = SuiPayAllSui.with {
                $0.inputCoins = inputRefs
                $0.recipient = only.address
            }
        } else {
            input.paySui = SuiPaySui.with {
                $0.inputCoins = inputRefs
                $0.recipients = addresses
                $0.amounts = amounts
            }
        }

        let output: SuiSigningOutput = AnySigner.sign(input: input, coin: .sui)
        guard output.error == .ok, !output.unsignedTx.isEmpty, !output.signature.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "Sui: empty AnySigner output" : output.errorMessage)
        }

        let combined = "\(output.unsignedTx):\(output.signature)"
        return SignedTransaction(
            rawData: Data(combined.utf8),
            rawHex: combined,
            txHash: ""
        )
    }

    private static func resolveBudget(draft: SendDraft, isToken: Bool, recipientCount: Int) -> UInt64 {
        let fallback = isToken ? defaultTokenBudget : defaultNativeBudget
        // Slightly larger budget when paying many recipients in one PTB.
        let scaledFallback = fallback &* UInt64(max(1, min(recipientCount, 8)))
        let raw = draft.fee.suiGasBudgetMist.flatMap { SigningAmount.uint64($0) } ?? scaledFallback
        return min(max(raw, minGasBudget), maxGasBudget)
    }
}
