import SwiftUI

/// Unified button component. All variants wrap native `Button` + iOS 26 system
/// styles (`.buttonStyle(.glass / .glassProminent / .plain)`). Per `CLAUDE.md`
/// Rule #3 (native-only) and Rule #19 (one canonical CTA primitive), feature
/// code never hand-rolls a glass button — it reaches for `UniButton`.
///
/// ### Hit-testing contract (added 2026-06-08)
///
/// **The bug:** taps near the edge of a Liquid Glass button didn't register —
/// only taps near the center worked.
///
/// **The cause:** SwiftUI's `Button` hit-tests its **content's** intrinsic
/// frame, not the layout-modifier frame. A `.buttonStyle(.glass)` paints a
/// capsule around the label, sized to whatever the surrounding frame asks
/// for (e.g., `.frame(maxWidth: .infinity, height: 47)`). The painted glass
/// extends to the layout frame — the **tap region does not**. Taps inside
/// the visible capsule but outside the label's intrinsic bounds fall
/// through. (Juniperphoton, 2025: *"only the ellipsis symbol of this button
/// label can be clicked … even while the glass effect is interacting with
/// highlighting effects when tapping the white area of the circle."*)
///
/// **The fix:** `.contentShape(<the same shape the glass paints>)` on the
/// label expands the tap region to match the visible glass. Apple's own
/// `.glassEffect(_:in:)` API takes an `in: Shape` parameter for exactly this
/// reason — to align the painted material's shape with the surface's
/// interactive area. For `.buttonStyle(.glass)` / `.glassProminent`, the
/// default shape is `Capsule()`; for our circular `.actionCircle` variant
/// it's `Circle()`. Every glass variant below applies the matching
/// `.contentShape` inside the label builder.
///
/// ### Haptics
///
/// Per `CLAUDE.md` Rule #10 §E, each variant fires a default semantic
/// haptic on tap — no caller responsibility:
///
/// | Variant         | Haptic                          |
/// |-----------------|---------------------------------|
/// | `.primary`      | `.contextualImpact(.commit)`    |
/// | `.secondary`    | `.selection`                    |
/// | `.destructive`  | `.warning`                      |
/// | `.tertiary`     | none                            |
/// | `.toolbarPill`  | `.selection`                    |
/// | `.walletPill`   | `.selection`                    |
/// | `.actionCircle` | `.contextualImpact(.commit)`    |
///
/// The haptic is fired declaratively via `.uniHaptic(_:trigger:)`, which
/// honors the user's `@AppStorage("hapticFeedbackEnabled")` preference and
/// the system-level "System Haptics" + "Reduce Motion" settings.
struct UniButton: View {
    enum Variant {
        /// High-emphasis primary action. Liquid Glass prominent + accent tint.
        /// 47pt height, `maxWidth: .infinity`. Capsule hit-shape.
        case primary
        /// Standard alternative action. Liquid Glass with neutral tint.
        /// 47pt height, `maxWidth: .infinity`. Capsule hit-shape.
        case secondary
        /// Dangerous action (delete, remove, sign out). Glass prominent + red.
        /// 47pt height, `maxWidth: .infinity`. Capsule hit-shape.
        case destructive
        /// Inline text button (links, "Skip", "Sign in"). No glass surface.
        /// Intrinsic-size content; relies on label's own hit-test.
        case tertiary
        /// Nav-bar slot pill — text + trailing chevron, glass capsule.
        /// Sized by the toolbar (no explicit height); matches the toolbar's
        /// auto-glass icon envelope via `.controlSize(.large)` per the
        /// 2026-06-07 WalletHomeView audit. Capsule hit-shape.
        case toolbarPill
        /// Wallet-home toolbar identity pill — leading `WalletAvatar` +
        /// wallet name + trailing chevron, all inside a glass capsule.
        /// Same vertical envelope and glass register as `.toolbarPill`;
        /// only the leading slot differs. Drives the
        /// `WalletSwitcherSheet` open on tap. The avatar's symbol +
        /// colorHex are passed via `walletSymbol:` / `walletColorHex:`
        /// on the initializer; if either is `nil` the pill collapses to
        /// the `.toolbarPill` layout (text-only). 2026-06-09 addition.
        case walletPill
        /// Wallet-home action triplet (Send / Receive / Swap). Circular
        /// 56×56 glass-prominent surface, accent-tinted. Pairs with an
        /// external label rendered beneath by the call site. Circle
        /// hit-shape.
        case actionCircle

        /// Default haptic fired on tap. `nil` means silent (`.tertiary`).
        fileprivate var defaultHaptic: UniHaptic? {
            switch self {
            case .primary:       return .contextualImpact(.commit)
            case .secondary:     return .selection
            case .destructive:   return .warning
            case .tertiary:      return nil
            case .toolbarPill:   return .selection
            case .walletPill:    return .selection
            case .actionCircle:  return .contextualImpact(.commit)
            }
        }
    }

    /// The label slot. Either:
    /// - `.localized(LocalizedStringKey)` — auto-localizes through the
    ///   String Catalog (Rule #9). The default path for any literal
    ///   button label.
    /// - `.verbatim(String)` — renders the string as-is, used for runtime
    ///   values that aren't catalog keys (a user-chosen wallet name, a
    ///   formatted balance, a chain display name). The wallet-switcher
    ///   pill uses this path because the active wallet's name is
    ///   user-supplied.
    fileprivate enum LabelSource {
        case localized(LocalizedStringKey)
        case verbatim(String)
    }

    fileprivate let labelSource: LabelSource
    let variant: Variant
    /// SF Symbol shown before the title (`.primary` / `.secondary` /
    /// `.destructive` / `.tertiary` only). For `.actionCircle`, see `icon:`
    /// instead — that variant doesn't render a title.
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    /// Optional glass tint override (the `.glass` / `.glassProminent` FILL
    /// colour) for the `.primary` / `.secondary` / `.destructive` variants.
    /// `nil` keeps the variant's default tint. Lets a caller keep the unified
    /// Liquid Glass material while carrying a bespoke accent — e.g. the Reset
    /// flow's exact destructive red (`UniColors.Reset.danger`) on a glass
    /// `.destructive` button instead of the brighter system red.
    var tint: Color? = nil
    /// SF Symbol for `.actionCircle`'s glyph. Ignored by other variants
    /// today; kept on the public surface so future toolbar / action-class
    /// variants can adopt it without an API break.
    var icon: String? = nil
    /// LEGACY wallet identity (`.walletPill` only). The pre-2026-06-09
    /// flat-circle avatar took an SF Symbol + hex color tuple. The
    /// 2026-06-09 redesign passes a `WalletAvatarSpec` via the new
    /// `walletSpec:` parameter — keep these two for source
    /// compatibility until every call site migrates.
    var walletSymbol: String? = nil
    var walletColorHex: String? = nil
    /// 2026-06-09 wallet-identity spec — gradient + glyph or monogram
    /// + derived badge. When set, the `.walletPill` label renders the
    /// new gradient-disc `WalletAvatar`. Takes precedence over
    /// `walletSymbol` / `walletColorHex` when both are provided.
    var walletSpec: WalletAvatarSpec? = nil
    /// 2026-06-09 v3 — wallet UUID, threaded into the `.walletPill`'s
    /// inner `WalletAvatar` so the `.custom` SVG branch can resolve
    /// the cached PNG. Nil for `.toolbarPill` (no avatar) and for
    /// cold-launch frames where no active wallet exists yet.
    var walletId: UUID? = nil
    let action: () -> Void

    /// Trigger counter for the variant's default haptic. Incremented inside
    /// the action wrapper; the `.uniHaptic(...)` modifier observes the
    /// change and fires the native feedback (if the user has haptics on).
    @State private var tapCount: Int = 0

    // MARK: - Initializers

    /// Build a button with a localized title (default path — literals are
    /// auto-extracted by Xcode into `Localizable.xcstrings`).
    init(
        title: LocalizedStringKey,
        variant: Variant,
        systemImage: String? = nil,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        tint: Color? = nil,
        icon: String? = nil,
        action: @escaping () -> Void
    ) {
        self.labelSource = .localized(title)
        self.variant = variant
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.tint = tint
        self.icon = icon
        self.action = action
    }

    /// Build a button with a verbatim title (runtime values — wallet
    /// names, formatted balances, chain display names). Bypasses the
    /// String Catalog, which is correct for user-supplied or already-
    /// translated content.
    init(
        verbatim title: String,
        variant: Variant,
        systemImage: String? = nil,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        tint: Color? = nil,
        icon: String? = nil,
        walletSymbol: String? = nil,
        walletColorHex: String? = nil,
        walletSpec: WalletAvatarSpec? = nil,
        walletId: UUID? = nil,
        action: @escaping () -> Void
    ) {
        self.labelSource = .verbatim(title)
        self.variant = variant
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.tint = tint
        self.icon = icon
        self.walletSymbol = walletSymbol
        self.walletColorHex = walletColorHex
        self.walletSpec = walletSpec
        self.walletId = walletId
        self.action = action
    }

    // MARK: - Body

    var body: some View {
        buttonBody
            .modifier(HapticBinding(variant: variant, trigger: tapCount))
    }

    /// The effective interactive state. A loading button IS disabled
    /// (taps suppressed), so it shares the disabled visual register.
    private var isActive: Bool { isEnabled && !isLoading }

    @ViewBuilder
    private var buttonBody: some View {
        Button {
            tapCount &+= 1
            action()
        } label: {
            label
        }
        .modifier(VariantStyle(variant: variant, isActive: isActive, tintOverride: tint))
        .disabled(!isEnabled || isLoading)
    }

    /// Single source of truth for rendering the label string — picks
    /// `Text(LocalizedStringKey)` or `Text(verbatim:)` based on
    /// `labelSource`.
    @ViewBuilder
    private var titleText: some View {
        switch labelSource {
        case .localized(let key):
            Text(key)
        case .verbatim(let string):
            Text(verbatim: string)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch variant {
        case .primary, .secondary, .destructive:
            standardLabel
        case .tertiary:
            tertiaryLabel
        case .toolbarPill:
            toolbarPillLabel
        case .walletPill:
            walletPillLabel
        case .actionCircle:
            actionCircleLabel
        }
    }

    /// Label for the three "row of text + optional leading SF Symbol"
    /// variants. 47pt-tall, full-bleed width. `.contentShape(Capsule())`
    /// expands the tap region to match the painted glass.
    ///
    /// When `isLoading`, the leading glyph is replaced by a native
    /// `ProgressView`. The spinner is **explicitly tinted** to the
    /// variant's resolved LABEL color (`spinnerTint`) — never left to
    /// inherit the button's `.tint(...)`, which is the glass FILL color.
    /// On a `.glassProminent` CTA (dark/Ink fill) an untinted spinner
    /// inherits the dark fill tint and renders invisibly against it
    /// (the 2026-06-15 "Send shows no loading" bug). The spinner + the
    /// title text (e.g. "Sending…") read together as the working state.
    @ViewBuilder
    private var standardLabel: some View {
        HStack(spacing: UniSpacing.xs) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(spinnerTint)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
            }
            titleText
                .font(UniTypography.buttonLabel)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 47)
        .contentShape(Capsule())
    }

    /// The color the variant's spinner (and label) reads as. Resolves to
    /// the SAME role the title text uses, so the `ProgressView` is always
    /// visible on the variant's surface — white-on-Ink for the prominent
    /// CTAs, `.label` on the glass variants, accent for the inline link.
    /// Rule #4 — every value is a `UniColors` role, never a literal.
    private var spinnerTint: Color {
        switch variant {
        case .primary, .actionCircle:
            // `.glassProminent` accent fill → label opposes the fill.
            return UniColors.Button.primaryLabel
        case .destructive:
            // `.glassProminent` red fill → white label.
            return UniColors.Button.destructiveLabel
        case .secondary, .toolbarPill, .walletPill:
            // `.glass` neutral fill → `.label`-tone label.
            return UniColors.Button.secondaryLabel
        case .tertiary:
            // `.plain` inline link → accent.
            return UniColors.Button.tertiaryLabel
        }
    }

    @ViewBuilder
    private var tertiaryLabel: some View {
        HStack(spacing: UniSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            titleText
                .font(UniTypography.buttonLabel)
        }
        // No `.contentShape` — `.plain` style hit-tests the text itself,
        // which is correct for an inline link.
    }

    /// Nav-bar pill: text + trailing chevron, glass capsule. Sized by the
    /// toolbar's `.controlSize(.large)` envelope so the pill height
    /// matches the auto-glass icons sitting next to it (this is the
    /// invariant the 2026-06-07 WalletHomeView audit established).
    @ViewBuilder
    private var toolbarPillLabel: some View {
        HStack(spacing: UniSpacing.xxs) {
            titleText
                .font(UniTypography.bodyEmphasized)
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
        }
        .contentShape(Capsule())
    }

    /// Wallet-home toolbar identity pill (`.walletPill`). Same glass
    /// envelope as `.toolbarPill` (so the pill height tracks the
    /// toolbar's auto-glass icon envelope via `.controlSize(.large)`),
    /// but the leading slot carries a `WalletAvatar` instead of being
    /// empty. The pill's order: `[avatar] [wallet name] [chevron]`.
    ///
    /// When `walletSymbol` or `walletColorHex` is `nil` the label
    /// renders the text-only `.toolbarPill` layout, so a caller that
    /// hasn't yet wired the avatar (or that's gated on test mode)
    /// still gets a working pill.
    @ViewBuilder
    private var walletPillLabel: some View {
        HStack(spacing: UniSpacing.xs) {
            // 2026-06-09 — prefer the new gradient-disc spec when the
            // caller supplied one; fall back to the legacy SF Symbol
            // + hex tuple for sources that haven't migrated yet.
            if let walletSpec {
                WalletAvatar(spec: walletSpec, size: .toolbarPill, walletId: walletId)
            } else if let walletSymbol, let walletColorHex {
                WalletAvatar(
                    symbol: walletSymbol,
                    colorHex: walletColorHex,
                    size: .toolbarPill
                )
            }
            titleText
                .font(UniTypography.bodyEmphasized)
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
        }
        .contentShape(Capsule())
    }

    /// Wallet-home action circle (Send/Receive/Swap). 56×56 SF Symbol
    /// inside a glass-prominent circle. The external `Text` label beneath
    /// is rendered by the call site, not by `UniButton`. When `isLoading`,
    /// the glyph is replaced by a `spinnerTint`-tinted `ProgressView` so
    /// the working state reads on the dark prominent fill.
    @ViewBuilder
    private var actionCircleLabel: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(spinnerTint)
            } else {
                Image(systemName: icon ?? "questionmark")
                    .font(.system(size: 22, weight: .semibold))
            }
        }
        .frame(width: 56, height: 56)
        .contentShape(Circle())
    }

    /// Resolves the variant's glass tint + label tone. When the button is
    /// inactive (disabled or loading) it swaps in the disabled ROLES
    /// (Rule #4 — never a raw opacity literal): `disabledProminentFill`
    /// for `.glassProminent` variants, `disabledFill` for `.glass`
    /// variants, paired with the `disabledLabel` tone so the text / glyph
    /// reads as inert. The ACTIVE path is left byte-identical to the
    /// pre-token implementation — the glass styles supply their own
    /// automatic contrasting label color when active, so no
    /// `.foregroundStyle` is imposed on the active glass variants.
    private struct VariantStyle: ViewModifier {
        let variant: Variant
        let isActive: Bool
        /// Optional FILL tint override for the glass variants (nil = default).
        var tintOverride: Color? = nil

        @ViewBuilder
        func body(content: Content) -> some View {
            switch variant {
            case .primary:
                applyGlassProminent(content, activeTint: tintOverride ?? UniColors.Button.primaryTint)
            case .secondary:
                applyGlass(content, activeTint: tintOverride ?? UniColors.Button.secondaryTint)
            case .destructive:
                applyGlassProminent(content, activeTint: tintOverride ?? UniColors.Button.destructiveTint)
            case .tertiary:
                content
                    .buttonStyle(.plain)
                    .foregroundStyle(isActive ? UniColors.Button.tertiaryLabel : UniColors.Button.disabledLabel)
            case .toolbarPill:
                // `.controlSize(.large)` lifts the pill's capsule into the
                // same vertical envelope as the toolbar's auto-glass icon
                // backgrounds — the WWDC25 "Glassifying toolbars in
                // SwiftUI" guidance.
                applyGlass(content, activeTint: UniColors.Button.secondaryTint)
                    .controlSize(.large)
            case .walletPill:
                // Same glass envelope as `.toolbarPill` — the only
                // difference is the leading avatar in the label.
                applyGlass(content, activeTint: UniColors.Button.secondaryTint)
                    .controlSize(.large)
            case .actionCircle:
                applyGlassProminent(content, activeTint: UniColors.Button.primaryTint)
            }
        }

        /// `.glassProminent` variants. Active: original tint, system label.
        /// Inactive: prominent disabled fill + disabled label tone.
        @ViewBuilder
        private func applyGlassProminent(_ content: Content, activeTint: Color) -> some View {
            if isActive {
                content
                    .buttonStyle(.glassProminent)
                    .tint(activeTint)
            } else {
                content
                    .buttonStyle(.glassProminent)
                    .tint(UniColors.Button.disabledProminentFill)
                    .foregroundStyle(UniColors.Button.disabledLabel)
            }
        }

        /// `.glass` variants. Active: original tint, system label.
        /// Inactive: neutral disabled fill + disabled label tone.
        @ViewBuilder
        private func applyGlass(_ content: Content, activeTint: Color) -> some View {
            if isActive {
                content
                    .buttonStyle(.glass)
                    .tint(activeTint)
            } else {
                content
                    .buttonStyle(.glass)
                    .tint(UniColors.Button.disabledFill)
                    .foregroundStyle(UniColors.Button.disabledLabel)
            }
        }
    }

    /// Attaches the variant's default haptic to the button. `.tertiary`
    /// is silent — we skip the modifier rather than wire a no-op.
    private struct HapticBinding: ViewModifier {
        let variant: Variant
        let trigger: Int

        @ViewBuilder
        func body(content: Content) -> some View {
            if let haptic = variant.defaultHaptic {
                content.uniHaptic(haptic, trigger: trigger)
            } else {
                content
            }
        }
    }
}
