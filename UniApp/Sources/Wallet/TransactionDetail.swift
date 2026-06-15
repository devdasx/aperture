import Foundation

/// The full, fetched-live detail of ONE on-chain transaction — far richer
/// than the normalized triple stored in `TransactionRecord`
/// (`TransactionScanner.TransactionEvent`). Built by
/// `TransactionDetailService` on demand when the user opens the Transaction
/// Detail screen; it is a pure read (no SwiftData write, no schema
/// migration) layered over the fast first-paint the stored row already
/// gives.
///
/// **Shape.** Common fields every chain reports (hash, status, block/slot,
/// timestamp, confirmations, native fee, explorer URL) PLUS a per-family
/// `payload` carrying the chain-specific fields the user asked to see:
/// Bitcoin's inputs/outputs/hex/size/vsize/weight/feeRate; EVM's
/// gas/nonce/type/logs/decoded-ERC-20; Solana's slot/CU/balances/
/// instructions/logs; and a `.generic` labeled key-value list for the 9
/// other chains (XRPL, TRON, TON, NEAR, Aptos, Cosmos/Kava, Polkadot,
/// Stellar, Sui).
///
/// **Honesty (Rule #16 / #24).** Every value is the truth of what the
/// upstream RPC reported, parsed but never fabricated. A field the
/// provider omits is `nil` (the UI shows "—"), and a fetch failure returns
/// `nil` from the service — the screen keeps showing the stored row, it
/// never invents detail.
///
/// **Sendable (Rule #28).** Every type here is a `Sendable` value type so
/// the heavy parse runs off-main and only this small projection crosses
/// back to the `@MainActor` view. Money is `Decimal` throughout.
struct TransactionDetail: Sendable, Equatable {
    /// On-chain hash / signature / extrinsic-id (whatever uniquely names
    /// the tx on its chain). Verbatim, as the provider returned it.
    let hash: String

    /// The chain this transaction lives on.
    let chain: SupportedChain

    /// Confirmed / pending / failed, derived from the authoritative
    /// status field of the chain (EVM receipt `status`, Solana `meta.err`,
    /// XRPL `meta.TransactionResult`, etc.).
    let status: TransactionStatus

    /// Block height (EVM/Bitcoin/Cosmos/Aptos/Stellar `ledger`/Polkadot
    /// `blockHeight`) OR Solana `slot` OR Sui `checkpoint`. `nil` while the
    /// tx is still pending / unconfirmed.
    let blockNumber: Int64?

    /// On-chain timestamp, when the provider reports one. `nil` when the
    /// chain omits it for this tx (some older slots / pruned blocks).
    let blockTime: Date?

    /// How many blocks have been built on top, inclusive of the tx's own
    /// block (the tx's block = 1 confirmation). `nil` when the chain
    /// doesn't expose a comparable tip height, or the tx is pending.
    let confirmations: Int64?

    /// Total network fee paid, in the chain's native coin (already scaled
    /// by `nativeDecimals` — e.g. ETH, not wei; XLM, not stroops). `nil`
    /// when the provider didn't report a fee (e.g. a TRON energy-sponsored
    /// tx — the per-family payload then carries the energy breakdown).
    let feeNative: Decimal?

    /// The chain's native ticker for `feeNative` (BTC / ETH / SOL / …),
    /// surfaced so the UI can label the fee without re-deriving it.
    let feeTicker: String

    /// The canonical human block-explorer URL (via `TransactionExplorer`),
    /// or `nil` when no explorer is wired for the chain (UI hides the link).
    let explorerURL: URL?

    /// The chain-family-specific rich detail.
    let payload: Payload

    /// Per-family rich detail. One case per fetch strategy:
    /// Bitcoin / EVM / Solana get bespoke structs (richest fields); the 9
    /// other chains share `.generic` labeled rows.
    enum Payload: Sendable, Equatable {
        case bitcoin(BitcoinTxDetail)
        case evm(EVMTxDetail)
        case solana(SolanaTxDetail)
        /// Ordered, labeled key-value rows for XRPL / TRON / TON / NEAR /
        /// Aptos / Cosmos-Kava / Polkadot / Stellar / Sui — each fetcher
        /// fills the chain-specific rows (sequence, memo/tag, ledger, gas,
        /// energy usage, vm_status, …). Order is meaningful (the UI renders
        /// the rows top-to-bottom as built).
        case generic([DetailField])
    }
}

/// One labeled detail row for the `.generic` payload. The label is an
/// English source string (the UI localizes via `LocalizedStringKey` /
/// catalog at render); the value is the already-formatted display string.
struct DetailField: Sendable, Equatable, Identifiable {
    /// Stable identity for `ForEach` — the label is unique within a tx's
    /// generic row list.
    var id: String { label }
    /// English label ("Sequence", "Memo", "Ledger", "Energy used", …).
    let label: String
    /// Display value, already formatted (addresses shortened by the UI,
    /// not here — this is the full value so the UI decides truncation).
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: - Bitcoin family

/// Full detail of one Bitcoin-family transaction (BTC / LTC / BCH / DOGE).
/// Fields the providers return directly, PLUS the three Aperture computes
/// (`vsize` for Esplora segwit chains, `feeRate`, and `confirmations` on
/// the common `TransactionDetail`).
struct BitcoinTxDetail: Sendable, Equatable {
    /// Serialized transaction size in bytes.
    let size: Int
    /// Virtual size (vB) — Esplora computes `ceil(weight/4)`; the
    /// non-segwit chains (BCH/DOGE) use `size`.
    let vsize: Int
    /// Transaction weight units. Esplora/Haskoin return it directly;
    /// DOGE (no segwit) is `size * 4`.
    let weight: Int
    let version: Int
    let locktime: Int
    /// Effective fee rate in sat/vB (`fee / vsize`). `nil` when `vsize`
    /// is zero (guards a coinbase / fee-0 tx).
    let feeRate: Decimal?
    /// Total fee in sats (the raw integer the provider reported). The
    /// human-scaled native fee is on `TransactionDetail.feeNative`.
    let feeSats: Int64?
    let inputs: [BitcoinTxIO]
    let outputs: [BitcoinTxIO]
    /// Raw transaction hex (Esplora `/hex`, Haskoin `/raw.result`,
    /// BlockCypher inline `hex`). `nil` when the provider didn't return it.
    let hex: String?
}

/// One input or output leg of a Bitcoin-family transaction.
struct BitcoinTxIO: Sendable, Equatable, Identifiable {
    let id = UUID()
    /// `prevTxid:vout` for an input; `nil` for an output (outputs have no
    /// outpoint) and for a coinbase input.
    let outpoint: String?
    /// The address, when the script is addressable. `nil` for OP_RETURN
    /// outputs / nonstandard scripts / coinbase inputs.
    let address: String?
    /// Value in sats.
    let value: Int64
    /// Script type ("v0_p2wpkh", "v1_p2tr", "pay-to-pubkey-hash", …) when
    /// the provider reports it.
    let scriptType: String?
    /// `true` for a coinbase (newly-generated-coins) input.
    let isCoinbase: Bool

    init(outpoint: String?, address: String?, value: Int64, scriptType: String?, isCoinbase: Bool = false) {
        self.outpoint = outpoint
        self.address = address
        self.value = value
        self.scriptType = scriptType
        self.isCoinbase = isCoinbase
    }

    // UUID `id` excluded from equality so two structurally-equal legs
    // compare equal across fetches.
    static func == (lhs: BitcoinTxIO, rhs: BitcoinTxIO) -> Bool {
        lhs.outpoint == rhs.outpoint && lhs.address == rhs.address
            && lhs.value == rhs.value && lhs.scriptType == rhs.scriptType
            && lhs.isCoinbase == rhs.isCoinbase
    }
}

// MARK: - EVM family

/// Full detail of one EVM transaction (Ethereum + the 11 other EVM
/// chains). Combines `eth_getTransactionByHash` (the signed tx) with
/// `eth_getTransactionReceipt` (the execution result) + computed fee.
struct EVMTxDetail: Sendable, Equatable {
    let from: String
    /// `nil` for a contract-creation tx (the created address is in
    /// `contractAddress`).
    let to: String?
    /// Value in wei (raw, full-precision `Decimal`). The human-scaled
    /// native value is the caller's job via `nativeDecimals`.
    let valueWei: Decimal
    let nonce: Int64
    /// EIP-2718 tx type (0 legacy / 1 EIP-2930 / 2 EIP-1559 / chain-
    /// specific e.g. 0x7e on some L2 system txs). `nil` if absent.
    let type: Int?
    /// Gas limit (the tx's `gas` field).
    let gasLimit: Decimal?
    /// Gas actually used (receipt).
    let gasUsed: Decimal?
    let cumulativeGasUsed: Decimal?
    /// Submitted gas price (type 0/1). `nil` on type-2 txs.
    let gasPrice: Decimal?
    /// Actual per-gas price charged after base-fee burn (receipt). The
    /// authoritative fee multiplicand post-London.
    let effectiveGasPrice: Decimal?
    let maxFeePerGas: Decimal?
    let maxPriorityFeePerGas: Decimal?
    /// `gasUsed * effectiveGasPrice` in wei (full precision). The human-
    /// scaled native fee is on `TransactionDetail.feeNative`.
    let totalFeeWei: Decimal?
    /// Position of the tx in its block.
    let transactionIndex: Int64?
    /// Calldata (`input`). May be `"0x"` for a plain value transfer.
    let input: String
    /// The created contract's address, non-`nil` only for contract
    /// creation.
    let contractAddress: String?
    /// Decoded ERC-20 `Transfer(address,address,uint256)` logs.
    let erc20Transfers: [ERC20Transfer]
}

/// One decoded ERC-20 Transfer log from an EVM receipt.
struct ERC20Transfer: Sendable, Equatable, Identifiable {
    let id = UUID()
    /// The token contract (the log's `address`).
    let token: String
    let from: String
    let to: String
    /// Raw token value in base units (full-precision `Decimal`).
    let valueRaw: Decimal
    /// The log index within the tx (per-leg disambiguator, so a swap's two
    /// transfer legs are distinguishable).
    let logIndex: Int64?
    /// The token's decimals, resolved from `EVMTokenRegistry` by
    /// `(chain, contract)` at fetch time. `nil` when the contract is not in
    /// the curated registry — the UI then shows the raw base-units value
    /// with the "decimals not applied" caption (honesty: no decimals guess).
    let decimals: Int?
    /// The token's symbol from `EVMTokenRegistry` (`USDC`, `DAI`, …). `nil`
    /// for an unknown contract.
    let symbol: String?

    init(
        token: String,
        from: String,
        to: String,
        valueRaw: Decimal,
        logIndex: Int64?,
        decimals: Int? = nil,
        symbol: String? = nil
    ) {
        self.token = token
        self.from = from
        self.to = to
        self.valueRaw = valueRaw
        self.logIndex = logIndex
        self.decimals = decimals
        self.symbol = symbol
    }

    static func == (lhs: ERC20Transfer, rhs: ERC20Transfer) -> Bool {
        lhs.token == rhs.token && lhs.from == rhs.from && lhs.to == rhs.to
            && lhs.valueRaw == rhs.valueRaw && lhs.logIndex == rhs.logIndex
            && lhs.decimals == rhs.decimals && lhs.symbol == rhs.symbol
    }
}

// MARK: - Solana

/// Full detail of one Solana transaction from a single `getTransaction`
/// (jsonParsed) call.
struct SolanaTxDetail: Sendable, Equatable {
    let slot: Int64
    /// Fee in lamports (raw). Human-scaled SOL fee is on
    /// `TransactionDetail.feeNative`.
    let feeLamports: Int64
    let computeUnitsConsumed: Int64?
    let recentBlockhash: String?
    /// The raw error description when the tx failed (`meta.err` serialized
    /// to a string), `nil` on success.
    let errString: String?
    /// Human-readable one-line summaries of the top-level instructions.
    let instructions: [String]
    /// Program invoke/success trace (`meta.logMessages`).
    let logMessages: [String]
    /// Net balance changes for the accounts the parse could attribute —
    /// native SOL and SPL legs, each as a labeled signed amount.
    let netChanges: [SolanaBalanceChange]
}

/// One net balance change (SOL or SPL) for a Solana transaction.
struct SolanaBalanceChange: Sendable, Equatable, Identifiable {
    let id = UUID()
    /// The owner account this change applies to.
    let account: String
    /// Token symbol / mint short-name ("SOL", "USDC", or a shortened mint).
    let symbol: String
    /// Signed net delta, already scaled by the token's decimals
    /// (positive = received, negative = sent).
    let amount: Decimal

    init(account: String, symbol: String, amount: Decimal) {
        self.account = account
        self.symbol = symbol
        self.amount = amount
    }

    static func == (lhs: SolanaBalanceChange, rhs: SolanaBalanceChange) -> Bool {
        lhs.account == rhs.account && lhs.symbol == rhs.symbol && lhs.amount == rhs.amount
    }
}
