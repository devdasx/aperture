import SwiftUI

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
                }
            }
            .onPreferenceChange(UniSheetRenderedHeightKey.self) { newHeight in
                if abs(newHeight - renderedHeight) > 0.5 && newHeight > 0 {
                    renderedHeight = newHeight
                }
            }
            .presentationDetents(currentDetents)
            .presentationDragIndicator(.visible)
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
    /// **Convergence.** The transient between detent changes
    /// settles in one or two extra frames: switching to `.large`
    /// gives more rendered height; if that's now enough to fit
    /// the intrinsic, we switch back to `.height(intrinsic)` on
    /// the next preference update. This stabilizes at the largest
    /// detent that allows the content to fit, OR at `.large` if
    /// even that isn't enough.
    private var currentDetents: Set<PresentationDetent> {
        guard intrinsicHeight > 0 else { return [.medium] }
        guard renderedHeight > 0 else { return [.height(intrinsicHeight)] }
        if intrinsicHeight <= renderedHeight {
            return [.height(intrinsicHeight)]
        }
        return [.large]
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
}
