import Foundation
import SwiftData

// MARK: - ChainStateRecord

/// **The per-chain aggregate row — one row per (wallet × chain).**
///
/// User direction (2026-06-17): *"we'll create a row for each chain, with
/// all its details, address, balances, transactions, sent, received,
/// swap, self transfer, bridge, failed, utxos, private keys for each
/// chain … balance card should get its balances from each chain from its
/// row."* This model is that row: the single denormalized snapshot of
/// everything Aperture knows about one chain for one wallet, recomputed
/// from the normalized tables (`TokenBalanceRecord`, `TransactionRecord`,
/// `ChainUTXORecord`) after every refresh and read directly by the
/// balance card / home screen so per-chain balances render live.
///
/// **Why denormalize.** The normalized tables stay the source of truth
/// (every balance row, every tx leg). This aggregate exists so the UI can
/// read ONE indexed row per chain — total fiat, native balance, per-
/// category transaction counts, UTXO summary — without summing dozens of
/// rows on the main thread on every `@Query` notification. The repository
/// recomputes it from the normalized rows; it never holds data those rows
/// don't.
///
/// **Identity.** `(walletId, chainRaw)` is the logical unique key,
/// enforced by the repository's upsert (fetch-by-predicate then
/// update/insert) the same way `TransactionRepository` enforces its leg
/// identity. The SwiftData `@Attribute(.unique)` lives on `id` only.
///
/// **Encrypted private key (user-chosen 2026-06-17).** The user chose to
/// store each chain's private key as an AES-GCM-encrypted blob in the DB
/// (the alternative was a Keychain reference only). `encryptedPrivateKey`
/// holds the `AES.GCM.SealedBox.combined` ciphertext produced by
/// `ChainKeyVault`; the symmetric key lives in the Keychain, NEVER here.
/// Raw key material is derived inside `SigningKeyProvider.withPrivateKey`'s
/// closure and encrypted before it escapes — plaintext keys never touch
/// SwiftData. `nil` for watch-only wallets (no key) and until the one-time
/// derivation runs.
@Model
final class ChainStateRecord {
    @Attribute(.unique) var id: UUID

    /// Owning wallet — `WalletRecord.id`. Part of the logical identity.
    var walletId: UUID

    /// `SupportedChain.rawValue`. Part of the logical identity.
    var chainRaw: String

    /// The wallet's address on this chain (canonical encoding).
    var address: String

    /// BIP-32/44 derivation path that produced `address` (empty for
    /// watch-only / single-key imports).
    var derivationPath: String

    // MARK: Native balance

    /// Native-coin balance in canonical units (ETH/BTC/SOL — not
    /// wei/sats/lamports), decimal-string for precision (same contract as
    /// `TokenBalanceRecord.rawBalance` for natives: value is already
    /// human-scaled, paired with `nativeDecimals == 0`).
    var nativeBalanceRaw: String

    /// Decimals the native amount is expressed under. `0` because
    /// `nativeBalanceRaw` is already human-scaled (mirrors the
    /// coordinator's native upsert).
    var nativeDecimals: Int

    /// Fiat value of the native balance in `fiatCurrencyCode`.
    var nativeFiat: Decimal

    // MARK: Aggregate

    /// Total fiat for this chain = native + every token row, in
    /// `fiatCurrencyCode`. The balance card sums these across chains.
    var totalFiat: Decimal

    /// Number of positive-balance token rows held on this chain
    /// (excludes the native coin).
    var tokenCount: Int

    /// Currency code the fiat fields are denominated in.
    var fiatCurrencyCode: String

    // MARK: Transaction category counts

    /// Outgoing transfers (direction `.outgoing`, kind `.transfer`).
    var txSentCount: Int
    /// Incoming transfers (direction `.incoming`, kind `.transfer`).
    var txReceivedCount: Int
    /// Swaps (kind `.swap`, either direction).
    var txSwapCount: Int
    /// Self-transfers (kind `.selfTransfer` / direction `.internal`).
    var txSelfTransferCount: Int
    /// Bridges (kind `.bridge`).
    var txBridgeCount: Int
    /// Failed transactions (status `.failed`).
    var txFailedCount: Int
    /// Pending transactions (status `.pending`).
    var txPendingCount: Int
    /// All persisted legs for this chain (the row total).
    var txTotalCount: Int

    // MARK: UTXO summary (UTXO chains: BTC / BCH / LTC / DOGE)

    /// Number of unspent outputs persisted for this chain (0 for
    /// account-model chains).
    var utxoCount: Int
    /// Sum of UTXO values in the chain's smallest unit (sats/koinu),
    /// decimal-string. `"0"` when there are none.
    var utxoTotalRaw: String

    // MARK: Sync state

    /// Whether the address has any on-chain activity.
    var isUsed: Bool
    /// Last successful aggregate rebuild for this chain.
    var lastSyncedAt: Date?
    /// `ChainSyncState.rawValue` — idle / syncing / synced / failed.
    var syncStateRaw: String

    // MARK: Encrypted private key

    /// AES-GCM `SealedBox.combined` ciphertext of this chain's private
    /// key (see `ChainKeyVault`). `nil` for watch-only wallets and until
    /// the one-time derivation runs. The symmetric key is in the Keychain;
    /// the blob is already authenticated-encrypted by us, so no store-level
    /// encryption attribute is needed.
    var encryptedPrivateKey: Data?

    /// Provenance tag for the encryption scheme (`"aesgcm256-v1"`), so a
    /// future key-rotation migration can recognize older blobs.
    var keyEncryptionScheme: String?

    init(
        id: UUID = UUID(),
        walletId: UUID,
        chainRaw: String,
        address: String,
        derivationPath: String = "",
        nativeBalanceRaw: String = "0",
        nativeDecimals: Int = 0,
        nativeFiat: Decimal = 0,
        totalFiat: Decimal = 0,
        tokenCount: Int = 0,
        fiatCurrencyCode: String = "USD",
        txSentCount: Int = 0,
        txReceivedCount: Int = 0,
        txSwapCount: Int = 0,
        txSelfTransferCount: Int = 0,
        txBridgeCount: Int = 0,
        txFailedCount: Int = 0,
        txPendingCount: Int = 0,
        txTotalCount: Int = 0,
        utxoCount: Int = 0,
        utxoTotalRaw: String = "0",
        isUsed: Bool = false,
        lastSyncedAt: Date? = nil,
        syncState: ChainSyncState = .idle,
        encryptedPrivateKey: Data? = nil,
        keyEncryptionScheme: String? = nil
    ) {
        self.id = id
        self.walletId = walletId
        self.chainRaw = chainRaw
        self.address = address
        self.derivationPath = derivationPath
        self.nativeBalanceRaw = nativeBalanceRaw
        self.nativeDecimals = nativeDecimals
        self.nativeFiat = nativeFiat
        self.totalFiat = totalFiat
        self.tokenCount = tokenCount
        self.fiatCurrencyCode = fiatCurrencyCode
        self.txSentCount = txSentCount
        self.txReceivedCount = txReceivedCount
        self.txSwapCount = txSwapCount
        self.txSelfTransferCount = txSelfTransferCount
        self.txBridgeCount = txBridgeCount
        self.txFailedCount = txFailedCount
        self.txPendingCount = txPendingCount
        self.txTotalCount = txTotalCount
        self.utxoCount = utxoCount
        self.utxoTotalRaw = utxoTotalRaw
        self.isUsed = isUsed
        self.lastSyncedAt = lastSyncedAt
        self.syncStateRaw = syncState.rawValue
        self.encryptedPrivateKey = encryptedPrivateKey
        self.keyEncryptionScheme = keyEncryptionScheme
    }

    /// Decoded chain, or `nil` if storage holds an unknown raw.
    var chain: SupportedChain? { SupportedChain(rawValue: chainRaw) }

    /// Decoded sync state (defensive default `.idle`).
    var syncState: ChainSyncState { ChainSyncState(rawValue: syncStateRaw) ?? .idle }

    /// Native balance parsed back to `Decimal`.
    var nativeBalance: Decimal { Decimal(string: nativeBalanceRaw) ?? 0 }
}

/// Lifecycle of one chain's aggregate row during a refresh.
enum ChainSyncState: String, Codable, Sendable {
    case idle      // never synced
    case syncing   // a refresh is in flight
    case synced    // last refresh completed
    case failed    // last refresh could not reach the chain
}

// MARK: - ChainUTXORecord

/// **One unspent transaction output — for UTXO chains only (BTC / BCH /
/// LTC / DOGE).**
///
/// User direction (2026-06-17): the per-chain database must persist
/// `utxos`. Until now UTXOs were fetched only at send-time
/// (`UTXOService`) and never stored; this model persists the set so the
/// chain row can summarize it (`ChainStateRecord.utxoCount` /
/// `utxoTotalRaw`) and a future "manage coins" surface can read it
/// without a network round-trip.
///
/// **Identity.** `(walletId, chainRaw, txid, vout)` — the canonical UTXO
/// outpoint — enforced by the repository's upsert.
@Model
final class ChainUTXORecord {
    @Attribute(.unique) var id: UUID

    var walletId: UUID
    var chainRaw: String
    var address: String

    /// Funding transaction id (hex).
    var txid: String
    /// Output index within the funding transaction.
    var vout: Int
    /// Output value in the chain's smallest unit (sats/koinu),
    /// decimal-string for precision parity with the rest of the schema.
    var valueSatsRaw: String
    /// Locking script (hex) when the provider returns it inline; `nil`
    /// for Esplora (the signer derives it locally for the own address).
    var scriptHex: String?
    /// Whether the funding tx is confirmed (vs still in mempool).
    var confirmed: Bool
    /// When this row was last refreshed.
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        walletId: UUID,
        chainRaw: String,
        address: String,
        txid: String,
        vout: Int,
        valueSatsRaw: String,
        scriptHex: String? = nil,
        confirmed: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.walletId = walletId
        self.chainRaw = chainRaw
        self.address = address
        self.txid = txid
        self.vout = vout
        self.valueSatsRaw = valueSatsRaw
        self.scriptHex = scriptHex
        self.confirmed = confirmed
        self.updatedAt = updatedAt
    }

    /// Value parsed back to `Int64` sats (0 on a malformed string).
    var valueSats: Int64 { Int64(valueSatsRaw) ?? 0 }
}
