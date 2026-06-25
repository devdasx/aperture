import SwiftUI
import UIKit

/// Sheet presentation modifier that sizes the sheet to **exactly its
/// content's intrinsic height** — no taller (no empty space below the
/// content), no shorter (no clipped content). The Apple-blessed
/// equivalent for "fit to content" sheets, used here in place of fixed
/// `.medium` / `.large` detents.
///
/// **Why this is necessary (M-005 context).** Fixed proportional detents
/// (`.medium`, `.large`) and even multi-detent sets like
/// `[.medium, .large]` give the user a sheet that's either too tall
/// (wasted whitespace below the content — what the user complained about
/// 2026-06-05) or too short (clips translated copy in non-English
/// locales — what M-005 captures). The only correct sheet height for a
/// warning sheet is "exactly the content's natural rendered height in
/// the user's locale and Dynamic Type size." That's what this modifier
/// produces.
///
/// **Mechanism.** Two steps, both pure SwiftUI / iOS 26 native — no
/// third-party packages (Rule #3):
///
/// 1. Wrap the content's background in a `GeometryReader` and emit the
///    content's measured vertical size via a `PreferenceKey`.
/// 2. Receive that measurement, store it in `@State`, and pass it as
///    `[.height(measured)]` to `presentationDetents`.
///
/// Because the modifier applies `.fixedSize(horizontal: false, vertical: true)`
/// before the measurement layer, the wrapped content reports its
/// **intrinsic** vertical size, not its constrained size. That breaks
/// the chicken-and-egg of "sheet height drives content height drives
/// detent drives sheet height": the intrinsic height is independent of
/// the sheet's current frame, so the measurement converges in a single
/// frame.
///
/// **First-frame fallback.** Before the first measurement arrives the
/// modifier uses `.fraction(0.5)` as a conservative initial detent —
/// large enough that most warning-sheet content renders correctly on
/// the first frame, small enough that the snap-to-measured-height that
/// follows is visually subtle.
///
/// **Edge case: content taller than the screen.** `presentationDetents`
/// caps `.height(N)` at the system maximum (the sheet never exceeds
/// available vertical space). If the content's intrinsic height is
/// larger than that cap, the sheet snaps to the cap and the inner
/// `ScrollView` (or the user's drag) handles the overflow. Warning
/// sheets in UniApp don't reach this case in practice.
///
/// **Usage.** Apply inside the `.sheet { … }` closure as the outermost
/// modifier on the sheet content, **before** `.presentationBackground`:
///
/// ```swift
/// .sheet(isPresented: $isPresented) {
///     MyWarningSheet(…)
///         .uniAppEnvironment()
///         .intrinsicHeightSheet()
///         .presentationBackground(UniColors.Background.primary)
/// }
/// ```
///
/// **Do not** add an explicit `.presentationDetents(…)` at the same
/// call site; the modifier owns that. Adding both makes the SwiftUI
/// presentation system pick one arbitrarily and breaks the intended
/// content-sized behavior.
/// Preference carrying the sheet content's intrinsic height. Emitted
/// by `UniSheet`'s hidden `intrinsicProbe` background and read by
/// `UniIntrinsicHeightSheetModifier`. Module-internal access so
/// `UniSheet` can emit it from a separate file.
///
/// **2026-06-07 visibility change.** Previously `private` to the
/// modifier file — the modifier itself owned the emission via a
/// `.fixedSize` + `GeometryReader` background on the content. After
/// the small-iPhone safe-area-overflow fix moved the `.fixedSize`
/// measurement to a hidden duplicate inside `UniSheet`, the key
/// became a cross-file coordination primitive and needed broader
/// access.
struct UniSheetIntrinsicHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Use the latest non-zero measurement. The GeometryReader can
        // briefly emit 0 during teardown; ignoring those preserves the
        // last good measurement so the sheet doesn't shrink mid-animation.
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Preference carrying the sheet's actually-rendered height (i.e.
/// the vertical space the system gives the sheet after detent
/// clamping and safe-area insets). The modifier reads this and
/// compares it against the intrinsic height to decide whether the
/// content fits — and therefore whether to use a content-sized
/// `.height(_)` detent or fall back to `.large` (letting the
/// `ScrollView` inside `UniSheet` handle the overflow).
private struct UniSheetRenderedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct UniIntrinsicHeightSheetModifier: ViewModifier {
    /// Intrinsic content height — what the sheet WANTS to be.
    /// Measured by `UniSheet`'s hidden `intrinsicProbe`.
    @State private var intrinsicHeight: CGFloat = 0
    /// Rendered sheet height — what the system actually GIVES us
    /// after detent clamping and safe-area insets. Measured by the
    /// `GeometryReader` background below.
    @State private var renderedHeight: CGFloat = 0
    /// Whether the sheet is currently in the `.large` fallback state.
    /// Sticky with hysteresis (see `detentHysteresis`) so the detent
    /// doesn't oscillate when `intrinsicHeight ≈ renderedHeight` —
    /// without it, a content-sized detent whose rendered height lands
    /// a fraction of a point under the intrinsic flips to `.large`,
    /// which changes the rendered height, which flips back, forever.
    @State private var usesLargeFallback = false

    /// Hysteresis band, in points. The detent only switches to
    /// `.large` when the intrinsic height exceeds the rendered space
    /// by MORE than this, and only switches back to content-sized
    /// when the intrinsic height is below the rendered space by MORE
    /// than this. Inside the band the current state holds — an
    /// overflow of ≤ 8pt is absorbed by `UniSheet`'s inner ScrollView.
    private static let detentHysteresis: CGFloat = 8

    func body(content: Content) -> some View {
        // Two-layer measurement pattern, redesigned 2026-06-07 to
        // fix the small-iPhone safe-area-overflow bug. Previously
        // the modifier applied `.fixedSize(vertical: true)` to the
        // visible content to measure its intrinsic height — but
        // `.fixedSize` opts the content out of parent constraints,
        // including the sheet's bottom safe-area inset. When
        // intrinsic > available, the content overflowed past the
        // sheet bottom and pushed the action button into the home
        // indicator zone (user-reported via OpenSourceSheet
        // screenshot 2026-06-07).
        //
        // **New design.** The visible content has NO `.fixedSize`
        // — it flows naturally and respects all safe areas. The
        // intrinsic-height measurement lives in a hidden duplicate
        // inside `UniSheet` (see `UniSheet.intrinsicProbe`), which
        // emits via `UniSheetIntrinsicHeightKey`. This modifier
        // also adds a second `GeometryReader` background to read
        // the sheet's actually-rendered height (after detent
        // clamping), emitted via `UniSheetRenderedHeightKey`.
        // The detent decision is driven by comparing the two: if
        // intrinsic fits the rendered space, use a content-sized
        // detent; if it overflows, use `.large` and let the
        // ScrollView in `UniSheet` scroll.
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: UniSheetRenderedHeightKey.self,
                            value: proxy.size.height
                        )
                }
            }
            .onPreferenceChange(UniSheetIntrinsicHeightKey.self) { newHeight in
                // Debounce sub-pixel jitter so the detent doesn't
                // re-animate on every frame.
                if abs(newHeight - intrinsicHeight) > 0.5 && newHeight > 0 {
                    intrinsicHeight = newHeight
                    updateDetentDecision()
                }
            }
            .onPreferenceChange(UniSheetRenderedHeightKey.self) { newHeight in
                if abs(newHeight - renderedHeight) > 0.5 && newHeight > 0 {
                    renderedHeight = newHeight
                    updateDetentDecision()
                }
            }
            .presentationDetents(currentDetents)
            .presentationDragIndicator(.visible)
            // iPad / Mac form-sheet sizing (Rule #3 — native iOS 18+ API).
            // On COMPACT width (iPhone) `.presentationSizing(.fitted)` defers
            // to the bottom-sheet `.presentationDetents` set above, so the
            // iPhone experience is byte-for-byte unchanged — the
            // `[.height(intrinsicHeight)]` / `.large` detent logic still
            // owns the height. On REGULAR width (iPad / Mac) the system
            // presents a centered form sheet that IGNORES `.height(_)`
            // detents and otherwise falls back to a FIXED form-sheet height
            // that CLIPS taller content (the create-wallet disclosure sheet's
            // ack toggle + buttons were cut off — user-reported iPad bug
            // 2026-06-16). `.fitted` makes the regular-width form sheet size
            // to its content's intrinsic height instead, so the same
            // content-sized behavior the iPhone already has now applies on
            // iPad. The inner `ScrollView` in `UniSheet` still absorbs any
            // overflow if content exceeds the system's form-sheet cap.
            // 2026-06-17: routed through `uniSheetSizing()` so iPad uses a
            // `.page` sheet (scrolls, never collapses) instead of `.fitted`
            // (which collapsed full-content sheets to a tiny centered card).
            .uniSheetSizing()
    }

    /// Decided detent set, computed from the latest intrinsic and
    /// rendered heights.
    ///
    /// **Three-state logic.**
    /// 1. **Before any measurement** — fall back to `.medium` as a
    ///    conservative initial detent. iOS uses this for the first
    ///    frame; once measurements arrive (typically within the
    ///    same render pass), the detent snaps to the correct one.
    /// 2. **Intrinsic measured, rendered not yet** — trust the
    ///    intrinsic and request `[.height(intrinsic)]`. iOS clamps
    ///    automatically if intrinsic > available; the next
    ///    `renderedHeight` update will tell us whether we need to
    ///    fall back to `.large`.
    /// 3. **Both measured** — if intrinsic fits the rendered space,
    ///    stay content-sized via `[.height(intrinsic)]`. If
    ///    intrinsic overflows the rendered space (small iPhones,
    ///    long translated copy, large Dynamic Type), use `.large`
    ///    so the system gives us the full available space and the
    ///    inner `ScrollView` handles the overflow.
    ///
    /// **Convergence & hysteresis.** The fit decision is sticky:
    /// `updateDetentDecision()` only flips `usesLargeFallback` when
    /// the intrinsic height crosses the rendered space by more than
    /// `detentHysteresis` in either direction. Switching to `.large`
    /// gives more rendered height; if the intrinsic now fits with
    /// margin, the next preference update switches back to
    /// `.height(intrinsic)`. This stabilizes at the largest detent
    /// that allows the content to fit, OR at `.large` if even that
    /// isn't enough — and never ping-pongs when the two measurements
    /// land within a few points of each other.
    private var currentDetents: Set<PresentationDetent> {
        guard intrinsicHeight > 0 else { return [.medium] }
        guard renderedHeight > 0 else { return [.height(intrinsicHeight)] }
        return usesLargeFallback ? [.large] : [.height(intrinsicHeight)]
    }

    /// Re-evaluates the sticky `.large`-fallback flag against the
    /// latest measurements, applying the hysteresis band so the
    /// detent doesn't oscillate when `intrinsicHeight ≈ renderedHeight`.
    private func updateDetentDecision() {
        guard intrinsicHeight > 0, renderedHeight > 0 else { return }
        if usesLargeFallback {
            // Only leave `.large` when the content fits the rendered
            // space with clear margin.
            if intrinsicHeight < renderedHeight - Self.detentHysteresis {
                usesLargeFallback = false
            }
        } else {
            // Only enter `.large` when the content overflows the
            // rendered space by more than the band — small overflows
            // are absorbed by the inner ScrollView.
            if intrinsicHeight > renderedHeight + Self.detentHysteresis {
                usesLargeFallback = true
            }
        }
    }
}

extension View {
    /// Apply inside a `.sheet { … }` closure to size the presenting
    /// sheet to exactly its content's intrinsic height. See
    /// `UniIntrinsicHeightSheetModifier` for the full rationale and
    /// usage rules.
    ///
    /// Replaces explicit `.presentationDetents(…)` calls — do not add
    /// both on the same call site.
    func intrinsicHeightSheet() -> some View {
        modifier(UniIntrinsicHeightSheetModifier())
    }

    /// **The single canonical detent + iPad-sizing modifier** for every
    /// explicit-detent sheet in UniApp. Replaces the bare
    /// `.presentationDetents(_:)` call at the ~25 sheet sites that use
    /// fixed `[.large]` / `[.medium]` / `[.medium, .large]` detents
    /// (Receive, Send review/fee, the Settings nav sheets, etc.).
    ///
    /// **What it does, and why it's one modifier not 25 edits.** It
    /// applies the passed `detents` exactly as before AND adds the
    /// native iOS 18+ `.presentationSizing(.fitted)` so the fix lands
    /// at one shared surface that every call site adopts, instead of
    /// 25 hand-edits that drift apart over time.
    ///
    /// **Compact width (iPhone) — unchanged.** On compact width
    /// `.presentationSizing(.fitted)` defers to the bottom-sheet
    /// `detents`, so the iPhone presentation is byte-for-byte identical
    /// to the prior `.presentationDetents(detents)` call. The detents
    /// still rule the height; nothing about the iPhone sheet moves.
    ///
    /// **Regular width (iPad / Mac) — fixed.** The system presents a
    /// centered form sheet that ignores the bottom-sheet `detents` and
    /// otherwise falls back to a FIXED form-sheet height that CLIPS
    /// taller content (user-reported iPad bug 2026-06-16). `.fitted`
    /// makes the regular-width form sheet size to its content instead,
    /// so iPad sheets fit their content the way iPhone sheets already
    /// do. Content that genuinely overflows a fitted form sheet must
    /// live inside a `ScrollView` so it scrolls rather than clips.
    ///
    /// **Usage** (drop-in replacement for `.presentationDetents`):
    /// ```swift
    /// .sheet(isPresented: $isShowing) {
    ///     SomeSheet()
    ///         .uniAppEnvironment()
    ///         .uniSheetDetents([.large])
    ///         .presentationBackground(UniColors.Background.primary)
    /// }
    /// ```
    func uniSheetDetents(_ detents: Set<PresentationDetent>) -> some View {
        self
            .presentationDetents(detents)
            .uniSheetSizing()
    }
}

extension View {
    /// The one place that chooses a presentation SIZE per device, so both the
    /// detent path (`uniSheetDetents`) and the intrinsic-height path share it.
    ///
    /// **iPhone (unchanged) → `.fitted`.** On compact width `.fitted` defers to
    /// the bottom-sheet `.presentationDetents`, so the iPhone sheet is
    /// byte-for-byte what it has always been — and it works perfectly.
    ///
    /// **iPad / Mac (fixed 2026-06-17) → `.page`.** `.fitted` sizes a
    /// regular-width sheet to its content's *intrinsic* size — and a full
    /// navigation surface (Receive, the filter/options sheets, Settings
    /// nav sheets) has no intrinsic size, so iPad collapsed it into a tiny
    /// centered card (user-reported). `.page` presents the standard large iPad
    /// page sheet that **scrolls** tall content instead of clipping it and
    /// never collapses. This supersedes the 2026-06-16 `.fitted` attempt,
    /// which fixed clipping on iPad but introduced the collapse.
    @ViewBuilder
    func uniSheetSizing() -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            self.presentationSizing(.fitted)
        } else {
            self.presentationSizing(.page)
        }
    }
}
