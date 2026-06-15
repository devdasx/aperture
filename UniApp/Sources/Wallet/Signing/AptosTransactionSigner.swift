import Foundation
import WalletCore

/// Builds + signs Aptos transactions (native APT `0x1::aptos_account::
/// transfer`, a legacy coin-type transfer for `0x…::module::Name` assets,
/// or a Fungible-Asset transfer for `0x…` metadata-address assets) from
/// `SendDraft` + just-in-time data, adapted from Stabro's proven
/// `signAptosTransaction` onto Aperture's contracts.
///
/// **wallet-core SigningInput (Aptos.proto, WalletCore 4.6.13 — field
/// names verified against the pinned `arm64.swiftinterface` + the
/// upstream `AptosTests.swift` fixtures):**
/// `chainID` (1 = mainnet), `sender`, `sequenceNumber` (Int64, JIT),
/// `maxGasAmount`, `gasUnitPrice` (octas/gas, JIT), `expirationTimestampSecs`
/// (now+N), `privateKey`, and the payload oneof:
/// - native APT → `transfer = AptosTransferMessage{to, amount}`.
/// - legacy coin (`0x…::module::Name`) → `tokenTransferCoins =
///   AptosTokenTransferCoinsMessage{to, amount, function:StructTag}`.
/// - fungible asset (`0x…` metadata) → `fungibleAssetTransfer =
///   AptosFungibleAssetTransferMessage{metadataAddress, to, amount}`.
///
/// **Fee model (matrix §G… EVM-table addendum / Aptos docs):** fee =
/// gas_used × gas_unit_price (octas); `gasUnitPrice` from
/// `estimate_gas_price` (JIT), `maxGasAmount` from the resolved fee.
///
/// **JIT:** sequence_number (`accounts/{addr}`) + gas estimate
/// (`estimate_gas_price`). Broadcast: `POST /v1/transactions` with the
/// BCS bytes (`output.encoded`) and `Content-Type:
/// application/x.aptos.signed_transaction+bcs`. The node returns the hash.
///
/// Output: `output.encoded` is the BCS-serialized SIGNED transaction
/// (ready to submit); `output.rawTxn` is the unsigned raw txn (hash of it
/// would be the txn hash, but the node returns the canonical hash).
enum AptosTransactionSigner {

    /// Mainnet chain id.
    private static let mainnetChainID: UInt32 = 1
    /// Default gas price (octas/gas) when not resolved (matrix: live
    /// `estimate_gas_price` returned 100).
    private static let defaultGasUnitPrice: UInt64 = 100
    /// Default max gas amount (units) — generous headroom for a transfer.
    private static let defaultMaxGasAmount: UInt64 = 100_000
    /// Tx expiry window (now + 600s).
    private static let expirySeconds: UInt64 = 600

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .aptos else {
            throw SigningError.malformedDraft("Aptos signer used for \(draft.chain.rawValue)")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let sequenceNumber = jit.aptosSequenceNumber else {
            throw SigningError.justInTimeRefreshFailed("Aptos sequence number not refreshed")
        }
        guard let amount = SigningAmount.uint64(display: recipient.amount, decimals: draft.effectiveDecimals) else {
            throw SigningError.malformedDraft("invalid Aptos amount")
        }

        var input = AptosSigningInput()
        input.chainID = mainnetChainID
        input.sender = draft.fromAddress
        input.sequenceNumber = Int64(bitPattern: sequenceNumber)
        input.gasUnitPrice = jit.aptosGasUnitPrice ?? resolveGasUnitPrice(draft.fee.aptosGasUnitPrice)
        input.maxGasAmount = resolveMaxGas(draft.fee.aptosMaxGasAmount)
        input.expirationTimestampSecs = UInt64(Date().timeIntervalSince1970) + expirySeconds
        input.privateKey = privateKey.data

        if let contract = draft.tokenContract, !contract.isEmpty {
            if contract.contains("::") {
                // Legacy coin type 0xaddr::module::Name → transfer_coins.
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
                // Pure Fungible Asset (metadata address) → FA transfer.
                input.fungibleAssetTransfer = AptosFungibleAssetTransferMessage.with {
                    $0.metadataAddress = contract
                    $0.to = recipient.address
                    $0.amount = amount
                }
            }
        } else {
            // Native APT — 0x1::aptos_account::transfer.
            input.transfer = AptosTransferMessage.with {
                $0.to = recipient.address
                $0.amount = amount
            }
        }

        let output: AptosSigningOutput = AnySigner.sign(input: input, coin: .aptos)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "Aptos: empty AnySigner output" : output.errorMessage)
        }

        let rawData = output.encoded
        return SignedTransaction(
            rawData: rawData,
            // The broadcast wire form is the BCS bytes; we carry their hex
            // so the broadcaster (which submits raw BCS Data, not hex) can
            // also reconstruct/inspect. The Aptos broadcaster decodes back
            // from `rawData`.
            rawHex: SigningNumeric.hexString(rawData),
            txHash: "" // node returns the canonical hash at broadcast
        )
    }

    // MARK: - Helpers

    private static func resolveGasUnitPrice(_ value: Decimal?) -> UInt64 {
        guard let value, let n = SigningAmount.uint64(value), n > 0 else { return defaultGasUnitPrice }
        return n
    }

    private static func resolveMaxGas(_ value: Decimal?) -> UInt64 {
        guard let value, let n = SigningAmount.uint64(value), n > 0 else { return defaultMaxGasAmount }
        return n
    }
}
