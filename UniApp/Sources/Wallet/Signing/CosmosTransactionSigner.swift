import Foundation
import WalletCore

/// Builds + signs Kava (Cosmos SDK) transactions — a bank `MsgSend` of
/// `ukava` (native) or any other held denom (token), with an optional
/// memo + a gas-limit × gas-price fee — from `SendDraft` + just-in-time
/// data, adapted from Stabro's proven `signCosmosTransaction` /
/// `KavaTransactionBuilder` onto Aperture's contracts and wallet-core's
/// native Cosmos signer.
///
/// **wallet-core SigningInput (Cosmos.proto, WalletCore 4.6.13 — field
/// names verified against the pinned `arm64.swiftinterface` + the
/// upstream `CosmosTests.swift` fixture):**
/// `signingMode = .protobuf` (Stargate/Direct), `accountNumber` (JIT),
/// `chainID` ("kava_2222-10"), `sequence` (JIT), `memo`, `fee =
/// CosmosFee{gas, amounts:[CosmosAmount{denom:"ukava", amount}]}`,
/// `messages:[CosmosMessage{sendCoinsMessage = Send{fromAddress,
/// toAddress, amounts:[CosmosAmount{denom, amount}]}}]`, `privateKey`.
///
/// **Fee model (matrix §G12, doc-grounded — node-config + chain-registry):**
/// fee = ceil(gas_limit × gas_price) ukava. Default gas 200,000; gas
/// price tiers low 0.05 / avg 0.1 / high 0.25 ukava/gas (≥0.001 node
/// floor). `FeeChoice.cosmosGasLimit` + `.cosmosGasPrice` resolve these;
/// the fee is ALWAYS paid in ukava even for a token send.
///
/// **Memo (matrix §G12):** the Cosmos universal tag — exchanges require
/// it; ≤512 chars; carried in the draft's `.text` memo.
///
/// **Token send:** a MsgSend with the token's denom (the draft's
/// `tokenContract` holds the denom, e.g. `usdx`, `swp`, `ibc/…`). Fee
/// still in ukava.
///
/// Output: `output.serialized` is the base64 TxRaw for `POST
/// /cosmos/tx/v1beta1/txs`; the node assigns the hash.
enum CosmosTransactionSigner {

    /// Kava chain id (matrix §G12, verified via staking params / registry).
    private static let chainID = "kava_2222-10"
    /// Native bank denom.
    private static let nativeDenom = "ukava"
    /// Default gas limit for a single MsgSend (matrix §G12 — 200,000 covers
    /// the message + signature verification with margin).
    private static let defaultGasLimit: UInt64 = 200_000
    /// Default gas price (ukava/gas) — chain-registry AVERAGE tier.
    private static let defaultGasPrice = Decimal(string: "0.1") ?? 0
    /// Node floor (matrix §G12).
    private static let minGasPrice = Decimal(string: "0.001") ?? 0
    /// Chain memo cap.
    private static let maxMemoChars = 512

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .kava else {
            throw SigningError.malformedDraft("Cosmos signer used for \(draft.chain.rawValue)")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let accountNumber = jit.cosmosAccountNumber else {
            throw SigningError.justInTimeRefreshFailed("Kava account number not refreshed")
        }
        guard let sequence = jit.cosmosSequence else {
            throw SigningError.justInTimeRefreshFailed("Kava account sequence not refreshed")
        }

        // Send denom + amount. Native = ukava; token = the held denom.
        let denom: String
        let decimals: Int
        if draft.isTokenSend {
            guard let tokenDenom = draft.tokenContract, !tokenDenom.isEmpty else {
                throw SigningError.malformedDraft("Kava token send missing denom")
            }
            denom = tokenDenom
            decimals = draft.effectiveDecimals
        } else {
            denom = nativeDenom
            decimals = draft.chain.nativeDecimals
        }
        let sendAmount = SigningAmount.baseUnitsString(display: recipient.amount, decimals: decimals)
        guard sendAmount != "0" else {
            throw SigningError.malformedDraft("invalid Kava amount")
        }

        // Fee: ceil(gas_limit × gas_price) ukava (always native).
        let gasLimit = resolveGasLimit(draft.fee.cosmosGasLimit)
        let gasPrice = resolveGasPrice(draft.fee.cosmosGasPrice)
        let feeUkava = ceilToInt(Decimal(gasLimit) * gasPrice)

        let send = CosmosMessage.Send.with {
            $0.fromAddress = draft.fromAddress
            $0.toAddress = recipient.address
            $0.amounts = [CosmosAmount.with {
                $0.denom = denom
                $0.amount = sendAmount
            }]
        }
        let message = CosmosMessage.with { $0.sendCoinsMessage = send }

        let fee = CosmosFee.with {
            $0.gas = gasLimit
            $0.amounts = [CosmosAmount.with {
                $0.denom = nativeDenom
                $0.amount = feeUkava
            }]
        }

        var input = CosmosSigningInput()
        input.signingMode = .protobuf
        input.accountNumber = accountNumber
        input.chainID = chainID
        input.sequence = sequence
        input.messages = [message]
        input.fee = fee
        input.privateKey = privateKey.data
        if let memo = cosmosMemo(from: draft.memo) {
            input.memo = String(memo.prefix(maxMemoChars))
        }

        let output: CosmosSigningOutput = AnySigner.sign(input: input, coin: .kava)
        guard output.error == .ok, !output.serialized.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "Kava: empty AnySigner output" : output.errorMessage)
        }

        return SignedTransaction(
            rawData: Data(output.serialized.utf8),
            rawHex: output.serialized, // base64 TxRaw for POST /cosmos/tx/v1beta1/txs
            txHash: ""                 // node assigns the hash at broadcast
        )
    }

    // MARK: - Helpers

    private static func resolveGasLimit(_ value: Decimal?) -> UInt64 {
        guard let value, let n = SigningAmount.uint64(value), n > 0 else { return defaultGasLimit }
        return n
    }

    private static func resolveGasPrice(_ value: Decimal?) -> Decimal {
        let price = value ?? defaultGasPrice
        return max(price, minGasPrice)
    }

    /// ceil(x) as a decimal-integer String (Cosmos fee amount must be a
    /// whole ukava integer).
    private static func ceilToInt(_ value: Decimal) -> String {
        var up = Decimal.zero
        var input = value
        NSDecimalRound(&up, &input, 0, .up)
        return NSDecimalNumber(decimal: up).stringValue
    }

    private static func cosmosMemo(from memo: SendMemoValue) -> String? {
        switch memo {
        case .text(let s): return s.isEmpty ? nil : s
        default:           return nil
        }
    }
}
