import SwiftUI
import SwiftData

/// The wallet-home app-bar sync indicator (2026-06-14).
///
/// **Design intent (one sentence, Rule #2 §D.1):** in the app bar, show
/// the user whether their wallet is fetching fresh truth right now — and
/// when it finishes, dissolve that motion into the Aperture iris so the
/// bar reads as "at rest, this is your wallet."
///
/// **The two states it renders:**
/// 1. `isSyncing == true`  → a small, gently rotating
///    `arrow.triangle.2.circlepath` glyph — the *same* honest-motion mark
///    `SyncFreshnessLabel` already uses (Rule #2 §A.5 consistency). The
///    surface IS working, so it moves; the motion is the message.
/// 2. `isSyncing == false` → the real ``ApertureIrisView`` brand mark
///    (Rule #7 — the designed asset, never a hand-built logo), tinted
///    `UniColors.Brand.mark`. At rest, the bar carries the brand.
///
/// **The morph is native iOS 26 Liquid Glass.** Both states live inside a
/// single ``GlassEffectContainer`` and each carries `.glassEffect(in:)`
/// against a *shared* `.glassEffectID("sync-mark", in:)` — the shared id
/// is what tells the system "this is the SAME glass surface changing its
/// contents," so it morphs the syncing glyph into the iris rather than
/// crossfading two separate marks. Flipping the `if/else` under
/// `withAnimation` (driven here by `.animation(_, value:)`) engages that
/// morph — the translucency / specular / motion-response contract
/// (Rule #2 §B.1) is delivered by the system, not hand-rolled (Rule #3).
/// A toolbar item already adopts Liquid Glass on iOS 26, so this morph
/// happens inside the bar's native material.
///
/// **Data contract (Rule #27 — read state ONLY from the DB, live).** Like
/// ``SyncFreshnessLabel``, this view owns a one-row `@Query` on
/// `SyncStatusRecord` keyed by `(domain, scopeId)`. SwiftData re-runs the
/// query whenever the background sync writer flips `isSyncing` or stamps
/// `lastSyncedAt`, so the indicator flips syncing↔logo the instant the
/// store changes — no relaunch, no navigate-away (Rule #25). The view
/// holds no network type.
///
/// **RTL (Rule #11).** The brand mark must never mirror —
/// `.flipsForRightToLeftLayoutDirection(false)` opts the iris out of the
/// automatic RTL flip. The rotating sync glyph is rotationally symmetric,
/// so its direction is moot.
///
/// **Honesty survives the relocation (Rule #16 §B / Rule #27 §B).** The
/// visible "Updated 14:31" footnote moved off the wallet home into this
/// bar mark, so the freshness fact is carried by the indicator's
/// VoiceOver label — "Synced, updated 14:31" / "Syncing…" / "Not synced
/// yet" / "Updated 14:31, offline". The value is never silently passed
/// off as live: a screen reader hears the as-of time, and a sighted user
/// reads the same stamp on `AssetDetailView` and the per-asset surfaces
/// where ``SyncFreshnessLabel`` still lives.
struct SyncStatusToolbarMark: View {

    /// One-row query keyed on the unique `key` — identical pattern to
    /// `SyncFreshnessLabel`. SwiftData filters at the store level and
    /// re-runs whenever the sync writer saves a change to that row.
    @Query private var rows: [SyncStatusRecord]

    /// Shared namespace so `.glassEffectID` can morph the syncing glyph
    /// into the iris mark (and back) instead of cross-fading them.
    @Namespace private var glassNamespace

    /// The wallet home passes `domain: .balances, scopeId: <walletUUID>`.
    init(domain: SyncDomain, scopeId: String) {
        let key = SyncStatusRecord.makeKey(domain: domain, scopeId: scopeId)
        _rows = Query(filter: #Predicate<SyncStatusRecord> { $0.key == key })
    }

    var body: some View {
        // Reads ONLY the store (Rule #27). A nil record (writer hasn't
        // created the row yet) reads the same as "never synced" → the
        // at-rest iris.
        let record = rows.first
        let isSyncing = record?.isSyncing == true

        // Two glass surfaces in one region MUST share a
        // GlassEffectContainer (Rule #2 §B.6) — it's also what enables
        // the morph between the two `.glassEffectID`s.
        GlassEffectContainer(spacing: UniSpacing.s) {
            Group {
                if isSyncing {
                    syncingMark
                } else {
                    irisMark
                }
            }
        }
        // Flip under animation so the system morphs the glass identity
        // (Rule #2 §B.6 — `withAnimation` engages morphing). A calm,
        // restrained spring; the morph should feel like a settle, not a
        // bounce (Rule #2 §A.4 — the designer is invisible).
        .animation(.smooth(duration: 0.45), value: isSyncing)
        // One announcement, not a glyph name + stray runs.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(record: record, isSyncing: isSyncing))
    }

    // MARK: - States

    /// Syncing — the rotating honest-motion mark inside a glass surface
    /// that morphs from / to the iris.
    ///
    /// **No `.interactive()`.** This is a *status* surface, not a tap
    /// target — and `.interactive()` is for elements that respond to
    /// input (skill best-practice; Rule #2 §A.3 — a surface behaves as
    /// what it is). The three Liquid Glass behaviors (Rule #2 §B.1) are
    /// still all present: translucency + specular come from
    /// `.glassEffect()`; the motion-response is the morph itself
    /// (driven by `withAnimation`) plus the glass's ambient reaction to
    /// scroll / tilt that the system supplies for free.
    private var syncingMark: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(UniColors.Icon.secondary)
            // Native iOS 26 symbol animation — no hand-rolled rotation.
            .symbolEffect(.rotate, options: .repeating)
            .frame(width: 28, height: 28)
            .glassEffect(in: .circle)
            .glassEffectID("sync-mark", in: glassNamespace)
    }

    /// At rest — the real Aperture iris brand mark inside a glass surface
    /// that morphs from / to the syncing glyph. Real designed asset
    /// (Rule #7); never mirrors in RTL (Rule #11).
    private var irisMark: some View {
        ApertureIrisView(ringColor: UniColors.Brand.mark)
            .frame(width: 22, height: 22)
            .flipsForRightToLeftLayoutDirection(false)
            .frame(width: 28, height: 28)
            .glassEffect(in: .circle)
            .glassEffectID("sync-mark", in: glassNamespace)
    }

    // MARK: - Accessibility (the freshness fact, spoken)

    /// The honest as-of state, spoken — the visible footnote moved into
    /// the bar, so the timestamp lives here for VoiceOver (Rule #16 §B).
    private func accessibilityLabel(
        record: SyncStatusRecord?,
        isSyncing: Bool
    ) -> Text {
        if isSyncing {
            return Text("Syncing…")
        }
        guard let syncedAt = record?.lastSyncedAt else {
            return Text("Not synced yet")
        }
        if record?.lastErrorMessage != nil {
            return Text("Updated \(freshnessText(for: syncedAt)) · Offline")
        }
        return Text("Synced, updated \(freshnessText(for: syncedAt))")
    }

    /// Same concise as-of formatting as `SyncFreshnessLabel` (native,
    /// locale-aware — Rule #3): clock time for today, relative phrase for
    /// older syncs.
    private func freshnessText(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.relative(presentation: .named))
    }
}
