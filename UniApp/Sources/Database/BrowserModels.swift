import Foundation
import SwiftData

// MARK: - BrowserHistoryRecord

/// One row per dApp the user has visited via the in-app browser.
/// Drives the "Recent" section on `BrowserHomeView`.
///
/// **Composite uniqueness on `host`.** Visiting the same dApp twice
/// updates the existing row (`lastVisitedAt = now`, `visitCount += 1`)
/// rather than appending a duplicate. Safari's mobile history works
/// the same way — one row per host with a "last opened" timestamp,
/// not one row per page-view. Aperture's history surface is a
/// "what dApps am I using" register, not a per-URL audit log.
///
/// **Why we store the title.** The page's `<title>` is the
/// human-readable identity — "Uniswap Interface" reads more clearly
/// than `app.uniswap.org` in a list row. We still show the host
/// as a subtitle so the user can verify the canonical destination
/// (Rule #16 §A.5 — name the source).
///
/// **Eviction.** We keep up to 50 most-recent rows; the repository's
/// `recordVisit(...)` enforces the cap by trimming the oldest after
/// every insert. Honest about the cap — the user reads what they've
/// actually browsed recently, not a 10-year audit trail.
///
/// **Privacy.** History lives on-device only. There's no telemetry
/// upstream and no CloudKit sync. Per Rule #16 §A.5 the source-of-truth
/// claim is "Aperture sees the host because you typed or tapped it; no
/// one else does."
@Model
final class BrowserHistoryRecord {
    /// Stable identifier.
    @Attribute(.unique) var id: UUID

    /// Canonical URL last visited at this host. When the user
    /// navigates within the same host (e.g. uniswap.org/swap →
    /// uniswap.org/pool), this is the most recent one.
    var url: String

    /// Page `<title>` as reported by the WKWebView. Empty when
    /// the page hadn't loaded a title yet at recording time —
    /// the row falls back to the host in that case.
    var title: String

    /// Hostname. The "primary key" semantically — duplicates by
    /// host collapse into one row via `recordVisit(...)`.
    @Attribute(.unique) var host: String

    /// Published favicon URL when we observed one. `nil` until the
    /// browser caches a favicon for this host; the row renders the
    /// letter-chip fallback in that case.
    var iconURL: String?

    /// When the user last opened this dApp.
    var lastVisitedAt: Date

    /// How many times the user has opened this dApp. Drives a future
    /// "popular" sort and a low-confidence "frequently used" promotion.
    var visitCount: Int

    init(
        id: UUID = UUID(),
        url: String,
        title: String,
        host: String,
        iconURL: String? = nil,
        lastVisitedAt: Date = Date(),
        visitCount: Int = 1
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.host = host
        self.iconURL = iconURL
        self.lastVisitedAt = lastVisitedAt
        self.visitCount = visitCount
    }
}

// MARK: - BrowserBookmarkRecord

/// One row per user-bookmarked dApp. Layered on top of
/// `BrowserFavorite.starterSet` (the static curated set every user
/// sees on first launch): the user can pin or unpin starter set
/// entries (writes a row with `isFavorite`), reorder them
/// (`sortOrder`), or add new bookmarks from the URL bar (a future
/// "Add bookmark" affordance).
///
/// **Why a separate model from `BrowserHistoryRecord`.** History is
/// what the user did; bookmarks are what the user wants to keep.
/// Different lifecycle, different uniqueness semantics, different
/// pruning rules. Safari, Chrome, Firefox all separate the two —
/// for the same reasons.
///
/// **Today's surface.** The home view reads only the static
/// `BrowserFavorite.starterSet` in its Favorites grid. The
/// `BrowserBookmarkRecord` model exists so a follow-on turn can
/// flip the source without a schema change: the grid will read
/// `isFavorite: true` rows from this model + the static starter
/// set, with the persisted ones taking precedence.
@Model
final class BrowserBookmarkRecord {
    /// Stable identifier.
    @Attribute(.unique) var id: UUID

    /// Canonical URL the bookmark resolves to.
    var url: String

    /// User-facing name. Defaults to the page title at add time;
    /// editable from a future "Edit bookmark" sheet.
    var title: String

    /// Hostname — the cache key for the favicon and the canonical
    /// "where you'll land" string.
    @Attribute(.unique) var host: String

    /// Published favicon URL, when known.
    var iconURL: String?

    /// Display order in the Favorites grid. Lower = earlier.
    /// The grid sorts ascending so a user reorders by drag-and-drop
    /// (future affordance) without renaming the persisted rows.
    var sortOrder: Int

    /// `true` if the user has pinned this bookmark to the Favorites
    /// grid; `false` if it's a plain bookmark living in a future
    /// "All bookmarks" list.
    var isFavorite: Bool

    /// When the user added the bookmark. Drives a future "added on"
    /// footnote and the secondary "recency" sort.
    var addedAt: Date

    init(
        id: UUID = UUID(),
        url: String,
        title: String,
        host: String,
        iconURL: String? = nil,
        sortOrder: Int = 0,
        isFavorite: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.host = host
        self.iconURL = iconURL
        self.sortOrder = sortOrder
        self.isFavorite = isFavorite
        self.addedAt = addedAt
    }
}

// MARK: - ConnectedDAppRecord

/// One row per dApp the user has *actively connected* to via the in-app
/// browser — an approved `eth_requestAccounts` (EVM) or Solana `connect`.
/// Drives the "Connected dApps" section in `BrowserSettingsView`, shown
/// as a union with live `WalletConnectClient.activeSessions`.
///
/// **Connection ≠ history (Rule #16).** A dApp in `BrowserHistoryRecord`
/// is one the user *visited*; a dApp here is one the user *granted
/// account access to*. These are distinct lifecycles and must never be
/// conflated — visiting Uniswap doesn't mean Uniswap can read your
/// address, only that you opened the page. A row exists here only after
/// the user tapped "Connect" in `DAppConnectSheet` and
/// `DAppRequestRouter.approveConnect(...)` ran.
///
/// **Composite uniqueness on `host`.** Re-connecting the same dApp
/// updates the existing row (`connectedAt = now`, refreshes `name` /
/// `iconURL` / `chainLabel`) rather than appending a duplicate — the
/// same upsert-by-host shape as `BrowserHistoryRecord`. The in-memory
/// `connectedHosts: Set<String>` in the router is keyed by host too, so
/// the persisted row and the live allow-set stay one-to-one.
///
/// **Lifecycle.** Inserted/updated on connect; deleted on disconnect
/// (the EVM session teardown, the Solana `disconnect` RPC, or the user's
/// swipe-to-disconnect in settings). When the row is gone the dApp is no
/// longer listed as connected — an honest reflection of the granted set.
///
/// **Privacy.** Like the rest of the browser models, this lives
/// on-device only — no telemetry, no CloudKit sync. The store directory
/// is excluded from backups (see `ApertureDatabase.defaultStoreURL()`),
/// so a restored device starts with zero connected dApps and the user
/// re-grants honestly.
@Model
final class ConnectedDAppRecord {
    /// Stable identifier.
    @Attribute(.unique) var id: UUID

    /// Hostname — the "primary key" semantically. Duplicates by host
    /// collapse into one row via the upsert in
    /// `DAppRequestRouter.approveConnect(...)`. Matches the router's
    /// `connectedHosts` set keying so the persisted row and the live
    /// allow-set never drift.
    @Attribute(.unique) var host: String

    /// User-facing name — the page `<title>` reported when the user
    /// connected, falling back to the host when the page hadn't titled
    /// itself yet. Same human-readable-identity rationale as
    /// `BrowserHistoryRecord.title`.
    var name: String

    /// Canonical URL the dApp connected from.
    var url: String

    /// Published favicon URL when one was known at connect time. `nil`
    /// → the row renders the letter-chip fallback via
    /// `BrowserFaviconView`.
    var iconURL: String?

    /// When the user last connected (or re-connected) this dApp.
    var connectedAt: Date

    /// Human-readable chain the connection was made on (e.g.
    /// `"Ethereum"`, `"Solana"`) — `SupportedChain.displayName` at
    /// connect time. Stored as a display string rather than a chain
    /// rawValue because this surface only ever *shows* it; it never
    /// needs to decode back to a `SupportedChain`.
    var chainLabel: String

    /// How the dApp connected — `"injected"` for the in-app browser's
    /// EIP-1193 / Solana wallet-adapter bridge, reserved for
    /// `"walletconnect"` should a future turn persist WC sessions here
    /// too. Defaults to `"injected"` so this column is an additive
    /// lightweight migration: any row written before the column existed
    /// decodes the default.
    var transport: String

    init(
        id: UUID = UUID(),
        host: String,
        name: String,
        url: String,
        iconURL: String? = nil,
        connectedAt: Date = Date(),
        chainLabel: String,
        transport: String = "injected"
    ) {
        self.id = id
        self.host = host
        self.name = name
        self.url = url
        self.iconURL = iconURL
        self.connectedAt = connectedAt
        self.chainLabel = chainLabel
        self.transport = transport
    }
}
