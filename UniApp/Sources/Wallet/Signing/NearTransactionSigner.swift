import Foundation
import WalletCore

/// Builds + signs NEAR transactions (native NEAR `Transfer` action, or a
/// NEP-141 fungible-token transfer = `storage_deposit` + `ft_transfer`
/// FunctionCall actions, with an optional FT memo) from `SendDraft` +
/// just-in-time data, adapted from Stabro's proven `signNearTransaction`
/// onto Aperture's contracts.
///
/// **wallet-core SigningInput (NEAR.proto, WalletCore 4.6.13 — field
/// names verified against the pinned `arm64.swiftinterface` + the
/// upstream `NEARTests.swift` fixture):**
/// `signerID`, `nonce` (access-key nonce + 1, JIT), `receiverID`,
/// `blockHash` (base58-DECODED recent block hash → 32 bytes, JIT),
/// `actions:[NEARAction]`, `privateKey`.
/// - Native: one `NEARAction.transfer = NEARTransfer{deposit}` where
///   `deposit` is the amount as a **16-byte LITTLE-endian** Borsh u128
///   (verified: the fixture sets `deposit = 01000000…` for value 1).
/// - FT (NEP-141): two FunctionCall actions on the token contract —
///   `storage_deposit{account_id}` (0.00125 NEAR, registers the
///   recipient) then `ft_transfer{receiver_id, amount, memo?}` (1
///   yoctoNEAR attached deposit, 30 Tgas).
///
/// **Fee model (matrix §G10, doc-grounded — protocol/transactions/gas):**
/// deterministic gas units × network gas_price; no user tip. Native
/// transfer ~0.45 Tgas; FT transfer 30 Tgas attached. The signer does
/// not set a gas PRICE field (network-set); it sets the FunctionCall gas
/// budgets.
///
/// **JIT:** access-key nonce + 1 and a recent block hash (≤24h old).
/// Broadcast: `send_tx` / `broadcast_tx_commit` (base64). Output:
/// `output.signedTransaction` (Borsh bytes); `output.hash` is the txid.
enum NearTransactionSigner {

    /// NEP-141 standard gas budgets (matrix §G10 / reference).
    private static let storageDepositGas: UInt64 = 10_000_000_000_000   // 10 Tgas
    private static let ftTransferGas: UInt64 = 30_000_000_000_000       // 30 Tgas
    /// 0.00125 NEAR minimum NEP-145 storage registration deposit.
    private static let storageDepositYocto = "1250000000000000000000"
    /// ft_transfer requires exactly 1 yoctoNEAR attached (anti-phishing).
    private static let oneYocto = "1"

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .near else {
            throw SigningError.malformedDraft("NEAR signer used for \(draft.chain.rawValue)")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let nonce = jit.nearNonce else {
            throw SigningError.justInTimeRefreshFailed("NEAR access-key nonce not refreshed")
        }
        guard let blockHashB58 = jit.nearBlockHash,
              let blockHash = WalletCore.Base58.decodeNoCheck(string: blockHashB58) else {
            throw SigningError.justInTimeRefreshFailed("NEAR recent block hash not refreshed")
        }

        var input = NEARSigningInput()
        input.signerID = draft.fromAddress
        input.nonce = nonce
        input.blockHash = blockHash
        input.privateKey = privateKey.data

        if draft.isTokenSend {
            guard let contract = draft.tokenContract, !contract.isEmpty else {
                throw SigningError.malformedDraft("NEP-141 send missing token contract")
            }
            // Both FunctionCall actions target the token contract.
            input.receiverID = contract

            // The transfer amount is a decimal STRING in the token's own
            // decimals (NEP-141 ft_transfer arg is a u128 string).
            let amountString = SigningAmount.baseUnitsString(display: recipient.amount, decimals: draft.effectiveDecimals)

            let storageArgs = try jsonArgs(["account_id": recipient.address])
            var storageCall = NEARFunctionCall()
            storageCall.methodName = "storage_deposit"
            storageCall.args = storageArgs
            storageCall.gas = storageDepositGas
            guard let storageDeposit = SigningAmount.u128LittleEndian(Decimal(string: storageDepositYocto) ?? 0) else {
                throw SigningError.malformedDraft("could not encode NEAR storage deposit")
            }
            storageCall.deposit = storageDeposit

            var transferArgs: [String: String] = ["receiver_id": recipient.address, "amount": amountString]
            if let memo = nearMemo(from: draft.memo) { transferArgs["memo"] = memo }
            var transferCall = NEARFunctionCall()
            transferCall.methodName = "ft_transfer"
            transferCall.args = try jsonArgs(transferArgs)
            transferCall.gas = ftTransferGas
            guard let oneYoctoData = SigningAmount.u128LittleEndian(Decimal(string: oneYocto) ?? 1) else {
                throw SigningError.malformedDraft("could not encode NEAR 1 yocto deposit")
            }
            transferCall.deposit = oneYoctoData

            input.actions = [
                NEARAction.with { $0.functionCall = storageCall },
                NEARAction.with { $0.functionCall = transferCall },
            ]
        } else {
            input.receiverID = recipient.address
            guard let deposit = SigningAmount.u128LittleEndian(display: recipient.amount, decimals: draft.chain.nativeDecimals) else {
                throw SigningError.malformedDraft("invalid NEAR amount")
            }
            input.actions = [
                NEARAction.with { $0.transfer = NEARTransfer.with { $0.deposit = deposit } }
            ]
        }

        let output: NEARSigningOutput = AnySigner.sign(input: input, coin: .near)
        guard output.error == .ok, !output.signedTransaction.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "NEAR: empty AnySigner output" : output.errorMessage)
        }

        let rawData = output.signedTransaction
        return SignedTransaction(
            rawData: rawData,
            rawHex: rawData.base64EncodedString(), // base64 for send_tx
            txHash: output.hash.hexString
        )
    }

    // MARK: - Helpers

    private static func jsonArgs(_ dict: [String: String]) throws -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            throw SigningError.malformedDraft("could not encode NEAR function-call args")
        }
        return data
    }

    private static func nearMemo(from memo: SendMemoValue) -> String? {
        switch memo {
        case .text(let s): return s.isEmpty ? nil : s
        default:           return nil
        }
    }
}
