import Foundation
import SwiftData

// MARK: - Schema v1

/// Versioned schema aggregator for Aperture's local SwiftData store. Lists
/// every `@Model` type the app persists.
///
/// **Not wired into the container (audited 2026-06-11).**
/// `ApertureDatabase` builds its `ModelContainer` from a plain
/// `Schema([...])` with no `SchemaMigrationPlan`, so only SwiftData's
/// automatic lightweight migration runs today — every schema change MUST
/// stay additive (new optional columns, or columns with defaults).
/// Wiring this type in safely requires freezing a copy of the model
/// types as they shipped: a migration stage needs a real V1 → V2 pair,
/// and pointing a single-version plan at the *current* model shape would
/// make the next additive change read as an unknown store version and
/// fail opens on already-shipped stores. Until that refactor lands,
/// treat this declaration as documentation of the model set.
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
            AppMetadataRecord.self,
            CustomTokenRecord.self,
            BrowserHistoryRecord.self,
            BrowserBookmarkRecord.self,
            HistoricalPriceRecord.self
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

    /// LEGACY (pre-2026-06-09). SF Symbol name used as the wallet's
    /// identity glyph in the original flat-circle avatar. The
    /// 2026-06-09 wallet-avatar redesign replaces this with a
    /// gradient-disc + glyph-or-monogram system; the canonical
    /// avatar storage is now the `avatarGradient` / `avatarSymbolType`
    /// / `avatarGlyph` / `avatarMonogram` / `avatarBadge` columns
    /// below. This field stays in the schema for source compatibility
    /// (SwiftData lightweight migration tolerates additive changes
    /// to a `@Model`; removing a column would be a destructive
    /// migration we don't need to take). Old rows decode their
    /// legacy value; new code reads the avatar* columns.
    var iconSymbol: String

    /// LEGACY (pre-2026-06-09). Hex color for the original flat-circle
    /// avatar background. Superseded by `avatarGradient` below; see
    /// the doc comment on `iconSymbol` for the migration rationale.
    var iconColorHex: String

    // MARK: - 2026-06-09 wallet-avatar redesign (gradient disc system)
    //
    // The seven columns below describe the wallet-avatar identity per
    // the design handoff at
    // `/Users/thuglifex/Downloads/design_handoff_wallet_avatars/`
    // (v3 expanded the original five columns with the two
    // `avatarCustomSvg` / `avatarCustomTint` columns for the Upload
    // tab). They hydrate into a `WalletAvatarSpec` via
    // `WalletAvatarSpec.hydrate(...)` and render through the
    // `WalletAvatar(spec:size:walletId:)` primitive.
    //
    // SwiftData lightweight migration handles additive columns
    // automatically. Pre-2026-06-09 rows decode these columns as the
    // schema's underlying-type default — empty `String("")` and `nil`
    // for optionals — and `WalletAvatarSpec.hydrate(...)` detects that
    // shape and falls back to `WalletAvatarSpec.auto(name:)` so the
    // wallet's disc is never blank. `ApertureDatabase.bootstrap()`
    // additionally calls `WalletRepository.backfillAvatarDefaults()`
    // on every open so the persisted columns themselves get backfilled
    // — read once, written once, then the live wallet edits flow.
    //
    // **Pre-v3 glyph rawValue retirement (2026-06-09 v3).** The v3
    // wallet-avatar glyph set replaces the prior 20 geometric marks
    // with 30 Lucide icons. Some prior rawValues — `dot`, `ring`,
    // `rings`, `dots`, `bars`, `hex`, `diamond`, `triangle`, `square`,
    // `bolt`, `heart`, `leaf`, `moon`, `key` — are no longer in
    // `WalletAvatarGlyph`. Rows whose `avatarGlyph` holds a retired
    // rawValue decode through `WalletAvatarGlyph(rawValue:)` as nil,
    // and `WalletAvatarSpec.hydrate(...)` falls through to a `.mono`
    // avatar on the wallet's initial. The wallet's chosen *gradient*
    // is preserved across this fallback. No crash, no blank disc.
    // See `WalletAvatarGlyph.swift` for the full retired-name list
    // and `WalletAvatarSpec.swift` for the hydrate path.

    /// Background gradient key — one of `WalletAvatarGradient`'s
    /// rawValues (`"graphite"`, `"slate"`, `"indigo"`, …). Default
    /// `"graphite"` — Aperture's monochrome brand register. New
    /// wallets created via `WalletRepository.createWallet(...)` are
    /// written with the `auto(name)` deterministic gradient, NOT the
    /// schema default — the schema default is the backstop for
    /// pre-migration rows whose hydrate path lands here.
    var avatarGradient: String

    /// Symbol type — `"glyph"` (iris or Lucide icon), `"mono"` (1-2
    /// letter monogram), or `"custom"` (user-uploaded sanitized SVG
    /// per the v3 Upload tab). Default `"mono"` so a pre-migration row
    /// with empty columns hydrates to a monogram from the wallet name;
    /// the new-wallet path overrides this from `auto(name)` (also
    /// `.mono` — the first character uppercased).
    var avatarSymbolType: String

    /// Glyph name when `avatarSymbolType == "glyph"`. One of
    /// `WalletAvatarGlyph.allCases` (`"iris"`, `"wallet"`, …,
    /// `"infinity"`). `nil` when the symbol type is mono or custom.
    var avatarGlyph: String?

    /// Monogram text when `avatarSymbolType == "mono"`. 1-2 characters,
    /// uppercased by the writer. `nil` when the symbol type is glyph
    /// or custom.
    var avatarMonogram: String?

    /// User-uploaded sanitized SVG text when `avatarSymbolType ==
    /// "custom"`. The output of `SVGSanitizer.sanitize(_:)` — guaranteed
    /// passive (no scripts, no event handlers, no remote refs) and
    /// ≤ 50 KB. The on-disc rendering goes through
    /// `WalletCustomSvgRenderer`'s WKWebView snapshot cache. `nil`
    /// when the symbol type is glyph or mono.
    var avatarCustomSvg: String?

    /// Tint choice for `.custom` SVGs — `"white"` (default;
    /// `brightness(0) invert(1)` filter applied so the SVG reads as a
    /// clean white silhouette on the gradient) or `"original"` (keep
    /// the SVG's source colors). `nil` when the symbol type is glyph
    /// or mono; the hydrate path also accepts `nil` for `.custom`
    /// and falls back to `.white`.
    var avatarCustomTint: String?

    /// Type badge raw value when present — `"watch"` / `"hardware"` /
    /// `"shared"`. Per the design handoff hard rule #4, this is
    /// DERIVED from `WalletRecord.kind` at hydrate time, not
    /// user-selectable. The column exists for future flexibility (a
    /// hand-tuned override surface a future agent might add), but
    /// today every hydrate call ignores the stored value and reads
    /// `WalletAvatarBadge.derive(from: kind)` instead.
    var avatarBadge: String?

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
        iconSymbol: String = WalletAvatarDefaults.legacySymbol,
        iconColorHex: String = WalletAvatarDefaults.legacyColorHex,
        avatarGradient: String? = nil,
        avatarSymbolType: String? = nil,
        avatarGlyph: String? = nil,
        avatarMonogram: String? = nil,
        avatarCustomSvg: String? = nil,
        avatarCustomTint: String? = nil,
        avatarBadge: String? = nil
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

        // 2026-06-09 avatar fields. If the caller didn't supply a
        // gradient / symbolType / monogram / glyph, we run the
        // deterministic `auto(name)` so the disc is never blank.
        // Per the design handoff's hard rule #3: *"New wallets
        // default via deterministic auto(name) (never blank)."*
        // The badge is derived from `kind` regardless of what the
        // caller passed in.
        let auto = WalletAvatarDefaults.spec(forName: name, kind: kind)
        self.avatarGradient = avatarGradient ?? auto.gradient
        self.avatarSymbolType = avatarSymbolType ?? auto.symbolType
        self.avatarGlyph = avatarGlyph ?? auto.glyph
        self.avatarMonogram = avatarMonogram ?? auto.monogram
        // v3 Upload-tab fields. New wallets land with nil for both —
        // `auto(name)` produces a `.glyph` (iris) default, not a
        // `.custom`. Manifest restore passes through whatever was
        // persisted at the prior mutation.
        self.avatarCustomSvg = avatarCustomSvg
        self.avatarCustomTint = avatarCustomTint
        self.avatarBadge = WalletAvatarBadge.derive(from: kind)?.rawValue
    }

    /// Decoded kind. Falls back to `.watchOnly` — the LEAST capable
    /// kind — if storage somehow holds an unknown raw. A corrupted
    /// record must never be granted send/sign capability it can't
    /// prove it has; watch-only suppresses both. Defensive only, the
    /// writer paths enumerate the cases — DEBUG builds assert so the
    /// corruption is caught in development.
    var kind: WalletKind {
        guard let decoded = WalletKind(rawValue: kindRaw) else {
            assertionFailure("WalletRecord.kindRaw holds unknown value \"\(kindRaw)\" — falling back to .watchOnly (least capable).")
            return .watchOnly
        }
        return decoded
    }

    /// The fully-hydrated `WalletAvatarSpec` for this wallet, resolved
    /// from the persisted columns + the wallet's name + kind. Every
    /// wallet-identity surface in the app reads this — `MainTabView`
    /// (tab icon), `WalletHomeView` (toolbar pill + long-press menu),
    /// `WalletSwitcherSheet` (rows), `WalletsListView` (rows),
    /// `WalletDetailView` (preview), `WalletIconPickerSheet` (live
    /// preview + grids). The hydrator handles the empty-column / auto
    /// (name) backstop so the disc is never blank.
    var avatarSpec: WalletAvatarSpec {
        WalletAvatarSpec.hydrate(
            gradient: avatarGradient,
            symbolType: avatarSymbolType,
            glyph: avatarGlyph,
            monogram: avatarMonogram,
            customSvg: avatarCustomSvg,
            customTint: avatarCustomTint,
            badge: avatarBadge,
            walletName: name,
            walletKind: kind
        )
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

    // MARK: - Legacy (pre-2026-06-09 flat-circle avatar)

    /// LEGACY. SF Symbol default for the pre-2026-06-09 flat-circle
    /// avatar. Retained so the schema's `iconSymbol` column has a
    /// non-empty default for source-compatible decode paths; the
    /// new avatar system reads the avatar* columns and ignores this.
    static let legacySymbol: String = "wallet.pass.fill"

    /// LEGACY. Background hex default for the pre-2026-06-09 avatar.
    /// Same story as `legacySymbol`.
    static let legacyColorHex: String = "#0B0D11"

    /// LEGACY alias — `symbol` and `colorHex` are referenced by older
    /// callers (the WalletRepository backfill path, a handful of view
    /// initializers) and stay here as one-line forwards until those
    /// call sites migrate to the spec-based primitive.
    static var symbol: String { legacySymbol }
    static var colorHex: String { legacyColorHex }

    // MARK: - 2026-06-09 gradient-disc avatar defaults

    /// Returns the deterministic auto(name) spec for a wallet with the
    /// given name and kind, in primitive-column form. This is the
    /// canonical default for a newly-created wallet — per the design
    /// handoff's hard rule #3: *"New wallets default via deterministic
    /// auto(name) (never blank)."*
    ///
    /// The badge is derived from `kind` in the same call so the writer
    /// path has a single source of truth for the avatar bundle.
    static func spec(
        forName name: String,
        kind: WalletKind
    ) -> (gradient: String, symbolType: String, glyph: String?, monogram: String?, badge: String?) {
        // 2026-06-09 — switched from deterministic `auto(name:)` to
        // `randomDefault()`. Per user direction: *"default icon for
        // any new created wallet for all users, same icon, but always
        // different color (Random color)"*. The `name` parameter is
        // kept on the API for source-compatibility (every caller
        // already passes it) and as the seed source for the legacy
        // pre-migration backfill path — which now also picks a random
        // gradient at one-time write, then stays sticky in the
        // `WalletRecord` columns.
        let spec = WalletAvatarSpec.randomDefault()
        _ = name // see doc comment — kept for API stability
        return (
            gradient: spec.gradient.rawValue,
            symbolType: spec.symbolType.rawValue,
            glyph: spec.glyph?.rawValue,
            monogram: spec.monogram,
            badge: WalletAvatarBadge.derive(from: kind)?.rawValue
        )
    }
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

    /// Stored copy of the owning address's UUID. Duplicates
    /// `address?.id` as a primitive column because `#Predicate`
    /// traversal of the optional `address` relationship can degrade
    /// to an in-memory full scan; repository predicates filter on
    /// this column directly. Optional so the column is an additive
    /// lightweight migration — pre-existing rows decode `nil` and are
    /// backfilled once per repository instance by
    /// `TransactionRepository.ensureLegacyAddressIdBackfill()`.
    /// Written alongside `address` at every insert in
    /// `TransactionRepository.upsertTransaction`.
    var addressId: UUID?

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

    /// Stored copy of the owning address's UUID. Duplicates
    /// `address?.id` as a primitive column for the same reason as
    /// `TransactionRecord.addressId`: `#Predicate` traversal of the
    /// optional `address` relationship can degrade to an in-memory
    /// full scan, and `upsertBalance` runs dozens of times per
    /// refresh. Optional so the column is an additive lightweight
    /// migration — pre-existing rows decode `nil` and are backfilled
    /// by `TransactionRepository.ensureLegacyAddressIdBackfill()`.
    /// Written alongside `address` at every insert in
    /// `TransactionRepository.upsertBalance`.
    var addressId: UUID?

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

// MARK: - CustomTokenRecord

/// One row per user-added token. Parallel to the static
/// `EVMTokenRegistry` / `SolanaTokenRegistry` entries but sourced
/// from the user pasting a contract / mint into "Add custom token."
///
/// **Why a separate model.** Static registries are the curated set —
/// audited from `SUPPORTED_ASSETS.md`, ship with every binary. Custom
/// tokens are user-typed contracts we read at runtime: their
/// `(name, symbol, decimals)` came from a live `eth_call` or Solana
/// mint-info / Metaplex fetch, their icon came from a Trust Wallet
/// probe at add-time. Persisting them as a distinct model keeps the
/// audit boundary clean (`CLAUDE.md` Rule #16 — Aperture reads what
/// the contract says about itself; the user, not Aperture, is the
/// vetter) and lets the scanner loop them in alongside the static
/// registry per chain.
///
/// **Dedup contract.** `(chainRaw, contract)` uniquely identifies a
/// custom token. The repository uses `dedupKey` for case-insensitive
/// comparison on the EVM side; Solana mints are case-sensitive (base58)
/// so the key keeps them verbatim.
///
/// **No seed material.** Same posture as `WalletRecord` — only public
/// on-chain metadata lives here. The contract is public; the icon URL
/// is public.
@Model
final class CustomTokenRecord {
    /// Stable identifier — UUID for the SwiftData unique key.
    @Attribute(.unique) var id: UUID

    /// `SupportedChain.rawValue`. Decoded back via
    /// `SupportedChain(rawValue:)` in callers.
    var chainRaw: String

    /// On-chain contract address (EVM EIP-55 form when the chain is
    /// EVM, base58 mint when Solana). Normalized at insert by the
    /// repository so subsequent dedup compares stably.
    var contract: String

    /// Ticker the user sees in the Tokens list (e.g. `"PEPE"`).
    var symbol: String

    /// Longer display name (e.g. `"Pepe"`). Same source as `symbol`
    /// — fetched on-chain when the contract exposes name(), else the
    /// user typed it manually in the Add sheet.
    var name: String

    /// On-chain `decimals()` for EVM, or the SPL mint's `decimals`
    /// byte for Solana. Cached so the scanner doesn't refetch on every
    /// balance read.
    var decimals: Int

    /// Trust Wallet logo URL if the HEAD probe succeeded at
    /// add-time; nil for "use the letter-glyph fallback." Stored as
    /// a string so the schema doesn't depend on the `URL` Codable
    /// surface (SwiftData prefers primitive types for forward
    /// compatibility).
    var iconURL: String?

    /// When the user added it. Drives the "Added · Jan 12" footnote
    /// in the Custom Tokens list.
    var addedAt: Date

    /// `true` if `name + symbol` came from a live chain fetch
    /// (`eth_call name()/symbol()` for EVM, Metaplex metadata for
    /// Solana). `false` if the user typed them manually because the
    /// contract didn't implement the standard surface. Surfaces a
    /// one-line "User-provided metadata" footnote on the row so
    /// the user has honest provenance per Rule #16.
    var metadataFromChain: Bool

    init(
        id: UUID = UUID(),
        chainRaw: String,
        contract: String,
        symbol: String,
        name: String,
        decimals: Int,
        iconURL: String? = nil,
        addedAt: Date = Date(),
        metadataFromChain: Bool = true
    ) {
        self.id = id
        self.chainRaw = chainRaw
        self.contract = contract
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.iconURL = iconURL
        self.addedAt = addedAt
        self.metadataFromChain = metadataFromChain
    }

    /// Composite key for deduplication: `"{chainRaw}|{contract.lowercased()}"`.
    /// EVM contracts are case-insensitive on chain; Solana base58 is
    /// case-sensitive but lowercasing never makes two distinct mints
    /// collide (base58's character set is strictly distinct upper /
    /// lower). The lowercased form is the conservative dedup key for
    /// both families.
    var dedupKey: String { "\(chainRaw)|\(contract.lowercased())" }

    /// `true` iff `chainRaw` decodes to a known `SupportedChain`.
    /// There is no safe default chain for a custom token — a row that
    /// fails this check must not be scanned or displayed as if it
    /// lived on Ethereum. Check this before trusting `chain`.
    var hasKnownChain: Bool {
        SupportedChain(rawValue: chainRaw) != nil
    }

    /// Decoded chain. Falls back to `.ethereum` if storage somehow
    /// holds an unknown raw — defensive only. Callers that can act on
    /// a corrupted row (scanners, dedup) gate on `hasKnownChain`
    /// first; the fallback exists solely so display surfaces outside
    /// the repository keep a non-optional read.
    var chain: SupportedChain {
        SupportedChain(rawValue: chainRaw) ?? .ethereum
    }
}

// MARK: - HistoricalPriceRecord

/// Per-day historical spot price for one `(symbol, fiat)` pair.
/// Feeds the `BalanceHistoryReconstructor` so the chart can value
/// past holdings at their **then-prices** rather than today's
/// — i.e. a wallet that held 1000 tokens at $4 each in the past
/// renders that peak as $4000, not as 1000 × today's-$0.05 = $50.
///
/// **Schema.** Composite key `"SYMBOL-FIAT-yyyymmdd"` so upserts
/// are a unique-key fetch. `dayKey` is the same integer
/// (yyyy × 10000 + mm × 100 + dd) the reconstructor computes from
/// each curve-point timestamp; this stores it explicitly so the
/// repository's range query is an integer comparison rather than a
/// date-string parse.
///
/// **Source.** Coinbase Exchange API `/products/{base}-{quote}/candles`
/// at daily granularity — `close` field. The same fallbacks the live
/// pricing layer uses (WrappedAssetAliases → ETH, KnownStablecoins
/// → USDT, EURPeggedStablecoins → EUR) apply at fetch time so
/// WETH gets ETH's history, AUSD gets USDT's, EURC gets EUR's.
///
/// **No TTL.** Historical prices are immutable by nature — May 1st's
/// close is the same forever. We only refetch when a new day rolls
/// over or when an old gap is discovered.
@Model
final class HistoricalPriceRecord {
    /// `"SYMBOL-FIAT-yyyymmdd"` composite key, e.g. `"USDT-USD-20260430"`.
    @Attribute(.unique) var key: String

    /// Uppercased token ticker.
    var symbol: String
    /// Uppercased fiat code (`USD`, `EUR`, etc.).
    var fiat: String
    /// `yyyy * 10000 + mm * 100 + dd` integer. Sortable + range-queryable.
    var dayKey: Int
    /// Closing spot price for the day in `fiat` per 1 token.
    var price: Decimal
    /// When this row was inserted (for cache-hit telemetry only — the
    /// price itself is immutable).
    var fetchedAt: Date

    init(symbol: String, fiat: String, dayKey: Int, price: Decimal, fetchedAt: Date = Date()) {
        let upperSymbol = symbol.uppercased()
        let upperFiat = fiat.uppercased()
        self.symbol = upperSymbol
        self.fiat = upperFiat
        self.dayKey = dayKey
        self.price = price
        self.fetchedAt = fetchedAt
        self.key = "\(upperSymbol)-\(upperFiat)-\(dayKey)"
    }
}

