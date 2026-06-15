import Foundation

/// A speed tier label for fee presets. `custom` is a user override.
enum FeeTier: String, Codable, Hashable, Sendable, CaseIterable {
    case slow
    case normal
    case fast
    case custom

    /// English source label (Rule #9; the orchestrator's i18n scanner
    /// extracts these). Resolved at call sites via `LocalizedStringKey`.
    var label: String {
        switch self {
        case .slow:   return "Slow"
        case .normal: return "Normal"
        case .fast:   return "Fast"
        case .custom: return "Custom"
        }
    }
}

/// The fully-resolved per-chain fee a send will pay. Every numeric field
/// a chain's signer needs lives here; only the fields relevant to the
/// chain's `ComposeFeeModel` are populated (the rest are `nil`).
/// Codable + Hashable + Sendable so it rides into `SendDraft` and across
/// isolation boundaries.
///
/// All money/price fields are `Decimal` (Rule: money math never Double).
/// Per-gas / per-byte raw integers are stored as `Decimal` too so they
/// survive u128/u256 magnitudes without precision loss.
struct FeeChoice: Codable, Hashable, Sendable {

    /// Which tier produced this choice (preset or `.custom`).
    let tier: FeeTier

    /// The fee model this choice is shaped for (so a consumer can switch
    /// on it without re-deriving from the chain).
    let feeModel: ComposeFeeModel

    // MARK: - UTXO (bitcoin family)

    /// sat/vB (BTC/LTC) or sat/byte (BCH) or koinu/byte (DOGE).
    var byteFeeRate: Decimal?

    // MARK: - EVM 1559

    /// maxFeePerGas in wei.
    var maxFeePerGasWei: Decimal?
    /// maxPriorityFeePerGas (tip) in wei.
    var maxPriorityFeePerGasWei: Decimal?
    /// The live NEXT-block base fee in wei (from `eth_feeHistory`), carried
    /// forward so the UI's CUSTOM fee path can compute a realistic
    /// `estimatedTotalNative` = gasLimit × (baseFee + tip) [+ L1] instead of
    /// only the worst-case ceiling. nil for non-1559 models.
    var baseFeePerGasWei: Decimal?

    // MARK: - EVM legacy

    /// gasPrice in wei (legacy / BNB).
    var gasPriceWei: Decimal?

    // MARK: - EVM gas units (shared by 1559 + legacy + L1 + zkSync)

    /// gasLimit in gas units (from eth_estimateGas + pad).
    var gasLimit: Decimal?
    /// Additive L1 data fee in wei (OP-stack chains), display + reserve
    /// only; the signer does not set it.
    var l1DataFeeWei: Decimal?
    /// zkSync gasPerPubdataLimit — REQUIRED on zkSync, nil elsewhere.
    var gasPerPubdataLimit: Decimal?

    // MARK: - Solana

    /// computeUnitPrice in micro-lamports/CU.
    var computeUnitPrice: Decimal?
    /// computeUnitLimit in compute units.
    var computeUnitLimit: Decimal?
    /// Base fee lamports (5,000 × signatures).
    var solanaBaseFeeLamports: Decimal?

    // MARK: - Stellar

    /// Per-operation base-fee bid in stroops.
    var stellarPerOpStroops: Decimal?
    /// Number of operations in the tx (1 for a simple payment).
    var stellarOpCount: Int?

    // MARK: - Sui

    /// gasPrice in MIST (≥ reference gas price).
    var suiGasPriceMist: Decimal?
    /// gasBudget in MIST (auto-sized from dry run).
    var suiGasBudgetMist: Decimal?

    // MARK: - XRP

    /// Fee in drops (burned).
    var xrpDrops: Decimal?

    // MARK: - TRON

    /// fee_limit in SUN (the energy-burn cap for contract calls).
    var tronFeeLimitSun: Decimal?
    /// Estimated bandwidth (bytes) the tx consumes.
    var tronEstimatedBandwidth: Decimal?
    /// Estimated energy (contract calls).
    var tronEstimatedEnergy: Decimal?

    // MARK: - NEAR

    /// gas_price in yoctoNEAR/gas (network-set).
    var nearGasPriceYocto: Decimal?
    /// Attached/prepaid gas units (deterministic for native; 30 Tgas
    /// for FT transfers).
    var nearGasUnits: Decimal?

    // MARK: - Polkadot

    /// partial_fee (inclusion fee) in plancks.
    var polkadotPartialFeePlancks: Decimal?
    /// Optional tip in plancks (the only sender lever).
    var polkadotTipPlancks: Decimal?

    // MARK: - Cosmos (Kava)

    /// gas_limit (uint64) for the cosmos tx.
    var cosmosGasLimit: Decimal?
    /// gas_price in ukava/gas.
    var cosmosGasPrice: Decimal?

    // MARK: - Aptos

    /// gas_unit_price in octas/gas.
    var aptosGasUnitPrice: Decimal?
    /// max_gas_amount in gas units.
    var aptosMaxGasAmount: Decimal?

    // MARK: - Computed total (always present)

    /// The estimated total fee in the chain's NATIVE units (e.g. BTC,
    /// ETH, SOL, XRP) — already divided by `10^nativeDecimals`. This is
    /// what the UI shows and what amount-math subtracts for "Max".
    /// For TON/Polkadot it is the deterministic network fee; for OP-stack
    /// it includes the additive L1 data fee.
    private(set) var estimatedTotalNative: Decimal

    /// The worst-case fee in native units (use for "Max"/send-all
    /// reservation so a base-fee rise can't strand the tx). Equals
    /// `estimatedTotalNative` for deterministic models.
    private(set) var worstCaseTotalNative: Decimal

    /// Set the resolved totals (the numeric fields are filled first, then
    /// the totals are computed from them).
    mutating func setTotals(estimated: Decimal, worst: Decimal) {
        estimatedTotalNative = estimated
        worstCaseTotalNative = worst
    }

    /// Convenience init: all per-chain numeric fields `nil`, totals set
    /// by the caller via `setTotals` after populating the relevant fields.
    /// Lives in this file so it can set the `private(set)` totals.
    init(tier: FeeTier, feeModel: ComposeFeeModel,
         estimatedTotalNative: Decimal, worstCaseTotalNative: Decimal) {
        self.tier = tier
        self.feeModel = feeModel
        self.byteFeeRate = nil
        self.maxFeePerGasWei = nil
        self.maxPriorityFeePerGasWei = nil
        self.baseFeePerGasWei = nil
        self.gasPriceWei = nil
        self.gasLimit = nil
        self.l1DataFeeWei = nil
        self.gasPerPubdataLimit = nil
        self.computeUnitPrice = nil
        self.computeUnitLimit = nil
        self.solanaBaseFeeLamports = nil
        self.stellarPerOpStroops = nil
        self.stellarOpCount = nil
        self.suiGasPriceMist = nil
        self.suiGasBudgetMist = nil
        self.xrpDrops = nil
        self.tronFeeLimitSun = nil
        self.tronEstimatedBandwidth = nil
        self.tronEstimatedEnergy = nil
        self.nearGasPriceYocto = nil
        self.nearGasUnits = nil
        self.polkadotPartialFeePlancks = nil
        self.polkadotTipPlancks = nil
        self.cosmosGasLimit = nil
        self.cosmosGasPrice = nil
        self.aptosGasUnitPrice = nil
        self.aptosMaxGasAmount = nil
        self.estimatedTotalNative = estimatedTotalNative
        self.worstCaseTotalNative = worstCaseTotalNative
    }
}

/// A complete fee quote returned by `ComposeFeeService`: the slow/normal/
/// fast preset choices plus the chain's fee model. The compose UI binds
/// to `tiers` and lets the user pick or supply a custom override. For
/// single-tier models (`hasSpeedTiers == false`) only `.normal` is
/// populated and the UI shows one fee.
struct FeeQuote: Codable, Hashable, Sendable {

    /// The chain this quote is for.
    let chain: SupportedChain

    /// The fee model (so the UI knows which fields to render).
    let feeModel: ComposeFeeModel

    /// Preset choices keyed by tier (slow/normal/fast). At minimum
    /// `.normal` is present; single-tier models only populate `.normal`.
    let tiers: [FeeTier: FeeChoice]

    /// Whether the model lets the user supply a custom fee.
    let isCustomAllowed: Bool

    /// Whether the model has real slow/normal/fast speed tiers.
    let hasSpeedTiers: Bool

    /// A note the UI may show (e.g. "Network fee is fixed" for TON, or
    /// the L1-data-fee component for OP-stack). English source.
    let note: String?

    /// Convenience: the normal-tier choice (always present).
    var normal: FeeChoice? { tiers[.normal] }
}
