import SwiftUI

/// **The single canonical sheet shell** for every modal sheet in
/// UniApp. Replaces the prior per-sheet
/// `NavigationStack { ScrollView { VStack { … } } }` pattern with one
/// reusable VStack-rooted template that the `.intrinsicHeightSheet()`
/// modifier can measure correctly.
///
/// **Why this exists (the bug it fixes).**
///
/// SwiftUI's `NavigationStack` is a "fill the container" layout — it
/// has no defined intrinsic vertical size. When the
/// `.intrinsicHeightSheet()` modifier's measurement layer applies
/// `.fixedSize(horizontal: false, vertical: true)` to a sheet body
/// rooted in `NavigationStack`, the stack collapses to zero. The
/// measurement returns 0, the modifier's reducer rejects 0, the
/// detent falls back to `.medium`, and the visible sheet renders at
/// `.medium` regardless of content. That's what the
/// 2026-06-05 screenshot showed: a sheet larger than its content,
/// with the lower rows of content hidden below the action region.
///
/// **The fix.** Replace `NavigationStack` with a bare VStack. VStack
/// HAS a defined intrinsic vertical size (the sum of its children's
/// intrinsic vertical sizes). With `.fixedSize` applied through the
/// modifier's hidden measurement layer, the VStack reports its
/// natural rendered height, the detent matches, and the sheet sizes
/// to its content exactly.
///
/// **Apple-native conventions preserved.**
/// - System drag indicator (set by `.intrinsicHeightSheet()`).
/// - System sheet chrome (rounded top corners, dim background).
/// - System safe-area insets at the bottom (the modifier and the
///   shell don't fight iOS's keyboard / home-indicator handling).
///
/// **What is lost (and accepted).**
/// - `NavigationStack`'s title compression on scroll. Sheets in the
///   app don't scroll — they're content-sized. Title compression is
///   irrelevant when there's nothing to scroll. Rule #15's pattern
///   was the right answer for nav-style sheets; this shell is the
///   right answer for the warning / disclosure / confirmation sheets
///   that dominate the app.
/// - The system back chevron on pushed sub-screens. Sheets don't
///   push; if a future sub-screen is needed, present a second sheet
///   on top, or restructure to a multi-step state machine inside the
///   shell (like `PinSetupFlow` does).
///
/// **Usage.**
///
/// ```swift
/// UniSheet(title: "Skip backup?") {
///     // body content
///     hero
///     UniHeadline(text: "Save your recovery phrase before you skip.")
///     UniBody(text: "…", color: UniColors.Text.secondary)
/// } actions: {
///     // action region — typically a GlassEffectContainer of UniButtons
///     GlassEffectContainer(spacing: UniSpacing.s) {
///         VStack(spacing: UniSpacing.s) {
///             UniButton(title: "Back up now", variant: .primary) { … }
///             UniButton(title: "Skip anyway", variant: .secondary) { … }
///         }
///     }
/// }
/// ```
///
/// Then at the call site:
/// ```swift
/// .sheet(isPresented: $isShowing) {
///     SomeSheet()
///         .uniAppEnvironment()
///         .intrinsicHeightSheet()
///         .presentationBackground(UniColors.Background.primary)
/// }
/// ```
struct UniSheet<BodyContent: View, Actions: View>: View {
    let title: LocalizedStringKey
    /// Optional back-navigation closure. When non-nil, the title row
    /// renders a leading `chevron.backward` button that calls this
    /// closure. Used by multi-step sheets like Settings to navigate
    /// between root and sub-pickers without a NavigationStack.
    let onBack: (() -> Void)?
    @ViewBuilder let bodyContent: () -> BodyContent
    @ViewBuilder let actions: () -> Actions

    init(
        title: LocalizedStringKey,
        onBack: (() -> Void)? = nil,
        @ViewBuilder bodyContent: @escaping () -> BodyContent,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.onBack = onBack
        self.bodyContent = bodyContent
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.l) {
            titleRow
            // Body content lives inside a ScrollView with
            // `.scrollBounceBehavior(.basedOnSize)` — Apple's
            // "scroll only when content exceeds the frame"
            // primitive (iOS 16.4+, documented at
            // developer.apple.com/documentation/swiftui/view/scrollbouncebehavior).
            //
            // On large iPhones where the sheet is sized to its
            // content (the `[.height(intrinsic)]` detent), the
            // ScrollView's frame matches its content's intrinsic
            // height — `.basedOnSize` then makes the ScrollView
            // act as a transparent container (no scrolling, no
            // bouncing, no indicator). The visual register is
            // identical to the prior `VStack`-only design.
            //
            // On small iPhones where the modifier falls back to
            // `.large` because the content overflows, the
            // ScrollView's frame is smaller than its content and
            // the user scrolls naturally. Title (above) and
            // actions (below) stay pinned in view — they aren't
            // inside the ScrollView, only the body is.
            //
            // 2026-06-07 bug fix: the previous body had no
            // ScrollView and the modifier applied
            // `.fixedSize(vertical: true)` to the visible content
            // to drive intrinsic measurement. On small iPhones
            // the fixedSize made content overflow past the
            // sheet's bottom safe-area inset, pushing the action
            // button into the home-indicator zone (user-reported
            // OpenSourceSheet screenshot). Moving the fixedSize
            // measurement to the hidden `intrinsicProbe` below
            // restores safe-area handling for the visible layer.
            ScrollView {
                bodyContent()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            actions()
                .frame(maxWidth: .infinity)
        }
        // Horizontal padding at `UniSpacing.m` (16pt). 2026-06-07
        // tightened from `UniSpacing.l` (24pt) after the user reported
        // a system `Toggle` switch having its right pill clipped on
        // small iPhones (CreateWalletDisclosureSheet screenshot,
        // /var/.../simulator_screenshot_…) — at 24pt each side the
        // content area was 345pt on iPhone 17 (393pt screen), and the
        // 16pt internal `UniCard` padding plus a trailing `Toggle`
        // could push the knob into the right edge. 16pt each side is
        // also Apple's standard sheet content margin (Mail compose,
        // Settings, share sheet), so the new value aligns with native
        // patterns. Tokens-only per Rule #4 — no raw numbers.
        .padding(.horizontal, UniSpacing.m)
        // Top padding gives room below the drag indicator. The system
        // sheet container already places content below the indicator;
        // this is breathing room.
        .padding(.top, UniSpacing.l)
        // Bottom padding keeps action region clear of the home
        // indicator on devices with one. Inside a `.sheet`, the
        // bottom safe-area inset is handled by the system; this is
        // for visual comfort.
        .padding(.bottom, UniSpacing.l)
        // Hidden intrinsic-height probe. Renders the same content
        // (title + body + actions + paddings) with
        // `.fixedSize(vertical: true)` so a `GeometryReader` can
        // capture its natural intrinsic height. The measurement is
        // emitted via `UniSheetIntrinsicHeightKey`, which the
        // `intrinsicHeightSheet()` modifier reads to decide the
        // presentation detent.
        //
        // Why a hidden duplicate instead of measuring the visible
        // content: applying `.fixedSize(vertical: true)` to the
        // visible content opts it out of parent constraints —
        // including the sheet's bottom safe-area inset — which is
        // exactly what caused the 2026-06-07 bug. By measuring on
        // a hidden layer only, the visible content flows naturally
        // and respects safe areas, while the modifier still gets
        // an accurate intrinsic height for detent selection.
        //
        // Cost: one extra layout pass per sheet appearance. For
        // the static declarative content that dominates this
        // codebase (UniText / UniCard / UniButton compositions),
        // negligible. For sheets with stateful inputs (e.g.
        // PassphraseSheet's TextEditor), the hidden duplicate has
        // its own state that is never seen — also fine.
        .background(intrinsicProbe)
    }

    /// Hidden measurement layer — see body's `.background(intrinsicProbe)`
    /// comment for the rationale. Re-renders the same VStack with
    /// `.fixedSize(vertical: true)` so the `GeometryReader` behind it
    /// reports the content's intrinsic vertical height. Emitted via
    /// `UniSheetIntrinsicHeightKey` for `intrinsicHeightSheet()` to
    /// consume.
    private var intrinsicProbe: some View {
        VStack(alignment: .leading, spacing: UniSpacing.l) {
            titleRow
            bodyContent()
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
                .frame(maxWidth: .infinity)
        }
        // Match the visible layer's tightened horizontal padding
        // so the intrinsic measurement reflects the actual layout.
        // 2026-06-07: 24 → 16 (UniSpacing.l → UniSpacing.m).
        .padding(.horizontal, UniSpacing.m)
        .padding(.top, UniSpacing.l)
        .padding(.bottom, UniSpacing.l)
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: UniSheetIntrinsicHeightKey.self,
                        value: proxy.size.height
                    )
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: UniSpacing.s) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(UniColors.Text.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back"))
            }
            Text(title)
                // Matches `.navigationTitle("…").displayMode(.large)`
                // visual weight without the NavigationStack chrome.
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.leading)
                // Critical: lets the title wrap onto multiple lines
                // in locales where the translation is longer than
                // English (Arabic, German, Russian) instead of
                // truncating with `…`.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
