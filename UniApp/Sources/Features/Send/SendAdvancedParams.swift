import Foundation

/// Per-chain advanced send parameters the Advanced sheet edits, shaped by
/// family. Only the fields relevant to the selected network are read /
/// written — the Advanced sheet branches on `network.family` and shows
/// only that family's controls (Rule: never surface a control a chain
/// doesn't have).
///
/// All values are **UI state with smart defaults** so the sheet is
/// optional. None of them are wired to real estimation / signing yet —
/// `// TODO: (T-063)` (fee estimation) and `// TODO: (T-065)` (apply the
/// advanced params to the signed transaction) carry that work.
struct SendAdvancedParams: Hashable, Sendable {

    // MARK: - Bitcoin (UTXO)

    /// Custom fee rate in sat/vB. Default is the "Fast" preset value.
    var bitcoinSatPerVByte: Double = 21

    /// Replace-By-Fee — lets the user bump a stuck tx later. On by
    /// default (the modern Bitcoin norm).
    var bitcoinRBFEnabled: Bool = true

    /// Optional OP_RETURN message / data hex carried on-chain.
    var bitcoinOpReturn: String = ""

    /// Selected UTXO ids for coin control. Empty = "let Aperture choose"
    /// (the default — automatic coin selection). Non-empty = the user
    /// hand-picked these inputs in the coin-control sheet.
    var bitcoinSelectedUTXOIds: Set<String> = []

    // MARK: - EVM (EIP-1559)

    /// Max fee per gas, in gwei. Default is the "Fast" preset.
    var evmMaxFeeGwei: Double = 24.0

    /// Priority fee (tip) per gas, in gwei.
    var evmPriorityFeeGwei: Double = 1.5

    /// Gas limit. 21,000 is the standard native-transfer limit; token
    /// transfers raise it. The real path estimates this. `// TODO: (T-063)`.
    var evmGasLimit: Int = 21_000

    /// Transaction nonce. Editable so a power user can replace / cancel a
    /// stuck tx. `nil` = "use the next nonce" (the default). The real
    /// path reads the account's pending nonce. `// TODO: (T-063)`.
    var evmNonce: Int? = nil

    /// Raw hex calldata (advanced — contract interactions). Empty for a
    /// plain transfer.
    var evmHexData: String = ""

    // MARK: - Solana

    /// Compute-unit price in micro-lamports — the priority fee. Default
    /// is the "Recommended" preset.
    var solanaComputeUnitPriceMicroLamports: Double = 50_000

    /// Whether the priority fee is enabled (sets the compute-unit limit
    /// automatically). On by default.
    var solanaPriorityFeeEnabled: Bool = true
}

extension SendAdvancedParams {
    /// Whether the selected network exposes an Advanced sheet at all.
    /// Bitcoin / EVM / Solana do; the long-tail chains degrade to the
    /// simple fee display (no Advanced entry). Drives whether the
    /// Review fee row shows an "Edit" affordance.
    static func hasAdvancedSheet(for network: SupportedChain?) -> Bool {
        guard let network else { return false }
        switch network.family {
        case .bitcoin, .evm:
            return true
        case .ed25519:
            // Only Solana among the ed25519 family ships a priority-fee
            // sheet; Stellar / Sui degrade to the simple fee display.
            return network == .solana
        case .ripple, .cosmos, .aptos, .near, .polkadot, .ton, .tron:
            return false
        }
    }

    /// Whether the network supports coin control (UTXO selection) — only
    /// the Bitcoin family.
    static func supportsCoinControl(for network: SupportedChain?) -> Bool {
        network?.family == .bitcoin
    }
}
