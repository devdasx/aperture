import Foundation

/// The fee *kind* a chain uses to price a transaction. Drives which
/// numeric fields a `FeeChoice` carries, which fee fetcher runs in
/// `ComposeFeeService`, and which advanced controls the compose UI shows.
///
/// Doc-grounded per `.claude/send-compose-matrix.md` (2026-06-15,
/// live-verified). Each case names the on-wire fee mechanism, not the
/// display tier.
enum ComposeFeeModel: String, Codable, Hashable, Sendable, CaseIterable {

    /// UTXO chains priced by `rate(sat/vB) × vsize`. Bitcoin, Litecoin
    /// (segwit/vsize). Source: mempool.space `/v1/fees/recommended`.
    case utxoByteFee

    /// UTXO chains priced by `rate(sat/byte) × rawSize` (no segwit, no
    /// witness discount). Bitcoin Cash. Source: BlockCypher `medium/
    /// high/low_fee_per_kb` ÷ 1000, clamped ≥ 1 sat/byte relay floor.
    case utxoByteFeeNoWitness

    /// Dogecoin's fixed fee-per-kB recommendation (0.01 DOGE/kB normal,
    /// 0.001 floor) plus the soft/hard dust surcharge. No segwit.
    case dogecoinFixedPerKB

    /// EIP-1559 (type 0x02): maxFeePerGas + maxPriorityFeePerGas ×
    /// gasLimit. Default for Ethereum/Arbitrum/Avalanche/Polygon/
    /// Celo/Kava-EVM (and zkSync's simple path). Source: eth_feeHistory.
    case evm1559

    /// Legacy (type 0x00): single gasPrice × gasLimit. BNB Chain
    /// (base fee = 0, no real 1559 market). Source: eth_gasPrice.
    case evmLegacy

    /// EIP-1559 L2 gas PLUS an additive L1 data fee fetched from the
    /// OP-Stack `GasPriceOracle` predeploy `getL1Fee(bytes)`. Optimism,
    /// Base, opBNB, Scroll (Scroll uses a different oracle address).
    case evm1559PlusL1Data

    /// zkSync Era: maxFeePerGas × gasLimit where gasLimit also covers
    /// pubdata via `gasPerPubdataLimit` (a REQUIRED extra field that
    /// does not exist on Ethereum). Source: eth_gasPrice + zks_gasPerPubdata.
    case zkSyncEra

    /// Solana: fixed 5,000-lamport base per signature + optional
    /// priority = ceil(computeUnitPrice × computeUnitLimit / 1e6).
    /// Source: getRecentPrioritizationFees + getFeeForMessage.
    case solana

    /// Stellar: fixed per-operation inclusion fee in stroops
    /// (min 100/op). Source: Horizon `/fee_stats`.
    case stellarPerOp

    /// Sui: decoupled gasPrice (≥ reference gas price) + gasBudget,
    /// auto-sized from a dry run. Source: suix_getReferenceGasPrice +
    /// sui_dryRunTransactionBlock.
    case suiGasBudget

    /// TON: deterministic phase-based fee (import + storage + gas +
    /// forward), NO user-set price. Source: toncenter `estimateFee`.
    case tonFixed

    /// XRP: fixed per-transaction burn in drops (base 10 × load_factor).
    /// Source: rippled `fee` method.
    case xrpFixed

    /// TRON: bandwidth (bytes) + energy (contract) resource model;
    /// TRX burned only when staked/free resources are insufficient.
    /// Source: TronGrid getchainparameters + getaccountresource +
    /// triggerconstantcontract.
    case tronResource

    /// NEAR: deterministic gas-unit cost × network gas_price (no tip
    /// market for plain transfers; FunctionCall sets attached gas).
    /// Source: NEAR `gas_price` + protocol config.
    case nearGas

    /// Polkadot: weight-based inclusion fee (partial_fee) + optional
    /// tip. Source: payment_queryInfo on a dummy-signed extrinsic.
    case polkadotWeight

    /// Cosmos SDK (Kava Cosmos): gasLimit × gasPrice (ukava), gas from
    /// simulate. Source: chain-registry fee tiers + cosmos simulate.
    case cosmosGas

    /// Aptos: gas_unit_price × max_gas_amount (octas), estimated via
    /// `/v1/estimate_gas_price` + `/v1/transactions/simulate`.
    case aptosGas

    /// Whether the user can set a custom numeric fee for this model.
    /// `tonFixed` is deterministic by the protocol — the user cannot
    /// bid; we surface a single honest estimate (Rule #2 honesty).
    var isUserAdjustable: Bool {
        self != .tonFixed
    }

    /// Whether the model exposes slow/normal/fast *speed* tiers that
    /// meaningfully change inclusion. NEAR/Aptos/TON/Polkadot/Cosmos
    /// have a single deterministic network fee (the only lever is a
    /// tip on Polkadot, or none) — the UI should present one fee, not
    /// three, to avoid implying a priority market that doesn't exist.
    var hasSpeedTiers: Bool {
        switch self {
        case .nearGas, .tonFixed, .aptosGas:
            return false
        default:
            return true
        }
    }
}

/// The memo / destination-tag / comment kind a chain attaches to a send.
/// Drives the recipient/compose UI's optional-data field and the
/// exchange-required warning (Rule #2 honesty: only show a memo field
/// where the protocol actually carries one).
enum ComposeMemoKind: String, Codable, Hashable, Sendable {
    /// No protocol memo/tag/data field (EVM, Sui, Aptos, Polkadot
    /// relay, Bitcoin-family transfers — OP_RETURN is separate).
    case none
    /// Free-form UTF-8 text memo (TRON raw_data.data, +1 TRX fee).
    case textMemo
    /// Cosmos `TxBody.memo` (≤512 chars).
    case cosmosMemo
    /// XRP `DestinationTag` (uint32) — most-required CEX field.
    case destinationTag
    /// TON text comment (0x00000000-prefixed cell), CEX-required.
    case tonComment
    /// Solana SPL Memo program instruction (≤566 bytes), CEX-required.
    case splMemo
    /// Stellar transaction memo (text ≤28 bytes / id u64 / hash 32B),
    /// CEX-required, SEP-29 gate.
    case stellarMemo
    /// NEAR NEP-141 FT `ft_transfer` memo (tokens only, optional).
    case nearFtMemo

    /// Whether centralized exchanges commonly REQUIRE this field for
    /// deposits — drives the "exchanges may require a memo" warning.
    var exchangeOftenRequires: Bool {
        switch self {
        case .destinationTag, .tonComment, .splMemo, .stellarMemo, .cosmosMemo, .textMemo:
            return true
        case .none, .nearFtMemo:
            return false
        }
    }
}
