import Foundation

/// Per-chain send capability, grounded in protocol docs (the 2026-06-15
/// multi-recipient capability research). The recipient step uses
/// `maxRecipients` to decide whether to offer a native multi-address
/// list. The inline notes record the on-chain mechanism + the signing
/// path for when the send domain is rebuilt (some chains are wallet-core-
/// native; a few need a custom transaction).
enum ChainSendCapability {

    /// Maximum distinct recipient addresses payable in ONE transaction.
    /// `1` = single-recipient only. Values are conservative practical UI
    /// caps, not always the protocol maximum.
    static func maxRecipients(for chain: SupportedChain) -> Int {
        switch chain {
        // UTXO — a transaction has many outputs (vout); N recipients +
        // change. wallet-core: Bitcoin `extra_outputs` (native).
        case .bitcoin, .bitcoinCash, .litecoin, .dogecoin:
            return 20

        // TON — wallet v4r2 carries up to 4 outgoing messages per signed
        // op. wallet-core: TheOpenNetworkSigningInput.messages[] (native).
        case .ton:
            return 4

        // Cosmos / Kava — a tx body holds many messages; N bank MsgSend.
        // wallet-core: CosmosSigningInput.messages[] (native).
        case .kava:
            return 10

        // Sui — `unsafe_pay` takes parallel recipient[]+amount[] arrays;
        // one atomic tx pays many. wallet-core / RPC (native).
        case .sui:
            return 20

        // Polkadot — `utility.batch` wraps N balances.transfer calls.
        // wallet-core supports batch; our SCALE builder extends to it.
        case .polkadot:
            return 20

        // Solana — multiple SystemProgram.transfer instructions in one
        // atomic tx (bounded by the 1232-byte / 64-account limits).
        // wallet-core high-level is single → custom multi-instruction tx
        // at signing time.
        case .solana:
            return 15

        // Stellar — up to 100 Payment operations per tx. wallet-core
        // high-level is a single opPayment → custom multi-op XDR at
        // signing time.
        case .stellar:
            return 20

        // Aptos — `0x1::aptos_account::batch_transfer(vector<address>,
        // vector<u64>)` stdlib entry function. wallet-core high-level is
        // single → custom entry-function payload at signing time.
        case .aptos:
            return 20

        // Single-recipient only. EVM native/ERC-20 transfers carry one
        // `to` (multi-recipient would need a disperse contract — a
        // separate advanced feature, not a native "send to many at once").
        // TRON / XRPL / NEAR have one recipient per transaction.
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm,
             .tron, .ripple, .near:
            return 1
        }
    }

    /// Whether the chain can pay more than one recipient in a single
    /// transaction (drives the recipient step's multi-address list).
    static func supportsMultiRecipient(_ chain: SupportedChain) -> Bool {
        maxRecipients(for: chain) > 1
    }

    /// The full doc-grounded compose capability (fee model, UTXO,
    /// OP_RETURN, memo/tag, reserve rule) for the amount/compose screen.
    /// `ChainSendCapability` owns the recipient-step multi-address cap;
    /// `ChainComposeCapability` owns the amount-step fee/UTXO/reserve
    /// surface. This accessor is the bridge between the two so callers
    /// reach the compose capability from the same namespace.
    static func compose(for chain: SupportedChain) -> ChainComposeCapability {
        ChainComposeCapability.capability(for: chain)
    }
}
