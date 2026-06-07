import SwiftUI
import UIKit

/// Single source of truth for every color used in UniApp.
///
/// All values map to iOS 26 system semantic colors so they adapt automatically
/// between light mode (default) and dark mode, respect Increase Contrast,
/// Smart Invert, and Dynamic Range.
///
/// Per `CLAUDE.md` Rule #3: never use hex literals or hand-rolled colors in views —
/// always reference a role from this file.
enum UniColors {

    // MARK: - Background

    /// **iOS Settings register.** The whole app uses the iOS `…GroupedBackground`
    /// palette — the same palette Settings / Health / Wallet (Apple's) / Files
    /// use system-wide. The visual contract is:
    ///
    /// - **Page** is a subtly warm gray (light) / true black (dark) —
    ///   `systemGroupedBackground`.
    /// - **Cards / rows** are a step up to white (light) / `#1C1C1E` (dark) —
    ///   `secondarySystemGroupedBackground`.
    /// - **Nested cards** are a further step — `tertiarySystemGroupedBackground`.
    ///
    /// This was flipped on 2026-06-07 per direct user direction
    /// ("cards should be white and the background in the whole app should
    /// match the settings screen background in the iOS"). Previously the
    /// roles pointed at `systemBackground` / `secondarySystemBackground`,
    /// which produced *white* page + *gray* cards — exactly the inverse of
    /// the iOS norm. The fix lives at the token level so every screen
    /// re-skins for free (Rule #4 — no feature file edits).
    enum Background {
        /// Primary screen background — the page color on every screen.
        /// Resolves to the iOS Settings page (warm gray in light, true
        /// black in dark). Use as the outermost `ZStack` / `List`
        /// `.background(…)` fill on every screen, sheet, and presentation
        /// surface root.
        static let primary = Color(uiColor: .systemGroupedBackground)
        /// One step up from the page — the canonical "card / row" fill
        /// (white in light, `#1C1C1E` in dark). Use as the `listRowBackground`
        /// on grouped lists and as the fill on card / chip surfaces.
        static let secondary = Color(uiColor: .secondarySystemGroupedBackground)
        /// Two steps up — nested cards / chips inside a card. Use sparingly;
        /// most surfaces only need primary + secondary.
        static let tertiary = Color(uiColor: .tertiarySystemGroupedBackground)

        /// Alias retained for source compatibility. Identical to `primary`
        /// after the 2026-06-07 iOS-Settings-register flip — they
        /// previously named distinct grouped vs. plain palettes; the
        /// whole app now uses the grouped palette, so the alias is a
        /// pointer to the canonical name. Prefer `Background.primary`
        /// in new code.
        static let groupedPrimary = Self.primary
        /// Alias retained for source compatibility. Identical to
        /// `secondary` after the 2026-06-07 flip. Prefer
        /// `Background.secondary` in new code.
        static let groupedSecondary = Self.secondary
        /// Alias retained for source compatibility. Identical to
        /// `tertiary` after the 2026-06-07 flip. Prefer
        /// `Background.tertiary` in new code.
        static let groupedTertiary = Self.tertiary
    }

    // MARK: - Text

    enum Text {
        /// Primary content (titles, primary body copy).
        static let primary = Color(uiColor: .label)
        /// Secondary content (subtitles, descriptions, captions).
        static let secondary = Color(uiColor: .secondaryLabel)
        /// Tertiary content (metadata, timestamps, helper text).
        static let tertiary = Color(uiColor: .tertiaryLabel)
        /// Quaternary content (very low emphasis).
        static let quaternary = Color(uiColor: .quaternaryLabel)
        /// Placeholder text inside input fields.
        static let placeholder = Color(uiColor: .placeholderText)
        /// Text drawn on top of a tinted/accent surface (e.g., primary CTA label).
        static let onTint = Color.white
        /// Text inverted against the system background (rare — splash, marketing surfaces).
        static let inverted = Color(uiColor: .systemBackground)
        /// Link / actionable inline text.
        static let link = Color.accentColor

        // Status text variants
        static let success = Color(uiColor: .systemGreen)
        static let warning = Color(uiColor: .systemOrange)
        static let error = Color(uiColor: .systemRed)
        static let info = Color(uiColor: .systemBlue)
    }

    // MARK: - Icon

    enum Icon {
        static let primary = Color(uiColor: .label)
        static let secondary = Color(uiColor: .secondaryLabel)
        static let tertiary = Color(uiColor: .tertiaryLabel)
        static let quaternary = Color(uiColor: .quaternaryLabel)
        static let accent = Color.accentColor
        static let onTint = Color.white

        // Status icon variants
        static let success = Color(uiColor: .systemGreen)
        static let warning = Color(uiColor: .systemOrange)
        static let error = Color(uiColor: .systemRed)
        static let info = Color(uiColor: .systemBlue)
    }

    // MARK: - Fill

    /// Use for non-glass filled controls (e.g., toggle backgrounds, tag chips).
    enum Fill {
        static let primary = Color(uiColor: .systemFill)
        static let secondary = Color(uiColor: .secondarySystemFill)
        static let tertiary = Color(uiColor: .tertiarySystemFill)
        static let quaternary = Color(uiColor: .quaternarySystemFill)
    }

    // MARK: - Separator & Stroke

    enum Separator {
        /// Hairline separator between rows (translucent over content).
        static let regular = Color(uiColor: .separator)
        /// Opaque separator (use only when content cannot show through).
        static let opaque = Color(uiColor: .opaqueSeparator)
    }

    enum Stroke {
        /// Subtle border on cards and surfaces.
        static let regular = Color(uiColor: .separator)
        /// Opaque border (rare).
        static let opaque = Color(uiColor: .opaqueSeparator)
    }

    // MARK: - Tint (system palette — accents and brand)

    enum Tint {
        static let accent = Color.accentColor // app accent (set in Assets.xcassets)
        static let red = Color(uiColor: .systemRed)
        static let orange = Color(uiColor: .systemOrange)
        static let yellow = Color(uiColor: .systemYellow)
        static let green = Color(uiColor: .systemGreen)
        static let mint = Color(uiColor: .systemMint)
        static let teal = Color(uiColor: .systemTeal)
        static let cyan = Color(uiColor: .systemCyan)
        static let blue = Color(uiColor: .systemBlue)
        static let indigo = Color(uiColor: .systemIndigo)
        static let purple = Color(uiColor: .systemPurple)
        static let pink = Color(uiColor: .systemPink)
        static let brown = Color(uiColor: .systemBrown)
        static let gray = Color(uiColor: .systemGray)
    }

    // MARK: - Button

    enum Button {
        /// Primary CTA (`UniButton.primary` → `.glassProminent`).
        static let primaryLabel = Color.white
        static let primaryTint = Color.accentColor

        /// Secondary CTA (`UniButton.secondary` → `.glass`).
        static let secondaryLabel = Color(uiColor: .label)
        static let secondaryTint = Color(uiColor: .label)

        /// Destructive CTA (delete, remove, sign-out).
        static let destructiveLabel = Color.white
        static let destructiveTint = Color(uiColor: .systemRed)

        /// Tertiary / inline text button.
        static let tertiaryLabel = Color.accentColor

        /// Disabled state (any variant).
        static let disabledLabel = Color(uiColor: .tertiaryLabel)
        static let disabledTint = Color(uiColor: .quaternarySystemFill)
    }

    // MARK: - Status (success, warning, error, info, neutral)

    /// Use for badges, banners, and inline messages.
    enum Status {
        // Success
        static let successBackground = Color(uiColor: .systemGreen).opacity(0.15)
        static let successForeground = Color(uiColor: .systemGreen)
        static let successStroke = Color(uiColor: .systemGreen).opacity(0.30)

        // Warning
        static let warningBackground = Color(uiColor: .systemOrange).opacity(0.15)
        static let warningForeground = Color(uiColor: .systemOrange)
        static let warningStroke = Color(uiColor: .systemOrange).opacity(0.30)

        // Error
        static let errorBackground = Color(uiColor: .systemRed).opacity(0.15)
        static let errorForeground = Color(uiColor: .systemRed)
        static let errorStroke = Color(uiColor: .systemRed).opacity(0.30)

        // Info
        static let infoBackground = Color(uiColor: .systemBlue).opacity(0.15)
        static let infoForeground = Color(uiColor: .systemBlue)
        static let infoStroke = Color(uiColor: .systemBlue).opacity(0.30)

        // Neutral
        static let neutralBackground = Color(uiColor: .systemGray5)
        static let neutralForeground = Color(uiColor: .label)
        static let neutralStroke = Color(uiColor: .separator)
    }

    /// Per-word validation feedback on the mnemonic editor surface.
    /// Status (success/warning/error) reads as "operation finished
    /// with this outcome"; per-word Validation reads as "mid-input
    /// signal — this word is/is-not in the BIP-39 wordlist". Different
    /// semantic, different role (Rule #4 §C).
    enum Validation {
        /// Word is in the BIP-39 wordlist. Calm, slightly desaturated
        /// green so a phrase mid-correction doesn't read as alarming.
        static let valid = Color(uiColor: .systemGreen).opacity(0.92)
        /// Word committed (caret moved off it) and is not in the
        /// BIP-39 wordlist. Slightly desaturated red — restrained
        /// (Rule #16 §B).
        static let invalid = Color(uiColor: .systemRed).opacity(0.92)
        /// Word currently being typed — caret is inside it. Neutral
        /// primary color so the user reads what they're typing without
        /// color noise.
        static let pending = Color(uiColor: .label)
    }

    // MARK: - Crypto-specific (price/asset states)

    enum Crypto {
        /// Price up / gain / receive.
        static let up = Color(uiColor: .systemGreen)
        /// Price down / loss / send.
        static let down = Color(uiColor: .systemRed)
        /// Flat / stable / neutral movement.
        static let stable = Color(uiColor: .systemGray)
        /// Stablecoin badge.
        static let stablecoin = Color(uiColor: .systemBlue)
        /// Pending / in-flight transaction.
        static let pending = Color(uiColor: .systemOrange)
        /// Confirmed transaction.
        static let confirmed = Color(uiColor: .systemGreen)
        /// Failed transaction.
        static let failed = Color(uiColor: .systemRed)
    }

    // MARK: - Material (non-glass card surfaces)

    /// Card surfaces when Liquid Glass is not appropriate (e.g., dense list
    /// rows where chrome would clutter). Prefer `.glassEffect(...)` for
    /// interactive / chrome surfaces (Rule #3).
    ///
    /// Re-pointed 2026-06-07 to the grouped palette in lockstep with
    /// `Background.*` (see the `Background` doc comment for the why) — so
    /// every card surface across the app is now the iOS-canonical white
    /// (light) / `#1C1C1E` (dark) sitting on the grouped page color.
    enum Material {
        /// Canonical card fill — `secondarySystemGroupedBackground`.
        /// White in light, `#1C1C1E` in dark. Matches `Background.secondary`
        /// by design: a "card" is a card whether it's a `UniCard`'s
        /// `.fill(…)` or a `listRowBackground(…)`.
        static let card = Color(uiColor: .secondarySystemGroupedBackground)
        /// One step up — for cards inside cards (rare).
        static let elevated = Color(uiColor: .tertiarySystemGroupedBackground)
    }

    // MARK: - Focus / Highlight (system selection)

    enum Focus {
        /// System selection tint (rows, picker selections).
        static let selection = Color.accentColor.opacity(0.20)
        /// Pressed/hover overlay.
        static let pressed = Color(uiColor: .systemFill)
    }

    // MARK: - Skeleton / Loading shimmer

    enum Skeleton {
        static let base = Color(uiColor: .secondarySystemFill)
        static let highlight = Color(uiColor: .tertiarySystemFill)
    }

    // MARK: - Splash (radial-gradient brand surface)

    /// Splash-only color roles for the launch screen. Per the 2026-06-07
    /// design handoff (`design_handoff_splash_screen/README.md`) the
    /// splash is a monochrome surface with a soft radial lift at
    /// `(0.5, 0.38)` from `lift` → `base`. These are splash-only because
    /// the rest of the app uses system semantic backgrounds; the splash
    /// is a brand-controlled launch surface where the gradient is
    /// load-bearing.
    ///
    /// **Black variant:** `lift = #1A1C21`, `base = #000000`.
    /// **Light variant:** `lift = #FFFFFF`, `base = #EEF0F4`.
    enum Splash {
        /// Upper-center radial highlight stop.
        static let lift = Color("SplashLift", bundle: .main)
        /// Outer radial stop (falls off to this).
        static let base = Color("SplashBase", bundle: .main)
        /// Wordmark + mark tint (white in dark / Ink in light).
        static let mark = Color("SplashMark", bundle: .main)
        /// Halo behind the mark (white@.14 dark / ink@.08 light).
        static let glow = Color("SplashGlow", bundle: .main)
        /// Loader track (white@.16 dark / ink@.10 light).
        static let loaderTrack = Color("SplashLoaderTrack", bundle: .main)
        /// Tagline color (white@.5 dark / ink@.5 light).
        static let tagline = Color("SplashTagline", bundle: .main)
    }

    // MARK: - Brand (Aperture identity surfaces)

    /// Brand-identity colors specific to Aperture. Defined as Assets.xcassets
    /// color sets with both light + dark appearance entries so the brand mark
    /// reads correctly in both modes. Per the 2026-06-07 design handoff:
    /// *"Aperture's brand colour is **black** (white knockout in dark
    /// contexts). Keep this screen monochrome; do not introduce accent
    /// colours."* The Aperture Blue gradient in the brand kit applies only
    /// to the **app-icon tile** (the Home Screen mark) — it is NOT the
    /// app's accent color. Everywhere else the brand is monochrome.
    ///
    /// - **`UniColors.Brand.mark`** → `BrandMark.colorset` → **Ink**
    ///   `#0B0D11` light / **Cloud** `#F5F5F7` dark. Used by the iris
    ///   mark, wordmark, and any brand-identity surface.
    /// - **`UniColors.Tint.accent`** → `AccentColor.colorset` → **Ink**
    ///   `#0B0D11` light / **Cloud** `#F5F5F7` dark — identical to the
    ///   brand mark. Surfaced system-wide as `.accentColor`; consumed
    ///   by every `.tint(...)`, every system control (Toggle, Picker,
    ///   etc.), and every `UniButton(.primary)` background.
    enum Brand {
        /// Fill color for the Aperture iris mark — graphite in light mode,
        /// soft white in dark mode. Use for the splash iris and the
        /// onboarding welcome-slide hero.
        static let mark = Color("BrandMark")
    }

    // MARK: - Illustration (onboarding native scenes)

    /// Color roles for SwiftUI-native illustrations (onboarding heroes etc.).
    /// These are *not* icon colors — they fill rendered scenes built from
    /// shapes, gradients, and canvases. Every illustration must reference
    /// these roles, never literal colors.
    enum Illustration {
        /// The primary line/stroke color inside an illustration (e.g., phone
        /// outline, shield outline, arrow path). Adapts to light/dark via
        /// the system label color.
        static let primaryLine = Color(uiColor: .label)
        /// Secondary supporting line (orbit rings, hairlines, ticks).
        static let secondaryLine = Color(uiColor: .tertiaryLabel)
        /// Decorative tertiary line (background grid, faint marks).
        static let tertiaryLine = Color(uiColor: .quaternaryLabel)
        /// A soft surface inside an illustration (e.g., vault interior).
        static let surface = Color(uiColor: .secondarySystemFill)
        /// A deeper surface for inner nesting (e.g., vault inside phone).
        static let surfaceDeep = Color(uiColor: .tertiarySystemFill)
        /// The accent fill used for highlighted shapes in illustrations.
        static let accentFill = Color.accentColor
        /// A muted accent used when accent would dominate.
        static let accentMuted = Color.accentColor.opacity(0.30)
    }
}
