import Foundation
import WalletCore

/// The per-family sign dispatcher — the single entry point the
/// `SendExecutor` calls. Keyed on `chain.family`, it builds the
/// wallet-core SigningInput from the `SendDraft` + just-in-time data and
/// returns a `SignedTransaction`. Adapted from Stabro's
/// `TransactionSigner.sign(privateKey:request:network:)` family switch.
///
/// **PASS 1 wired `.evm` (12 chains) + `.bitcoin` (4 chains).**
/// **PASS 2 closes the set — the remaining 10 chains across 8 families
/// (ed25519: Solana/Stellar/Sui; tron; cosmos: Kava; aptos; near;
/// polkadot; ton; ripple).** Every branch now builds the chain's real
/// wallet-core SigningInput; there is no `.chainNotWired` seam left —
/// the dispatcher covers all 26 supported chains.
///
/// Pure compute, `nonisolated` — invoked off-main by the executor.
enum TransactionSigner {

    /// Chain-family-agnostic just-in-time bundle. Only the field a given
    /// family needs is populated; the rest are nil. The executor fetches
    /// these immediately before signing (Rule #27 §C) and never signs
    /// against a stale volatile value.
    struct JustInTimeData: Sendable {
        // MARK: EVM
        /// EVM live pending nonce (`eth_getTransactionCount(addr,"pending")`).
        let evmNonce: UInt64?

        // MARK: Solana
        /// `getLatestBlockhash` → `value.blockhash` (base58); valid ~60–90s.
        let solanaRecentBlockhash: String?
        /// Recipient's Associated Token Account (derived) for an SPL send.
        let solanaRecipientTokenAccount: String?
        /// Sender's Associated Token Account for an SPL send.
        let solanaSenderTokenAccount: String?
        /// Whether the recipient ATA does NOT yet exist (→ CreateAndTransfer).
        let solanaRecipientATANeedsCreation: Bool?

        // MARK: Bitcoin family
        /// The address's CURRENT unspent-output set, re-fetched off-main
        /// immediately before signing (Rule #27 §C). The signer prefers
        /// this over the compose-time `draft.selectedUTXOs` so we never
        /// sign against a UTXO that was spent between compose and sign
        /// (a spent input → the network rejects the broadcast). `nil`
        /// only for non-Bitcoin chains.
        let bitcoinUTXOs: [SelectedUTXO]?

        // MARK: XRP / Ripple
        /// Account sequence from `account_info` (`account_data.Sequence`).
        let xrpSequence: UInt32?
        /// `last_ledger_sequence` = current ledger + buffer (tx expiry).
        let xrpLastLedgerSequence: UInt32?

        // MARK: Stellar
        /// The Stellar tx sequence = account `sequence` + 1 (the executor
        /// already increments it; the signer uses it verbatim).
        let stellarSequence: UInt64?

        // MARK: TON
        /// Wallet contract seqno from `getWalletInformation` / runGetMethod.
        let tonSeqno: UInt32?
        /// Sender's jetton-wallet address (from `get_wallet_address`) for a
        /// jetton (token) send — the message destination for jetton transfers.
        let tonSenderJettonWallet: String?

        // MARK: TRON
        /// Latest block ref from `/wallet/getnowblock` (encoded JSON the
        /// signer parses into a `TronBlockHeader`).
        let tronBlockHeaderJSON: String?

        // MARK: NEAR
        /// Access-key nonce + 1 (`query` access-key view).
        let nearNonce: UInt64?
        /// Recent block hash (base58) from `block {finality:final}`.
        let nearBlockHash: String?

        // MARK: Polkadot
        /// `state_getRuntimeVersion.specVersion` (must be live, never hardcoded).
        let polkadotSpecVersion: UInt32?
        /// `state_getRuntimeVersion.transactionVersion`.
        let polkadotTransactionVersion: UInt32?
        /// Mortal-era checkpoint block hash (hex) from `chain_getFinalizedHead`.
        let polkadotBlockHash: String?
        /// Mortal-era checkpoint block number (for `era.blockNumber`).
        let polkadotBlockNumber: UInt64?
        /// `system_accountNextIndex` nonce.
        let polkadotNonce: UInt64?

        // MARK: Aptos
        /// `accounts/{addr}.sequence_number`.
        let aptosSequenceNumber: UInt64?
        /// `estimate_gas_price.gas_estimate` (octas/gas).
        let aptosGasUnitPrice: UInt64?

        // MARK: Sui
        /// The selected input coin object refs (objectId/version/digest)
        /// from `suix_getCoins` — consensus-fresh, re-fetched at sign time.
        let suiInputCoins: [SuiCoinRef]?
        /// A SEPARATE SUI gas coin ref (required for a non-SUI token send).
        let suiGasCoin: SuiCoinRef?
        /// Reference gas price from `suix_getReferenceGasPrice` (MIST).
        let suiReferenceGasPrice: UInt64?

        // MARK: Cosmos (Kava)
        /// `cosmos/auth/.../accounts.account_number`.
        let cosmosAccountNumber: UInt64?
        /// `cosmos/auth/.../accounts.sequence`.
        let cosmosSequence: UInt64?

        init(
            evmNonce: UInt64? = nil,
            bitcoinUTXOs: [SelectedUTXO]? = nil,
            solanaRecentBlockhash: String? = nil,
            solanaRecipientTokenAccount: String? = nil,
            solanaSenderTokenAccount: String? = nil,
            solanaRecipientATANeedsCreation: Bool? = nil,
            xrpSequence: UInt32? = nil,
            xrpLastLedgerSequence: UInt32? = nil,
            stellarSequence: UInt64? = nil,
            tonSeqno: UInt32? = nil,
            tonSenderJettonWallet: String? = nil,
            tronBlockHeaderJSON: String? = nil,
            nearNonce: UInt64? = nil,
            nearBlockHash: String? = nil,
            polkadotSpecVersion: UInt32? = nil,
            polkadotTransactionVersion: UInt32? = nil,
            polkadotBlockHash: String? = nil,
            polkadotBlockNumber: UInt64? = nil,
            polkadotNonce: UInt64? = nil,
            aptosSequenceNumber: UInt64? = nil,
            aptosGasUnitPrice: UInt64? = nil,
            suiInputCoins: [SuiCoinRef]? = nil,
            suiGasCoin: SuiCoinRef? = nil,
            suiReferenceGasPrice: UInt64? = nil,
            cosmosAccountNumber: UInt64? = nil,
            cosmosSequence: UInt64? = nil
        ) {
            self.evmNonce = evmNonce
            self.bitcoinUTXOs = bitcoinUTXOs
            self.solanaRecentBlockhash = solanaRecentBlockhash
            self.solanaRecipientTokenAccount = solanaRecipientTokenAccount
            self.solanaSenderTokenAccount = solanaSenderTokenAccount
            self.solanaRecipientATANeedsCreation = solanaRecipientATANeedsCreation
            self.xrpSequence = xrpSequence
            self.xrpLastLedgerSequence = xrpLastLedgerSequence
            self.stellarSequence = stellarSequence
            self.tonSeqno = tonSeqno
            self.tonSenderJettonWallet = tonSenderJettonWallet
            self.tronBlockHeaderJSON = tronBlockHeaderJSON
            self.nearNonce = nearNonce
            self.nearBlockHash = nearBlockHash
            self.polkadotSpecVersion = polkadotSpecVersion
            self.polkadotTransactionVersion = polkadotTransactionVersion
            self.polkadotBlockHash = polkadotBlockHash
            self.polkadotBlockNumber = polkadotBlockNumber
            self.polkadotNonce = polkadotNonce
            self.aptosSequenceNumber = aptosSequenceNumber
            self.aptosGasUnitPrice = aptosGasUnitPrice
            self.suiInputCoins = suiInputCoins
            self.suiGasCoin = suiGasCoin
            self.suiReferenceGasPrice = suiReferenceGasPrice
            self.cosmosAccountNumber = cosmosAccountNumber
            self.cosmosSequence = cosmosSequence
        }
    }

    /// Sign `draft` for `wallet`. The signing key(s) are derived inside
    /// `SigningKeyProvider`'s closure and dropped at return — they never
    /// outlive this call.
    static func sign(
        draft: SendDraft,
        wallet: WalletDescriptor,
        jit: JustInTimeData,
        passphrase: String? = nil
    ) throws -> SignedTransaction {
        switch draft.chain.family {
        case .evm:
            guard let nonce = jit.evmNonce else {
                throw SigningError.justInTimeRefreshFailed("EVM nonce not refreshed")
            }
            return try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                expectedAddress: draft.fromAddress
            ) { key in
                try EVMTransactionSigner.sign(
                    draft: draft, jit: EVMTransactionSigner.JustInTime(nonce: nonce), privateKey: key
                )
            }

        case .bitcoin:
            let requiredAddresses: Set<String> = [draft.fromAddress]
            return try SigningKeyProvider.withBitcoinKeys(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                requiredAddresses: requiredAddresses
            ) { keys in
                try BitcoinTransactionSigner.sign(
                    draft: draft, privateKeys: keys, freshUTXOs: jit.bitcoinUTXOs
                )
            }

        // MARK: - PASS 2 — the remaining 10 chains, real wallet-core signers

        case .ed25519:   // Solana, Stellar, Sui
            return try signEd25519(draft: draft, wallet: wallet, jit: jit, passphrase: passphrase)

        case .tron:
            return try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                expectedAddress: draft.fromAddress
            ) { key in
                try TronTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            }

        case .cosmos:    // Kava (Cosmos)
            return try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                expectedAddress: draft.fromAddress
            ) { key in
                try CosmosTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            }

        case .aptos:
            return try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                expectedAddress: draft.fromAddress
            ) { key in
                try AptosTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            }

        case .near:
            return try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                expectedAddress: draft.fromAddress
            ) { key in
                try NearTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            }

        case .polkadot:
            return try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                expectedAddress: draft.fromAddress
            ) { key in
                try PolkadotTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            }

        case .ton:
            return try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                expectedAddress: draft.fromAddress
            ) { key in
                try TONTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            }

        case .ripple:    // XRP Ledger
            return try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: draft.chain, passphrase: passphrase,
                expectedAddress: draft.fromAddress
            ) { key in
                try RippleTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            }
        }
    }

    /// The ed25519 family routes to its three per-chain signers (each
    /// wallet-core proto is distinct: Solana lamports/SPL, Stellar
    /// stroops/XDR, Sui MIST/object-model). Grouped here because they
    /// share the same key-access path (`withPrivateKey` + the chain's
    /// ed25519 CoinType + key↔address parity).
    private static func signEd25519(
        draft: SendDraft, wallet: WalletDescriptor,
        jit: JustInTimeData, passphrase: String?
    ) throws -> SignedTransaction {
        try SigningKeyProvider.withPrivateKey(
            wallet: wallet, chain: draft.chain, passphrase: passphrase,
            expectedAddress: draft.fromAddress
        ) { key in
            switch draft.chain {
            case .solana:  return try SolanaTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            case .stellar: return try StellarTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            case .sui:     return try SuiTransactionSigner.sign(draft: draft, jit: jit, privateKey: key)
            default:
                throw SigningError.malformedDraft("ed25519 signer used for \(draft.chain.rawValue)")
            }
        }
    }
}

/// A `Sendable` Sui owned-coin object reference (objectId/version/digest)
/// fetched from `suix_getCoins` and threaded through `JustInTimeData` to
/// the Sui signer. Version bumps on every mutation, so these are
/// re-fetched immediately before signing (Rule #27 §C).
struct SuiCoinRef: Sendable, Hashable {
    let objectId: String
    let version: UInt64
    let digest: String
}
