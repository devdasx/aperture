import Foundation

/// Per-chain compose capability, doc-grounded in
/// `.claude/send-compose-matrix.md` (2026-06-15, live-verified). This is
/// the spec the Send amount/compose UI reads to decide which advanced
/// controls to show (fee model, UTXO selection, OP_RETURN, memo/tag,
/// reserve warnings) and which the future sign step honors.
///
/// Reserve/min-balance/existential-deposit/activation rules are encoded
/// as a `ReserveRule` so the amount-math + validator can compute the
/// real spendable balance and block sends that would brick an account.
struct ChainComposeCapability: Sendable, Hashable {

    /// Fee pricing model (drives `ComposeFeeService` + which fee fields
    /// the `FeeChoice` carries).
    let feeModel: ComposeFeeModel

    /// UTXO model (Bitcoin family): the compose screen fetches a UTXO
    /// set, runs coin selection, and re-estimates fee after selection.
    let supportsUTXO: Bool

    /// OP_RETURN data anchoring (Bitcoin family). `nil` = unsupported.
    /// The value is the max data bytes for broad relay compatibility.
    let opReturnMaxBytes: Int?

    /// The memo / destination-tag / comment kind this chain carries.
    let memoKind: ComposeMemoKind

    /// Max UTF-8 byte length of the memo field, where bounded. `nil` =
    /// not bounded by a small protocol cap (or no memo).
    let memoMaxBytes: Int?

    /// The reserve / min-balance / existential-deposit / activation rule
    /// that constrains spendable balance and send amount.
    let reserve: ReserveRule

    /// Max distinct recipients payable in one transaction (mirrors
    /// `ChainSendCapability.maxRecipients`, restated so the compose
    /// layer is self-contained).
    let maxRecipients: Int

    /// The on-chain decimals of the native coin (octa=8, wei=18, …).
    let nativeDecimals: Int

    /// Whether the chain can pay more than one recipient atomically.
    var supportsMultiRecipient: Bool { maxRecipients > 1 }
}

/// How a chain reserves part of an account's balance (so it can never be
/// spent without bricking/closing the account) and whether sending to a
/// brand-new recipient requires activation. All amounts are in the
/// chain's native units as `Decimal` (money math, never Double).
enum ReserveRule: Sendable, Hashable {

    /// No reserve, no activation (Bitcoin family, EVM, Sui, TON, Cosmos,
    /// TRON-for-existing-recipients). Spendable = balance − fee.
    case none

    /// XRP-style account reserve: `base` XRP locked + `perOwnedObject`
    /// XRP per owned object. Spendable = balance − base −
    /// (ownerCount × perOwnedObject) − fee. Sending to a non-existent
    /// account must deliver ≥ `base`.
    case xrpReserve(base: Decimal, perOwnedObject: Decimal)

    /// Stellar-style minimum balance: `(2 + subentryCount + sponsoring −
    /// sponsored) × baseReserve`. Spendable = balance − minBalance −
    /// sellingLiabilities − fee. CreateAccount to an unfunded dest must
    /// send ≥ a bare account's min (`baseReserve × 2`).
    case stellarReserve(baseReserve: Decimal)

    /// Polkadot existential deposit: an account dropping below `ed` is
    /// reaped and its funds destroyed. Spendable = free −
    /// max(frozen − reserved, ed) − fee (keep-alive default).
    case existentialDeposit(ed: Decimal)

    /// Solana rent-exempt minimum: the SOL account must hold ≥ `rent`
    /// lamports (as Decimal SOL) to stay onchain. Spendable = balance −
    /// rent − fee. ATA creation for a token recipient costs extra rent.
    case solanaRent(rent: Decimal)

    /// NEAR storage-staking reserve: storage_usage × per-byte rate must
    /// stay locked. Spendable = total − locked − storageReserve − fee.
    /// `perByte` is the storage_amount_per_byte rate; the actual reserve
    /// is computed live from the account's storage_usage.
    case nearStorage(perByte: Decimal)

    /// TRON one-off activation surcharge when sending to a never-
    /// activated address (~1.1 TRX). Not a standing reserve — a per-send
    /// extra cost detected via getaccount (empty = inactive).
    case tronActivation(surcharge: Decimal)

    /// Whether this rule implies a *standing* locked balance (vs a
    /// one-off activation cost). Standing reserves cap "Max"/send-all.
    var hasStandingReserve: Bool {
        switch self {
        case .none, .tronActivation:
            return false
        case .xrpReserve, .stellarReserve, .existentialDeposit, .solanaRent, .nearStorage:
            return true
        }
    }
}

extension ChainComposeCapability {

    /// The doc-grounded capability for a chain. The single source of
    /// truth the compose UI + amount math + validator read.
    static func capability(for chain: SupportedChain) -> ChainComposeCapability {
        let decimals = chain.nativeDecimals
        switch chain {

        // MARK: - Bitcoin family (UTXO)

        case .bitcoin:
            return ChainComposeCapability(
                feeModel: .utxoByteFee, supportsUTXO: true, opReturnMaxBytes: 80,
                memoKind: .none, memoMaxBytes: nil, reserve: .none,
                maxRecipients: 20, nativeDecimals: decimals)
        case .litecoin:
            return ChainComposeCapability(
                feeModel: .utxoByteFee, supportsUTXO: true, opReturnMaxBytes: 80,
                memoKind: .none, memoMaxBytes: nil, reserve: .none,
                maxRecipients: 20, nativeDecimals: decimals)
        case .bitcoinCash:
            return ChainComposeCapability(
                feeModel: .utxoByteFeeNoWitness, supportsUTXO: true, opReturnMaxBytes: 220,
                memoKind: .none, memoMaxBytes: nil, reserve: .none,
                maxRecipients: 20, nativeDecimals: decimals)
        case .dogecoin:
            return ChainComposeCapability(
                feeModel: .dogecoinFixedPerKB, supportsUTXO: true, opReturnMaxBytes: 80,
                memoKind: .none, memoMaxBytes: nil, reserve: .none,
                maxRecipients: 20, nativeDecimals: decimals)

        // MARK: - EVM core / per-chain quirks (account model)

        case .ethereum, .arbitrum, .avalanche:
            return evm(.evm1559, decimals: decimals)
        case .optimism, .base, .opBNB, .scroll:
            return evm(.evm1559PlusL1Data, decimals: decimals)
        case .zkSync:
            return evm(.zkSyncEra, decimals: decimals)
        case .polygon, .celo, .kavaEvm:
            // Polygon (25-gwei tip floor), Celo (fee-currency option),
            // Kava EVM (feemarket floor) — all 1559 with a per-chain
            // clamp applied in the fee service.
            return evm(.evm1559, decimals: decimals)
        case .bnbChain:
            return evm(.evmLegacy, decimals: decimals)

        // MARK: - Solana

        case .solana:
            // Rent-exempt minimum for a bare SOL account = 890,880
            // lamports = 0.00089088 SOL (live-verified). Refreshed via
            // getMinimumBalanceForRentExemption at compose time.
            return ChainComposeCapability(
                feeModel: .solana, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .splMemo, memoMaxBytes: 566,
                reserve: .solanaRent(rent: Decimal(string: "0.00089088")!),
                maxRecipients: 15, nativeDecimals: decimals)

        // MARK: - Stellar

        case .stellar:
            // Base reserve = 0.5 XLM (live base_reserve_in_stroops:5000000).
            return ChainComposeCapability(
                feeModel: .stellarPerOp, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .stellarMemo, memoMaxBytes: 28,
                reserve: .stellarReserve(baseReserve: Decimal(string: "0.5")!),
                maxRecipients: 20, nativeDecimals: decimals)

        // MARK: - Sui

        case .sui:
            // No activation/min-balance to receive (Rule #2 honesty:
            // do not show a reserve warning).
            return ChainComposeCapability(
                feeModel: .suiGasBudget, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .none, memoMaxBytes: nil, reserve: .none,
                maxRecipients: 20, nativeDecimals: decimals)

        // MARK: - TON

        case .ton:
            // Comment ≈123 bytes fit the root cell (1023 bits − 32-bit
            // opcode); snake encoding extends it, but exchange memos
            // are short.
            return ChainComposeCapability(
                feeModel: .tonFixed, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .tonComment, memoMaxBytes: 123, reserve: .none,
                maxRecipients: 4, nativeDecimals: decimals)

        // MARK: - XRP

        case .ripple:
            // Base reserve 1 XRP, owner reserve 0.2 XRP/object
            // (live reserve_base_xrp:1E0, reserve_inc_xrp:2E-1).
            return ChainComposeCapability(
                feeModel: .xrpFixed, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .destinationTag, memoMaxBytes: nil,
                reserve: .xrpReserve(base: 1, perOwnedObject: Decimal(string: "0.2")!),
                maxRecipients: 1, nativeDecimals: decimals)

        // MARK: - TRON

        case .tron:
            // ~1.1 TRX one-off activation surcharge to a never-activated
            // recipient (1 TRX createNewAccount + 0.1 TRX bandwidth).
            return ChainComposeCapability(
                feeModel: .tronResource, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .textMemo, memoMaxBytes: nil,
                reserve: .tronActivation(surcharge: Decimal(string: "1.1")!),
                maxRecipients: 1, nativeDecimals: decimals)

        // MARK: - NEAR

        case .near:
            // storage_amount_per_byte = 1e19 yocto/byte = 1e-5 NEAR/byte
            // (live-confirmed). Actual reserve = storage_usage × this.
            return ChainComposeCapability(
                feeModel: .nearGas, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .nearFtMemo, memoMaxBytes: nil,
                reserve: .nearStorage(perByte: Decimal(string: "0.00001")!),
                maxRecipients: 1, nativeDecimals: decimals)

        // MARK: - Polkadot

        case .polkadot:
            // Existential deposit = 0.01 DOT (lowered from 1 DOT).
            return ChainComposeCapability(
                feeModel: .polkadotWeight, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .none, memoMaxBytes: nil,
                reserve: .existentialDeposit(ed: Decimal(string: "0.01")!),
                maxRecipients: 20, nativeDecimals: decimals)

        // MARK: - Cosmos (Kava)

        case .kava:
            // No existential deposit on Cosmos; memo ≤512 chars.
            return ChainComposeCapability(
                feeModel: .cosmosGas, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .cosmosMemo, memoMaxBytes: 512, reserve: .none,
                maxRecipients: 10, nativeDecimals: decimals)

        // MARK: - Aptos

        case .aptos:
            // No account reserve/min-balance/activation; no memo/tag/
            // op_return (doc-grounded — Aptos coin transfer has no
            // transfer-note primitive).
            return ChainComposeCapability(
                feeModel: .aptosGas, supportsUTXO: false, opReturnMaxBytes: nil,
                memoKind: .none, memoMaxBytes: nil, reserve: .none,
                maxRecipients: 20, nativeDecimals: decimals)
        }
    }

    /// Shared EVM capability (account model, no UTXO/memo/op_return/
    /// reserve; single recipient — multi-recipient needs a disperse
    /// contract, out of scope).
    private static func evm(_ model: ComposeFeeModel, decimals: Int) -> ChainComposeCapability {
        ChainComposeCapability(
            feeModel: model, supportsUTXO: false, opReturnMaxBytes: nil,
            memoKind: .none, memoMaxBytes: nil, reserve: .none,
            maxRecipients: 1, nativeDecimals: decimals)
    }
}
