import Foundation
import WalletCore

/// Builds + signs Aptos transactions (native APT, coin, or FA transfer).
///
/// **Multi-recipient (BUG-001):** native multi uses
/// `0x1::aptos_account::batch_transfer` via WalletCore `anyEncoded`.
/// Token multi is refused honestly (no batch coin/FA path yet).
enum AptosTransactionSigner {

    private static let mainnetChainID: UInt32 = 1
    private static let defaultGasUnitPrice: UInt64 = 100
    static let minimumMaxGasAmount: UInt64 = 100_000
    private static let expirySeconds: UInt64 = 600

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .aptos else {
            throw SigningError.malformedDraft("Aptos signer used for \(draft.chain.rawValue)")
        }
        let recipients = try SendRecipientSigning.requireRecipients(draft)
        guard let sequenceNumber = jit.aptosSequenceNumber else {
            throw SigningError.justInTimeRefreshFailed("Aptos sequence number not refreshed")
        }

        var input = AptosSigningInput()
        input.chainID = mainnetChainID
        input.sender = draft.fromAddress
        input.sequenceNumber = Int64(bitPattern: sequenceNumber)
        input.gasUnitPrice = jit.aptosGasUnitPrice ?? resolveGasUnitPrice(draft.fee.aptosGasUnitPrice)
        input.maxGasAmount = resolveMaxGas(draft.fee.aptosMaxGasAmount, recipientCount: recipients.count)
        input.expirationTimestampSecs = UInt64(Date().timeIntervalSince1970) + expirySeconds
        input.privateKey = privateKey.data

        if let contract = draft.tokenContract, !contract.isEmpty {
            // Token multi not supported yet — refuse rather than pay only first.
            guard recipients.count == 1, let recipient = recipients.first else {
                throw SigningError.signingFailed(
                    "Sending tokens to multiple recipients on Aptos isn't available yet"
                )
            }
            guard let amount = SigningAmount.uint64(display: recipient.amount, decimals: draft.effectiveDecimals) else {
                throw SigningError.malformedDraft("invalid Aptos amount")
            }
            if contract.contains("::") {
                let parts = contract.components(separatedBy: "::")
                guard parts.count == 3 else {
                    throw SigningError.malformedDraft("Aptos coin type must be 0xADDR::module::Name")
                }
                input.tokenTransferCoins = AptosTokenTransferCoinsMessage.with {
                    $0.to = recipient.address
                    $0.amount = amount
                    $0.function = AptosStructTag.with {
                        $0.accountAddress = parts[0]
                        $0.module = parts[1]
                        $0.name = parts[2]
                    }
                }
            } else {
                input.fungibleAssetTransfer = AptosFungibleAssetTransferMessage.with {
                    $0.metadataAddress = contract
                    $0.to = recipient.address
                    $0.amount = amount
                }
            }
        } else if recipients.count == 1, let recipient = recipients.first {
            guard let amount = SigningAmount.uint64(display: recipient.amount, decimals: draft.effectiveDecimals) else {
                throw SigningError.malformedDraft("invalid Aptos amount")
            }
            input.transfer = AptosTransferMessage.with {
                $0.to = recipient.address
                $0.amount = amount
            }
        } else {
            // Native multi → batch_transfer via anyEncoded entry payload.
            let addresses = recipients.map(\.address)
            var amountStrings: [String] = []
            amountStrings.reserveCapacity(recipients.count)
            for r in recipients {
                guard let amount = SigningAmount.uint64(display: r.amount, decimals: draft.effectiveDecimals) else {
                    throw SigningError.malformedDraft("invalid Aptos amount")
                }
                amountStrings.append(String(amount))
            }
            let addressesJSON = try jsonStringArray(addresses)
            let amountsJSON = try jsonStringArray(amountStrings)
            input.anyEncoded = """
            {
                "function": "0x1::aptos_account::batch_transfer",
                "type_arguments": [],
                "arguments": [\(addressesJSON), \(amountsJSON)],
                "type": "entry_function_payload"
            }
            """
            input.abi = """
            ["vector<address>", "vector<u64>"]
            """
        }

        let output: AptosSigningOutput = AnySigner.sign(input: input, coin: .aptos)
        guard output.error == .ok, !output.encoded.isEmpty else {
            let reason = output.errorMessage.isEmpty ? "Aptos: empty AnySigner output" : output.errorMessage
            throw SigningError.signingFailed(reason)
        }

        let rawData = output.encoded
        return SignedTransaction(
            rawData: rawData,
            rawHex: SigningNumeric.hexString(rawData),
            txHash: ""
        )
    }

    // MARK: - Helpers

    private static func resolveGasUnitPrice(_ value: Decimal?) -> UInt64 {
        guard let value, let n = SigningAmount.uint64(value), n > 0 else { return defaultGasUnitPrice }
        return n
    }

    static func resolveMaxGas(_ value: Decimal?) -> UInt64 {
        resolveMaxGas(value, recipientCount: 1)
    }

    static func resolveMaxGas(_ value: Decimal?, recipientCount: Int) -> UInt64 {
        let scaledMinimum = minimumMaxGasAmount &* UInt64(max(1, min(recipientCount, 20)))
        guard let value, let n = SigningAmount.uint64(value), n > 0 else { return scaledMinimum }
        return max(n, scaledMinimum)
    }

    /// JSON array of JSON strings (each element quoted).
    private static func jsonStringArray(_ values: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values, options: [])
        guard let s = String(data: data, encoding: .utf8) else {
            throw SigningError.malformedDraft("could not encode Aptos batch arguments")
        }
        return s
    }
}
