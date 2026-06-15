import Foundation
import WalletCore

/// Builds + signs Stellar transactions (native XLM + alphanum4 asset
/// payment, or create_account for an unfunded destination, with the five
/// memo types) from `SendDraft` + just-in-time data, adapted from
/// Stabro's proven `signStellarTransaction` onto Aperture's contracts.
///
/// **wallet-core SigningInput (Stellar.proto, WalletCore 4.6.13 —
/// field names verified against the pinned `arm64.swiftinterface`):**
/// `account` (G… sender), `passphrase` (network passphrase string),
/// `fee` (Int32 per-op base-fee bid in stroops), `sequence` (Int64 =
/// account sequence + 1, JIT), the operation oneof (`opPayment` /
/// `opCreateAccount`), and a memo oneof (`memoVoid` / `memoText` ≤28
/// bytes / `memoID` uint64 / `memoHash` 32 bytes / `memoReturnHash`).
/// Output `output.signature` is the base64 XDR envelope.
///
/// **Fee model (matrix §G5, doc-grounded — fees-resource-limits):**
/// per-operation inclusion fee = opCount × base-fee bid (≥100 stroops/op).
/// `FeeChoice.stellarPerOpStroops` is the bid; 1 op for a simple payment.
///
/// **Activation:** sending native XLM to an UNFUNDED (HTTP 404)
/// destination MUST use `create_account` with startingBalance ≥ the
/// dest's min balance — `draft.recipientNeedsActivation` selects it.
/// A token (asset) send to an unfunded/no-trustline dest fails on-ledger
/// (op_no_trust) — compose gates that; the signer always emits a Payment
/// for a token send.
///
/// **wallet-core limitation (matrix §G5, verified in Signer.cpp):** the
/// upstream Stellar signer encodes ONLY native + `credit_alphanum4`
/// assets (codes ≤4 chars). An alphanum12 code can't ride wallet-core's
/// SigningInput — the signer refuses honestly rather than sign a
/// truncated/wrong asset.
///
/// Output: base64 XDR envelope for `POST /transactions` (tx=…); the
/// node assigns the tx hash at broadcast (`txHash` left empty).
enum StellarTransactionSigner {

    /// Public mainnet network passphrase (doc: stellar.org network
    /// passphrase). The whole signature commits to it; testnet is a
    /// different value and out of scope (mainnet-only app).
    private static let mainnetPassphrase = "Public Global Stellar Network ; September 2015"

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .stellar else {
            throw SigningError.malformedDraft("Stellar signer used for \(draft.chain.rawValue)")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let amount = SigningAmount.int64(display: recipient.amount, decimals: draft.effectiveDecimals) else {
            throw SigningError.malformedDraft("invalid Stellar amount")
        }
        // The tx sequence = account sequence + 1; the executor already
        // applied the +1 in its JIT fetch, so use it verbatim.
        guard let seq = jit.stellarSequence else {
            throw SigningError.justInTimeRefreshFailed("Stellar account sequence not refreshed")
        }
        let sequence = Int64(bitPattern: seq)

        let fee = Int32(clampingStroops(draft.fee.stellarPerOpStroops))

        var input = StellarSigningInput()
        input.account = draft.fromAddress
        input.passphrase = mainnetPassphrase
        input.fee = fee
        input.sequence = sequence
        input.privateKey = privateKey.data

        // Activation: unfunded native destination → create_account.
        if !draft.isTokenSend && draft.recipientNeedsActivation {
            input.opCreateAccount = StellarOperationCreateAccount.with {
                $0.destination = recipient.address
                $0.amount = amount // startingBalance (stroops)
            }
        } else {
            var payment = StellarOperationPayment()
            payment.destination = recipient.address
            payment.amount = amount
            if draft.isTokenSend {
                guard let (code, issuer) = parseAsset(draft.tokenContract) else {
                    throw SigningError.malformedDraft("Stellar token send needs CODE:ISSUER")
                }
                guard code.utf8.count <= 4 else {
                    // alphanum12 not encodable by wallet-core (matrix §G5).
                    throw SigningError.signingFailed("Stellar: asset codes longer than 4 characters aren't supported for sending yet")
                }
                payment.asset = StellarAsset.with {
                    $0.alphanum4 = code
                    $0.issuer = issuer
                }
            }
            input.opPayment = payment
        }

        applyMemo(&input, memo: draft.memo)

        let output: StellarSigningOutput = AnySigner.sign(input: input, coin: .stellar)
        guard output.error == .ok, !output.signature.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "Stellar: empty AnySigner output" : output.errorMessage)
        }

        let rawData = Data(output.signature.utf8)
        return SignedTransaction(
            rawData: rawData,
            rawHex: output.signature, // base64 XDR envelope for POST /transactions
            txHash: ""                // node assigns the hash at broadcast
        )
    }

    // MARK: - Helpers

    /// Map the draft's typed Stellar memo onto wallet-core's memo oneof
    /// (matrix §G5: text ≤28 bytes, id uint64, hash 32 bytes).
    private static func applyMemo(_ input: inout StellarSigningInput, memo: SendMemoValue) {
        switch memo {
        case .stellarMemo(.text(let text)):
            input.memoText = StellarMemoText.with { $0.text = String(text.prefix(28)) }
        case .stellarMemo(.id(let id)):
            input.memoID = StellarMemoId.with { $0.id = Int64(bitPattern: id) }
        case .stellarMemo(.hashHex(let hex)):
            if let data = SigningNumeric.hexToData(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex),
               data.count == 32 {
                input.memoHash = StellarMemoHash.with { $0.hash = data }
            } else {
                input.memoVoid = StellarMemoVoid()
            }
        case .text(let s):
            input.memoText = StellarMemoText.with { $0.text = String(s.prefix(28)) }
        default:
            input.memoVoid = StellarMemoVoid()
        }
    }

    /// Parse a `"CODE:ISSUER"` token contract string (the form the
    /// compose layer stores for Stellar assets).
    private static func parseAsset(_ contract: String?) -> (code: String, issuer: String)? {
        guard let contract else { return nil }
        let parts = contract.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// Clamp the per-op stroop bid to the ≥100-stroop network minimum
    /// (matrix §G5) and into Int32 range.
    private static func clampingStroops(_ value: Decimal?) -> Int64 {
        let raw = value.flatMap { SigningAmount.int64($0) } ?? 100
        let clamped = max(raw, 100)
        return min(clamped, Int64(Int32.max))
    }
}
