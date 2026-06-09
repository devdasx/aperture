import Foundation
import SwiftData

// MARK: - Schema v1

/// Versioned schema aggregator for Aperture's local SwiftData store. Lists
/// every `@Model` type the app persists. Schema versioning lets us evolve
/// the data model without losing user data — when a model changes, bump
/// `versionIdentifier` and register a migration stage in
/// `ApertureDatabase.migrationPlan`.
///
/// Per `CLAUDE.md` Rule #2 §C, SwiftData is the canonical local-persistence
/// surface for domain state. Sensitive secrets (mnemonic seed, PIN hash)
/// never live in SwiftData — they live in Keychain via `SeedVault` and
/// `PinCodeStorage`. SwiftData only holds the **reference** to the
/// Keychain item via the wallet's UUID.
enum ApertureSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            WalletRecord.self,
            WalletAddressRecord.self,
            TransactionRecord.self,
            TokenBalanceRecord.self,
            CachedPriceRecord.self,
            BiometricEnrollmentRecord.self,
            AppMetadataRecord.self
        ]
    }
}

// MARK: - WalletRecord

/// One row per wallet the user has created or imported. The wallet's
/// **seed material is NOT stored here** — only a stable `id` (UUID) that
/// the `SeedVault` Keychain layer uses to look up the encrypted 64-byte
/// BIP-39 seed. This keeps the SwiftData store free of cryptographic
/// material; a SwiftData database leak (improbable on iOS but defensible
/// in depth) would expose wallet metadata only, not signing keys.
@Model
final class WalletRecord {
    /// Stable identifier. Used as the Keychain key suffix for the
    /// encrypted seed (see `SeedVault.seedKey(for:)`) and as the
    /// relationship target for addresses + transactions + balances.
    @Attribute(.unique) var id: UUID

    /// User-facing name. Default at creation time: "Wallet" (in the user's
    /// language); editable from a future Settings → Wallets row.
    var name: String

    /// How the wallet entered Aperture. Drives wallet-screen iconography
    /// and disables send/sign affordances for watch-only.
    var kindRaw: String

    /// Word count (12 or 24) for created wallets; nil for private-key or
    /// watch-only imports.
    var mnemonicWordCount: Int?

    /// `true` if the user set a BIP-39 passphrase at creation/import. The
    /// passphrase itself is NEVER persisted (BIP-39 spec — the user owns
    /// remembering it); this flag exists only so the unlock flow can
    /// prompt "Enter your passphrase" when needed (T-019).
    var hasPassphrase: Bool

    /// Legacy palette tag retained for source compatibility with older
    /// callers (the create / import flows wrote this as the literal
    /// `"default"`). The 2026-06-09 wallet-avatar redesign promotes
    /// `iconColorHex` to the canonical brand-color storage; `colorTag`
    /// is now a non-load-bearing hint that's read only by code paths
    /// pre-dating the avatar work. New code reads `iconColorHex`.
    var colorTag: String

    /// SF Symbol name used as the wallet's identity glyph — rendered
    /// inside the circular `WalletAvatar` that surfaces in the
    /// MainTabView Wallet tab icon, the wallet-home toolbar pill, the
    /// `WalletSwitcherSheet`, `WalletsListView`, `WalletDetailView`,
    /// and the Wallet-tab long-press `contextMenu`. Default value
    /// `"wallet.pass.fill"` (the iOS-native wallet glyph). Editable
    /// from Settings → Wallets → <wallet> via the curated 18-symbol
    /// picker; new symbols are added to the picker, not chosen freely
    /// from the 5000+ SF Symbols library (Rule #2 §A.6 restraint).
    ///
    /// 2026-06-09 schema additive change (Rule #1 BIG — migration
    /// + new identity surface). Old rows decode this field via the
    /// Swift-level default in `init(...)` and are also seeded by
    /// `ApertureDatabase.bootstrap()` to defend against future
    /// schema-decode quirks.
    var iconSymbol: String

    /// Hex color (`"#RRGGBB"`) for the circular avatar background.
    /// Selected by the user from the curated `UniColors.WalletAvatar`
    /// palette (12 colors). The hex is the canonical storage because
    /// it survives palette changes — adding / removing tokens in the
    /// palette doesn't strand an existing wallet's chosen identity.
    /// Default `"#0B0D11"` (Ink) — matches Aperture's monochrome
    /// brand register (Rule #2 §A.5 + Rule #16 §B).
    var iconColorHex: String

    /// Display order in the wallet list. Lower = earlier. Default:
    /// monotonically increasing on insert; user reorders via drag.
    var sortOrder: Int

    /// User-toggled hidden state. Hidden wallets do not appear on the
    /// main screen by default but remain in Settings → Wallets.
    var isHidden: Bool

    /// `true` until the user proves they backed up the recovery phrase.
    /// Mirrors `@AppStorage("hasUnbackedupWallet")` per-wallet — once
    /// multi-wallet ships, the per-wallet flag is the source of truth and
    /// the AppStorage one becomes a derived rollup.
    var requiresBackup: Bool

    /// Wall-clock at create / import time.
    var createdAt: Date

    /// Last time anything in this wallet changed (address derivation,
    /// balance refresh, name edit). Drives "last synced" footers.
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \WalletAddressRecord.wallet)
    var addresses: [WalletAddressRecord] = []

    init(
        id: UUID = UUID(),
        name: String,
        kind: WalletKind,
        mnemonicWordCount: Int?,
        hasPassphrase: Bool,
        colorTag: String,
        sortOrder: Int,
        requiresBackup: Bool,
        iconSymbol: String = WalletAvatarDefaults.symbol,
        iconColorHex: String = WalletAvatarDefaults.colorHex
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.mnemonicWordCount = mnemonicWordCount
        self.hasPassphrase = hasPassphrase
        self.colorTag = colorTag
        self.iconSymbol = iconSymbol
        self.iconColorHex = iconColorHex
        self.sortOrder = sortOrder
        self.isHidden = false
        self.requiresBackup = requiresBackup
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }

    /// Decoded kind. Falls back to `.created` if storage somehow holds an
    /// unknown raw — defensive only, the writer paths enumerate the cases.
    var kind: WalletKind {
        WalletKind(rawValue: kindRaw) ?? .created
    }
}

/// How a wallet came into being. Drives the wallet-row icon and the
/// capability set (watch-only suppresses send/sign).
enum WalletKind: String, Codable, CaseIterable, Sendable {
    case created          // BIP-39 mnemonic generated on this device
    case importedMnemonic // BIP-39 mnemonic imported from elsewhere
    case importedKey      // Single private key, one chain
    case watchOnly        // Read-only — public address or xpub
}

/// Default identity for a freshly-created wallet. Schema-level
/// constants live next to the schema so the migration backfill
/// path in `ApertureDatabase.bootstrap()` and every call site
/// (create / import flows, repository inserts, schema decode
/// fallback) reads from the same source of truth.
///
/// **Why a struct of static lets, not free vars.** Per the global
/// Swift-style rules (`~/.claude/rules/swift/coding-style.md`):
/// *"Use `static let` for constants over global constants."*
enum WalletAvatarDefaults {
    /// SF Symbol used when a wallet hasn't picked an identity glyph yet.
    /// The iOS-native wallet mark — reads as "the thing where my value
    /// lives" without borrowing Apple's own Wallet app's brand.
    static let symbol: String = "wallet.pass.fill"

    /// Default background hex — Ink (`#0B0D11`) — matches Aperture's
    /// monochrome brand register (Rule #2 §A.5 + Rule #16 §B). A
    /// fresh wallet's identity reads as the brand, not as a chosen
    /// color.
    static let colorHex: String = "#0B0D11"
}

// MARK: - WalletAddressRecord

/// One row per (wallet × chain) address. A single wallet derived from a
/// BIP-39 mnemonic has one row per supported chain (24 chains today per
/// `SUPPORTED_ASSETS.md`); a watch-only multi-address wallet has one
/// row per address; a single-private-key wallet has one row.
@Model
final class WalletAddressRecord {
    @Attribute(.unique) var id: UUID

    /// `SupportedChain.rawValue` so the schema doesn't depend on the
    /// chain enum's case order (additive changes don't break decodes).
    var chainRaw: String

    /// On-chain address in the chain's canonical encoding (EIP-55 for
    /// EVM, bech32 for native segwit, base58 for Solana, etc.).
    var address: String

    /// BIP-32 / BIP-44 derivation path that produced this address, e.g.
    /// `m/44'/60'/0'/0/0` for ETH index 0. Empty for watch-only inputs
    /// (the user supplied the address directly).
    var derivationPath: String

    /// Cached "has any on-chain activity" hint from the most recent
    /// balance scan. Drives the green "used" dot in review/list rows.
    var isUsed: Bool

    /// Wall-clock of the last successful balance scan for this address.
    /// `nil` until the first scan completes.
    var lastScannedAt: Date?

    /// Back-pointer to the owning wallet. SwiftData manages the inverse
    /// via the `WalletRecord.addresses` relationship.
    var wallet: WalletRecord?

    @Relationship(deleteRule: .cascade, inverse: \TransactionRecord.address)
    var transactions: [TransactionRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \TokenBalanceRecord.address)
    var balances: [TokenBalanceRecord] = []

    init(
        id: UUID = UUID(),
        chainRaw: String,
        address: String,
        derivationPath: String = "",
        isUsed: Bool = false
    ) {
        self.id = id
        self.chainRaw = chainRaw
        self.address = address
        self.derivationPath = derivationPath
        self.isUsed = isUsed
        self.lastScannedAt = nil
    }
}

// MARK: - TransactionRecord

/// One row per on-chain transaction touching one of the wallet's
/// addresses. Populated by the balance/history scanner (T-037..T-040).
/// Schema is intentionally chain-agnostic — per-chain quirks (Bitcoin's
/// vin/vout vs. EVM's from/to/value) collapse to a uniform direction +
/// amount + counterparty triple.
@Model
final class TransactionRecord {
    @Attribute(.unique) var id: UUID

    /// On-chain transaction hash (hex for EVM/Bitcoin; base58 for
    /// Solana; differs per chain). Together with `chainRaw` (inherited
    /// from the address) it uniquely identifies the transaction.
    var txHash: String

    /// `in` / `out` / `internal`. Distinguishes incoming credits from
    /// outgoing debits — the wallet's screen groups by direction.
    var directionRaw: String

    /// Amount as a decimal-string to preserve precision across the wide
    /// dynamic range of token decimals (8 for BTC, 18 for ETH, 6 for
    /// USDC, etc.). Stored as String because `Decimal` round-trips
    /// reliably through `String(describing:)` and SwiftData's native
    /// Decimal support has historically been quirky on some iOS minor
    /// releases — strings are bulletproof.
    var amountRaw: String

    /// Token symbol (`BTC`, `ETH`, `USDC`). For native sends this is the
    /// chain's native ticker; for token transfers it's the ERC-20 /
    /// SPL / etc. symbol from the contract.
    var tokenSymbol: String

    /// Token contract address (nil for native coins). EVM: ERC-20
    /// contract; Solana: SPL mint; etc.
    var tokenContract: String?

    /// Block number / slot / ledger sequence the transaction was
    /// included in. `nil` while pending.
    var blockNumber: Int64?

    /// On-chain timestamp.
    var occurredAt: Date

    /// `pending` / `confirmed` / `failed`. Drives the spinner / check /
    /// cross glyph in the transaction row.
    var statusRaw: String

    /// Counterparty address (sender for `.in`, receiver for `.out`). May
    /// be empty for `internal` transfers or contract calls without a
    /// clear counterparty.
    var counterparty: String

    /// Fee paid (in chain native units, decimal-string), if known.
    /// `nil` for incoming transactions where the wallet didn't pay the
    /// fee.
    var feeRaw: String?

    /// Back-pointer to the address.
    var address: WalletAddressRecord?

    init(
        id: UUID = UUID(),
        txHash: String,
        direction: TransactionDirection,
        amountRaw: String,
        tokenSymbol: String,
        tokenContract: String? = nil,
        blockNumber: Int64? = nil,
        occurredAt: Date,
        status: TransactionStatus,
        counterparty: String,
        feeRaw: String? = nil
    ) {
        self.id = id
        self.txHash = txHash
        self.directionRaw = direction.rawValue
        self.amountRaw = amountRaw
        self.tokenSymbol = tokenSymbol
        self.tokenContract = tokenContract
        self.blockNumber = blockNumber
        self.occurredAt = occurredAt
        self.statusRaw = status.rawValue
        self.counterparty = counterparty
        self.feeRaw = feeRaw
    }
}

enum TransactionDirection: String, Codable, Sendable { case incoming, outgoing, `internal` }
enum TransactionStatus: String, Codable, Sendable { case pending, confirmed, failed }

// MARK: - TokenBalanceRecord

/// Latest known balance of one token at one address. The scanner
/// (T-037..T-040) writes here; the wallet screen reads from here.
/// One row per (address, token symbol, contract) triple.
@Model
final class TokenBalanceRecord {
    @Attribute(.unique) var id: UUID

    /// Token symbol (e.g. `ETH`, `USDC`). Native coin uses the chain's
    /// native ticker and `tokenContract == nil`.
    var tokenSymbol: String

    /// Contract address (`nil` for native coins). Per
    /// `SUPPORTED_ASSETS.md` engineering rule #4, contract addresses are
    /// case-sensitive on non-EVM chains — stored verbatim, never
    /// normalized.
    var tokenContract: String?

    /// Decimals for this token. Read from on-chain `decimals()` (EVM)
    /// or the equivalent per-chain RPC; cached here to avoid a
    /// per-render lookup.
    var decimals: Int

    /// Raw integer balance as a string (e.g. `"1000000"` for 1 USDC
    /// because USDC has 6 decimals). Decimal-string for the same
    /// precision-preservation reason as `TransactionRecord.amountRaw`.
    var rawBalance: String

    /// Cached fiat-equivalent value at last refresh (in the user's
    /// preferred currency at scan time). Stale by design — the wallet
    /// screen refreshes it when prices update.
    var fiatValueCached: Decimal

    /// Currency code (`USD`, `EUR`, …) under which the cached fiat
    /// value was computed.
    var fiatCurrencyCode: String

    /// When the balance was last fetched from chain.
    var updatedAt: Date

    /// Back-pointer to the address.
    var address: WalletAddressRecord?

    init(
        id: UUID = UUID(),
        tokenSymbol: String,
        tokenContract: String? = nil,
        decimals: Int,
        rawBalance: String,
        fiatValueCached: Decimal = 0,
        fiatCurrencyCode: String = "USD",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tokenSymbol = tokenSymbol
        self.tokenContract = tokenContract
        self.decimals = decimals
        self.rawBalance = rawBalance
        self.fiatValueCached = fiatValueCached
        self.fiatCurrencyCode = fiatCurrencyCode
        self.updatedAt = updatedAt
    }
}

// MARK: - CachedPriceRecord

/// On-disk price cache. `CoinbasePriceService` has an in-memory 60s TTL;
/// this disk cache survives app launches and gives the wallet screen
/// instant ("zero-latency") fiat values on cold open before the live
/// fetch completes. The live fetch then updates the row in place.
@Model
final class CachedPriceRecord {
    /// `"SYMBOL-FIAT"` composite key, e.g. `"BTC-USD"`. Unique so the
    /// upsert is a fetch-then-update by id.
    @Attribute(.unique) var key: String

    /// Token ticker.
    var symbol: String
    /// Fiat code.
    var fiat: String
    /// Spot price in fiat per 1 token.
    var price: Decimal
    /// When the price was fetched.
    var fetchedAt: Date
    /// Source label (e.g. `"coinbase"`). Future providers stack on the
    /// same schema (Kraken, CoinGecko) — the source name surfaces in
    /// the wallet-screen footer per Rule #16's "name your data source"
    /// honesty requirement.
    var source: String

    init(symbol: String, fiat: String, price: Decimal, fetchedAt: Date = Date(), source: String) {
        self.key = "\(symbol)-\(fiat)"
        self.symbol = symbol
        self.fiat = fiat
        self.price = price
        self.fetchedAt = fetchedAt
        self.source = source
    }
}

// MARK: - BiometricEnrollmentRecord

/// Snapshot of the device's biometric enrollment state at the last time
/// the user enabled Face ID / Touch ID / Optic ID in Aperture. Stored so
/// the next launch can detect that the user changed their biometric
/// enrollment in iOS Settings (added or removed a Face ID, registered a
/// new fingerprint, etc.) and prompt for re-enrollment per the user's
/// 2026-06-06 direction.
///
/// **Mechanism.** Apple's `LAContext.evaluatedPolicyDomainState` returns
/// an opaque `Data` hash of the current biometric enrollment. When
/// enrollment changes, the hash changes. We compare the stored snapshot
/// against the current one on every cold launch and on every
/// `applicationWillEnterForeground`; mismatch → set
/// `requiresBiometricReenrollment = true` in `AppMetadataRecord` and
/// disable `@AppStorage("biometricEnabled")`. The next time the user
/// reaches a biometric-gated surface, they're prompted to re-enable Face
/// ID; on success, the new snapshot replaces the old.
@Model
final class BiometricEnrollmentRecord {
    @Attribute(.unique) var id: UUID

    /// The `LAContext.evaluatedPolicyDomainState` hash captured the last
    /// time the user authenticated successfully via biometrics. Compared
    /// to the current device snapshot to detect enrollment changes.
    var domainStateSnapshot: Data?

    /// When the snapshot was recorded.
    var updatedAt: Date

    init(id: UUID = UUID(), domainStateSnapshot: Data?, updatedAt: Date = Date()) {
        self.id = id
        self.domainStateSnapshot = domainStateSnapshot
        self.updatedAt = updatedAt
    }
}

// MARK: - AppMetadataRecord

/// Single-row "app-wide" state. Bootstrapped on first launch in
/// `ApertureDatabase.bootstrap(_:)`. Holds counters and one-shot flags
/// the app reads to make decisions at launch — schema version (for
/// migrations), first-launch timestamp, last-opened timestamp, and the
/// biometric re-enrollment flag.
@Model
final class AppMetadataRecord {
    @Attribute(.unique) var id: UUID

    /// Schema version the row was last written under. Forwards-compat
    /// helper — a migration plan that bumps the schema reads this to
    /// decide which migration stages to run.
    var schemaVersion: Int

    /// Wall-clock at first launch. Useful as a "you've had Aperture for
    /// N days" surface in About, and as one input to "is this a fresh
    /// install or did the user delete + reinstall" heuristics.
    var firstLaunchAt: Date

    /// Last time the app was foregrounded. Updated by
    /// `ApertureDatabase.markOpened()`.
    var lastOpenedAt: Date

    /// `true` after `BiometricEnrollmentTracker` detects an enrollment
    /// change. The unlock flow / Settings → Security reads this to
    /// surface a one-tap re-enable affordance; cleared back to `false`
    /// when the user successfully re-authenticates.
    var requiresBiometricReenrollment: Bool

    init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        firstLaunchAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        requiresBiometricReenrollment: Bool = false
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.firstLaunchAt = firstLaunchAt
        self.lastOpenedAt = lastOpenedAt
        self.requiresBiometricReenrollment = requiresBiometricReenrollment
    }
}
