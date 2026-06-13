import SwiftUI
import SwiftData

/// The honest freshness whisper (Rule #16 §B / Rule #27 §B).
///
/// **Design intent (one sentence per Rule #2 §D.1):** tell the user how
/// old the number above it is, so a value served from the local store
/// never silently masquerades as real-time.
///
/// This is a *whisper*, not a banner. It reads one `SyncStatusRecord`
/// for a `(domain, scope)` pair via its own `@Query` — so it updates
/// live the instant the background sync writer flips `isSyncing` or
/// stamps `lastSyncedAt` (Rule #25, Rule #27 §A). The view layer reads
/// only the store; it holds no network type.
///
/// **Reusable.** The wallet home reads the active wallet's `.balances`
/// row; `AssetDetailView` and future surfaces pass their own
/// `(domain, scopeId)` — e.g. `.prices` / `"global"`, or `.transactions`
/// for a specific wallet. One component, every freshness surface.
///
/// **The states it renders (honest, restrained — Rule #16):**
/// 1. `isSyncing == true`        → "Syncing…" (the one place a glyph
///    earns its keep — a small `arrow.triangle.2.circlepath` signals
///    motion; it is the only icon, and only while moving).
/// 2. `lastSyncedAt != nil`      → "Updated 14:31" (same day → clock
///    time; older → "yesterday" / "3 days ago", native + locale-aware).
///    If `lastErrorMessage != nil` as well, the data is stale-with-error
///    → "Updated 14:31 · Offline" — tertiary text, *never* red. Offline
///    is a calm fact, not an alarm.
/// 3. `lastSyncedAt == nil`      → "Not synced yet" — the quietest line,
///    for a fresh wallet before its first successful refresh.
///
/// Typography is `UniTypography.footnote`; color is
/// `UniColors.Text.tertiary` — the most restrained legible register.
/// No alarming color. No background. No border. It is ambient status.
struct SyncFreshnessLabel: View {

    /// One-row query keyed on the unique `key`. SwiftData filters at the
    /// store level (not in the body) and re-runs whenever the sync writer
    /// saves a change to that row, so the stamp updates live with no
    /// relaunch / no navigation (Rule #25).
    @Query private var rows: [SyncStatusRecord]

    /// The wallet home passes `domain: .balances, scopeId: <walletUUID>`.
    /// Global domains (`prices`, `historical`) pass
    /// `scopeId: SyncDomain.globalScope`.
    init(domain: SyncDomain, scopeId: String) {
        // Compose the unique key, then bind the `@Query` to a predicate
        // on it — `key` is `@Attribute(.unique)`, so this fetches at most
        // one row. Capturing into a local keeps the `#Predicate` macro's
        // autoclosure free of `self`.
        let key = SyncStatusRecord.makeKey(domain: domain, scopeId: scopeId)
        _rows = Query(filter: #Predicate<SyncStatusRecord> { $0.key == key })
    }

    var body: some View {
        // Reads ONLY the store (Rule #27). A nil record (writer hasn't
        // created the row yet) reads the same as "never synced".
        let record = rows.first

        Group {
            if record?.isSyncing == true {
                syncingLabel
            } else if let syncedAt = record?.lastSyncedAt {
                updatedLabel(
                    syncedAt: syncedAt,
                    isStale: record?.lastErrorMessage != nil
                )
            } else {
                neverSyncedLabel
            }
        }
        .font(UniTypography.footnote)
        .foregroundStyle(UniColors.Text.tertiary)
        // The whole whisper is one announcement to VoiceOver, not three
        // separate runs ("arrow.triangle.2.circlepath" would otherwise
        // be read as a meaningless glyph name).
        .accessibilityElement(children: .combine)
    }

    // MARK: - States

    private var syncingLabel: some View {
        HStack(spacing: UniSpacing.xxs) {
            Image(systemName: "arrow.triangle.2.circlepath")
                // A continuous rotation while syncing reads as honest
                // motion (the surface IS working), not decoration.
                // `.symbolEffect(.rotate)` is the native iOS 26 symbol
                // animation — no hand-rolled rotation.
                .symbolEffect(.rotate, options: .repeating)
                .accessibilityHidden(true)
            Text("Syncing…")
        }
    }

    @ViewBuilder
    private func updatedLabel(syncedAt: Date, isStale: Bool) -> some View {
        if isStale {
            // Stale data we're still showing while offline / after a
            // failed attempt. Honest: the number is real but its as-of
            // time is old. Tertiary text, never red (Rule #16 §B).
            Text("Updated \(freshnessText(for: syncedAt)) · Offline")
        } else {
            Text("Updated \(freshnessText(for: syncedAt))")
        }
    }

    private var neverSyncedLabel: some View {
        Text("Not synced yet")
    }

    // MARK: - Formatting (native — Rule #3)

    /// A concise as-of string: a clock time for today's syncs
    /// (`14:31`), a native relative phrase for older ones
    /// (`yesterday`, `3 days ago`). Both are locale-aware and render
    /// their numeric runs LTR inside an RTL line via the Unicode BiDi
    /// algorithm (Rule #11) — no manual direction override needed.
    private func freshnessText(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            // `.dateTime.hour().minute()` → "14:31" / "2:31 PM" per the
            // user's locale + 12/24h setting. Foundation owns the format.
            return date.formatted(.dateTime.hour().minute())
        }
        // `.relative(presentation: .named)` → "yesterday" / "3 days
        // ago" / "last Tuesday", localized by Foundation.
        return date.formatted(.relative(presentation: .named))
    }
}
