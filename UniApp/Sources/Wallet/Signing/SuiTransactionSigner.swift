import Foundation
import WalletCore

/// Builds + signs Sui transactions (native SUI transfer / send-all, or a
/// `Coin<T>` token transfer) from `SendDraft` + just-in-time data,
/// adapted from Stabro's proven Sui path onto Aperture's contracts and
/// wallet-core's high-level Sui payloads.
///
/// **wallet-core SigningInput (Sui.proto, WalletCore 4.6.13 — field
/// names verified against the pinned `arm64.swiftinterface` + the
/// upstream `SuiTests.swift` `testSignDirect` fixture):**
/// `privateKey`, `gasBudget` (MIST), `referenceGasPrice` (MIST, JIT),
/// and a transaction payload oneof:
/// - `paySui` = `SuiPaySui{inputCoins:[ObjectRef], recipients, amounts}`
///   for native SUI (gas paid from the smashed input coins).
/// - `payAllSui` = `SuiPayAllSui{inputCoins, recipient}` for max/send-all.
/// - `pay` = `SuiPay{inputCoins, recipients, amounts, gas:ObjectRef}` for
///   a `Coin<T>` token transfer (a SEPARATE SUI gas coin is required).
///
/// `ObjectRef = SuiObjectRef{objectID, version, objectDigest}` — captured
/// live from `suix_getCoins` and re-fetched immediately before signing
/// (version bumps on every mutation → stale = rejected; Rule #27 §C).
///
/// **Fee model (matrix §G6, doc-grounded — gas-in-sui):** gasPrice ≥ RGP
/// (`suix_getReferenceGasPrice`), gasBudget auto-sized from a dry run /
/// safe default within [2,000 ; 50,000,000,000] MIST. The draft's
/// `FeeChoice.suiGasBudgetMist` / `suiGasPriceMist` resolve these.
///
/// **No memo** — Sui has no memo/tag/comment field (matrix §G6).
///
/// Output: `output.unsignedTx` + `output.signature` (both base64); the
/// broadcaster combines them for `sui_executeTransactionBlock`. The node
/// assigns the digest at broadcast (`txHash` left empty); we pass the
/// pair as `rawHex` = "<unsignedTx>:<signature>" exactly as the reference.
enum SuiTransactionSigner {

    /// Min/max gas budget guardrails (matrix §G6 doc-grounded).
    private static let minGasBudget: UInt64 = 2_000
    private static let maxGasBudget: UInt64 = 50_000_000_000
    /// Safe default budgets when the draft didn't carry a dry-run budget.
    private static let defaultNativeBudget: UInt64 = 4_000_000   // ~0.004 SUI
    private static let defaultTokenBudget: UInt64 = 5_000_000    // ~0.005 SUI

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .sui else {
            throw SigningError.malformedDraft("Sui signer used for \(draft.chain.rawValue)")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
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

        var input = SuiSigningInput()
        input.privateKey = privateKey.data
        input.referenceGasPrice = referenceGasPrice
        input.gasBudget = resolveBudget(draft: draft, isToken: draft.isTokenSend)

        if draft.isTokenSend {
            // Token (Coin<T>) send needs a SEPARATE SUI gas coin.
            guard let gas = jit.suiGasCoin else {
                throw SigningError.justInTimeRefreshFailed("Sui gas coin not refreshed for token send")
            }
            guard let amount = SigningAmount.uint64(display: recipient.amount, decimals: draft.effectiveDecimals) else {
                throw SigningError.malformedDraft("invalid Sui token amount")
            }
            input.pay = SuiPay.with {
                $0.inputCoins = inputRefs
                $0.recipients = [recipient.address]
                $0.amounts = [amount]
                $0.gas = SuiObjectRef.with {
                    $0.objectID = gas.objectId
                    $0.version = gas.version
                    $0.objectDigest = gas.digest
                }
            }
        } else if draft.isMaxSend {
            // Native send-all: PayAllSui (gas deducted from the smashed coin).
            input.payAllSui = SuiPayAllSui.with {
                $0.inputCoins = inputRefs
                $0.recipient = recipient.address
            }
        } else {
            guard let amount = SigningAmount.uint64(display: recipient.amount, decimals: draft.chain.nativeDecimals) else {
                throw SigningError.malformedDraft("invalid SUI amount")
            }
            input.paySui = SuiPaySui.with {
                $0.inputCoins = inputRefs
                $0.recipients = [recipient.address]
                $0.amounts = [amount]
            }
        }

        let output: SuiSigningOutput = AnySigner.sign(input: input, coin: .sui)
        guard output.error == .ok, !output.unsignedTx.isEmpty, !output.signature.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "Sui: empty AnySigner output" : output.errorMessage)
        }

        let combined = "\(output.unsignedTx):\(output.signature)"
        return SignedTransaction(
            rawData: Data(combined.utf8),
            rawHex: combined, // "<unsignedTx base64>:<signature base64>"
            txHash: ""        // node assigns the digest at broadcast
        )
    }

    /// Resolve the gas budget from the draft (dry-run-sized when present),
    /// clamped into the protocol's [min, max] MIST range.
    private static func resolveBudget(draft: SendDraft, isToken: Bool) -> UInt64 {
        let fallback = isToken ? defaultTokenBudget : defaultNativeBudget
        let raw = draft.fee.suiGasBudgetMist.flatMap { SigningAmount.uint64($0) } ?? fallback
        return min(max(raw, minGasBudget), maxGasBudget)
    }
}
