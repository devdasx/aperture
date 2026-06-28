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

    // MARK: - Page

    /// Top-level page/screen surfaces.
    enum Page {
        static let background = Color(uiColor: .systemGroupedBackground)
    }

    // MARK: - Card

    /// Canonical non-glass card surfaces. Kept separate from button tint
    /// roles because content containers and interactive controls need
    /// different contrast in dark mode.
    enum Card {
        /// Primary content-card/list-row fill.
        static let background = Color(uiColor: .secondarySystemGroupedBackground)
        /// Raised/nested card fill.
        static let elevated = Color(uiColor: .tertiarySystemGroupedBackground)
        /// Divider or hairline on a card when it needs an explicit stroke.
        static let stroke = Color(uiColor: .separator)
        /// Muted content drawn inside a card.
        static let secondaryText = Color(uiColor: .secondaryLabel)
    }

    // MARK: - List

    /// Native grouped-list colors. List rows are intentionally their own
    /// component namespace, even though their current fill matches `Card`.
    enum List {
        static let background = Page.background
        static let rowBackground = Card.background
        static let rowBackgroundElevated = Card.elevated
        static let separator = Color(uiColor: .separator)
        static let sectionHeader = Color(uiColor: .secondaryLabel)
    }

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
        static let primary = Page.background
        /// One step up from the page — the canonical "card / row" fill
        /// (white in light, `#1C1C1E` in dark). Use as the `listRowBackground`
        /// on grouped lists and as the fill on card / chip surfaces.
        static let secondary = Card.background
        /// Two steps up — nested cards / chips inside a card. Use sparingly;
        /// most surfaces only need primary + secondary.
        static let tertiary = Card.elevated

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
        /// Disabled / inactive label tone. Matches the UIControl disabled
        /// title color. Use for a label whose owning control is in a
        /// `.disabled` state — semantically distinct from `tertiary`
        /// (which is low-emphasis-but-active metadata).
        static let disabled = Color(uiColor: .tertiaryLabel)
        /// Quaternary content (very low emphasis).
        static let quaternary = Color(uiColor: .quaternaryLabel)
        /// Placeholder text inside input fields.
        static let placeholder = Color(uiColor: .placeholderText)
        /// Always-white text drawn over guaranteed-dark media (camera
        /// feed, photo scrims). **Not safe on the accent**: the app's
        /// accent is monochrome (Cloud `#F5F5F7` in dark mode), so
        /// white-on-accent is invisible there — for text on an
        /// accent-tinted surface use `Button.primaryLabel`, which
        /// adapts. Existing consumers (white over the camera feed) are
        /// correct with white and should migrate to the honestly-named
        /// `onMedia` below.
        static let onTint = Color.white
        /// Always-white text over media (camera feed, imagery) that is
        /// dark in both appearances. The properly-named home for the
        /// `onTint` consumers above.
        static let onMedia = Color.white
        /// Text inverted against the system background (rare — splash, marketing surfaces).
        static let inverted = Color(uiColor: .systemBackground)
        /// Link / actionable inline text. Apple-blue (2026-06-17) so every
        /// tappable-text affordance matches — see `UniColors.Button.text`.
        static let link = Color(uiColor: .systemBlue)

        // Status text variants
        static let success = Color(uiColor: .systemGreen)
        static let warning = Color(uiColor: .systemOrange)
        static let error = Color(uiColor: .systemRed)
        static let info = Color(uiColor: .systemBlue)
    }

    // MARK: - Copy

    /// Default colors for the reusable `UniText` components. These alias the
    /// semantic text colors today, but the component layer is independent so
    /// titles/body/captions can be retuned without changing raw text roles.
    enum Copy {
        static let largeTitle = Text.primary
        static let title = Text.primary
        static let headline = Text.primary
        static let body = Text.primary
        static let subtitle = Text.secondary
        static let callout = Text.secondary
        static let footnote = Text.tertiary
        static let caption = Text.tertiary
    }

    // MARK: - Navigation

    enum Navigation {
        static let title = Text.primary
        static let largeTitle = Text.primary
        static let icon = Icon.primary
        static let iconSecondary = Icon.secondary
    }

    // MARK: - Sheet

    enum Sheet {
        static let background = Page.background
        static let title = Text.primary
        static let body = Text.primary
        static let subtitle = Text.secondary
        static let backIcon = Icon.primary
    }

    // MARK: - Icon

    enum Icon {
        static let primary = Color(uiColor: .label)
        static let secondary = Color(uiColor: .secondaryLabel)
        static let tertiary = Color(uiColor: .tertiaryLabel)
        /// Disabled / inactive icon tone — same tone as `Text.disabled`.
        /// Use for a glyph whose owning control is `.disabled`, distinct
        /// from `tertiary` (low-emphasis-but-active).
        static let disabled = Color(uiColor: .tertiaryLabel)
        static let quaternary = Color(uiColor: .quaternaryLabel)
        static let accent = Color.accentColor
        /// Icon drawn on an accent-tinted surface. Adapts like
        /// `Button.primaryLabel` (white on Ink in light, black on
        /// Cloud in dark) — the monochrome accent makes literal
        /// white invisible in dark mode.
        static let onTint = Color(uiColor: .systemBackground)

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
        enum Primary {
            static let label = Color.white
            static let tint = Color(
                uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? .tertiarySystemGroupedBackground
                        : .label
                }
            )
            static let disabledTint = Color(uiColor: .tertiarySystemFill)
            static let disabledLabel = Color(uiColor: .tertiaryLabel)
        }

        enum Secondary {
            static let label = Color(uiColor: .label)
            static let tint = Primary.tint
            static let disabledTint = Color(uiColor: .quaternarySystemFill)
            static let disabledLabel = Color(uiColor: .tertiaryLabel)
        }

        enum Destructive {
            static let label = Color.white
            static let tint = Color(uiColor: .systemRed)
            static let disabledTint = Primary.disabledTint
            static let disabledLabel = Primary.disabledLabel
        }

        /// Inline primary text action, e.g. links and high-emphasis text
        /// buttons.
        enum TextAction {
            static let foreground = Color(uiColor: .systemBlue)
            static let disabled = Color(uiColor: .tertiaryLabel)
        }

        /// Inline secondary text action, e.g. quiet alternate text buttons.
        enum SecondaryTextAction {
            static let foreground = Color(uiColor: .secondaryLabel)
            static let disabled = Color(uiColor: .tertiaryLabel)
        }

        enum ToolbarPill {
            static let label = Secondary.label
            static let tint = Secondary.tint
            static let disabledTint = Secondary.disabledTint
            static let disabledLabel = Secondary.disabledLabel
        }

        enum WalletPill {
            static let label = Secondary.label
            static let tint = Secondary.tint
            static let disabledTint = Secondary.disabledTint
            static let disabledLabel = Secondary.disabledLabel
        }

        enum ActionCircle {
            static let label = Primary.label
            static let tint = Primary.tint
            static let disabledTint = Primary.disabledTint
            static let disabledLabel = Primary.disabledLabel
        }

        /// Primary CTA (`UniButton.primary` → `.glassProminent`).
        ///
        /// Button fill deliberately does NOT use `Color.accentColor`.
        /// Aperture's accent is the brand mark color: Ink in light mode,
        /// Cloud in dark mode. Cloud is perfect for marks, but terrible
        /// as a prominent button fill on a black screen because white
        /// glass + white glyphs disappear. Primary buttons are therefore
        /// filled controls: brand ink in light mode, a raised control
        /// surface in dark mode. The dark control surface is deliberately
        /// one step above `Card.background`, so buttons and cards never
        /// collapse into the same tone.
        static let primaryLabel = Primary.label
        static let controlSurface = Primary.tint
        static let primaryTint = Primary.tint

        /// Secondary CTA (`UniButton.secondary` → `.glass`).
        static let secondaryLabel = Secondary.label
        static let secondaryTint = Secondary.tint

        /// Destructive CTA (delete, remove, sign-out).
        static let destructiveLabel = Destructive.label
        static let destructiveTint = Destructive.tint

        /// **Text button (Apple register).** The single Apple-standard
        /// tappable-text color — iOS `systemBlue` (`#007AFF` light /
        /// `#0A84FF` dark, adapts automatically). Per direct user direction
        /// (2026-06-17): EVERY text button in the app reads in this blue —
        /// "Show all", "View all", inline links, `.tertiary` `UniButton`s,
        /// "Max" / "Paste" affordances, etc. This is the ONE place the app
        /// deliberately steps off the monochrome brand (see `Brand` below):
        /// a text button must read as tappable, and blue is the platform's
        /// universal "this is a link / action" signal. Filled CTAs
        /// (`.primary` / `.secondary` / `.destructive`) and system controls
        /// (Toggle, Picker) stay on the monochrome accent — ONLY plain text
        /// buttons go blue.
        static let text = TextAction.foreground
        static let secondaryText = SecondaryTextAction.foreground

        /// Tertiary / inline text button. Points at `Button.text` — the
        /// Apple-blue text-button color (2026-06-17).
        static let tertiaryLabel = TextAction.foreground

        /// Disabled state (any variant).
        static let disabledLabel = Primary.disabledLabel
        static let disabledTint = Color(uiColor: .quaternarySystemFill)
        /// Disabled fill for PROMINENT CTAs (`.primary` / `.destructive`
        /// / `.actionCircle` → `.glassProminent`). One step heavier than
        /// `disabledFill` so a disabled prominent button still reads as a
        /// solid (but inert) surface rather than a faint outline.
        static let disabledProminentFill = Primary.disabledTint
        /// Disabled fill for NEUTRAL / glass CTAs (`.secondary` /
        /// `.toolbarPill` / `.walletPill` → `.glass`). The lightest fill
        /// — the glass surface goes quiet when its action is unavailable.
        static let disabledFill = Secondary.disabledTint
    }

    // MARK: - Input

    enum Input {
        static let background = Card.background
        static let backgroundElevated = Card.elevated
        static let text = Text.primary
        static let placeholder = Text.placeholder
        static let icon = Icon.secondary
        static let revealIcon = Icon.secondary
        static let border = Color.clear
        static let focusedBorder = Color(uiColor: .separator)
        static let disabledBackground = Color(uiColor: .quaternarySystemFill)
        static let disabledText = Text.disabled
    }

    // MARK: - Toggle

    enum Toggle {
        static let tint = Tint.accent
        static let label = Text.primary
        static let secondaryLabel = Text.secondary
    }

    // MARK: - Feedback

    /// Operation-result colors. Component-specific surfaces like `Badge`
    /// should expose their own roles, but they can start from these common
    /// feedback hues.
    enum Feedback {
        enum Success {
            static let background = Color(uiColor: .systemGreen).opacity(0.15)
            static let foreground = Color(uiColor: .systemGreen)
            static let stroke = Color(uiColor: .systemGreen).opacity(0.30)
        }
        enum Warning {
            static let background = Color(uiColor: .systemOrange).opacity(0.15)
            static let foreground = Color(uiColor: .systemOrange)
            static let stroke = Color(uiColor: .systemOrange).opacity(0.30)
        }
        enum Error {
            static let background = Color(uiColor: .systemRed).opacity(0.15)
            static let foreground = Color(uiColor: .systemRed)
            static let stroke = Color(uiColor: .systemRed).opacity(0.30)
        }
        enum Info {
            static let background = Color(uiColor: .systemBlue).opacity(0.15)
            static let foreground = Color(uiColor: .systemBlue)
            static let stroke = Color(uiColor: .systemBlue).opacity(0.30)
        }
        enum Neutral {
            static let background = Color(uiColor: .systemGray5)
            static let foreground = Color(uiColor: .label)
            static let stroke = Color(uiColor: .separator)
        }
    }

    // MARK: - Badge

    enum Badge {
        enum Success {
            static let background = Feedback.Success.background
            static let foreground = Feedback.Success.foreground
            static let stroke = Feedback.Success.stroke
        }
        enum Warning {
            static let background = Feedback.Warning.background
            static let foreground = Feedback.Warning.foreground
            static let stroke = Feedback.Warning.stroke
        }
        enum Error {
            static let background = Feedback.Error.background
            static let foreground = Feedback.Error.foreground
            static let stroke = Feedback.Error.stroke
        }
        enum Info {
            static let background = Feedback.Info.background
            static let foreground = Feedback.Info.foreground
            static let stroke = Feedback.Info.stroke
        }
        enum Neutral {
            static let background = Feedback.Neutral.background
            static let foreground = Feedback.Neutral.foreground
            static let stroke = Feedback.Neutral.stroke
        }
    }

    // MARK: - Status (success, warning, error, info, neutral)

    /// Use for badges, banners, and inline messages.
    enum Status {
        // Success
        static let successBackground = Feedback.Success.background
        static let successForeground = Feedback.Success.foreground
        static let successStroke = Feedback.Success.stroke

        // Warning
        static let warningBackground = Feedback.Warning.background
        static let warningForeground = Feedback.Warning.foreground
        static let warningStroke = Feedback.Warning.stroke

        // Error
        static let errorBackground = Feedback.Error.background
        static let errorForeground = Feedback.Error.foreground
        static let errorStroke = Feedback.Error.stroke

        // Info
        static let infoBackground = Feedback.Info.background
        static let infoForeground = Feedback.Info.foreground
        static let infoStroke = Feedback.Info.stroke

        // Neutral
        static let neutralBackground = Feedback.Neutral.background
        static let neutralForeground = Feedback.Neutral.foreground
        static let neutralStroke = Feedback.Neutral.stroke
    }

    /// Import-success seal colours (design handoff). Two one-off brand
    /// hues that no other role carries: **secured** green for a
    /// key-holding import, **watching** blue for a watch-only import.
    /// Defined here because Rule #4 §B confines hex construction to this
    /// file; feature code reads these named roles. Scheme-parameterised
    /// (the caller passes its `colorScheme`) so each renders its
    /// light/dark variant.
    enum Seal {
        /// Green seal — key-holding import (recovery phrase / private key).
        static func secured(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? (Color(hex: "#2FD07F") ?? .green) : (Color(hex: "#179A5B") ?? .green)
        }
        /// Blue seal — watch-only import (view-only address).
        static func watching(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? (Color(hex: "#5A93F6") ?? .blue) : (Color(hex: "#2F6BD6") ?? .blue)
        }
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
        static let card = Card.background
        /// One step up — for cards inside cards (rare).
        static let elevated = Card.elevated
    }

    // MARK: - FeatureRow

    enum FeatureRow {
        static let icon = Icon.primary
        static let title = Text.primary
        static let detail = Text.secondary
    }

    // MARK: - EmptyState

    enum EmptyState {
        static let background = Card.background
        static let liftStart = Splash.lift
        static let liftEnd = Splash.base
        static let title = Text.secondary
        static let detail = Text.tertiary
        static let icon = Icon.tertiary
        static let logoShadow = Color.black.opacity(0.08)
    }

    // MARK: - Loading

    enum Loading {
        static let spinner = Icon.secondary
        static let caption = Text.secondary
        static let background = Page.background
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
    ///   by brand/system accent surfaces. Primary filled buttons use
    ///   `UniColors.Button.Primary.tint` instead so they remain legible
    ///   in dark mode.
    enum Brand {
        /// Fill color for the Aperture iris mark — graphite in light mode,
        /// soft white in dark mode. Use for the splash iris and the
        /// onboarding welcome-slide hero.
        static let mark = Color("BrandMark")
    }

    // MARK: - WalletAvatar (curated per-wallet identity palette)

    /// Curated palette for the circular wallet-identity avatar
    /// (`WalletAvatar` in `Features/Wallet/WalletAvatar.swift`).
    /// Surfaces in the MainTabView Wallet tab icon, the wallet-home
    /// toolbar pill, the `WalletSwitcherSheet`, the `WalletsListView`
    /// row, and the long-press context-menu switcher.
    ///
    /// **Why a curated 12-color palette, not a freeform ColorPicker.**
    /// Per Rule #2 §A.6 *"Less, but better"* (Rams via Ive). A user
    /// picking from a calibrated 12-color set lands at a tasteful
    /// identity within seconds; a user staring at the full RGB / HSB
    /// wheel can pick a neon yellow that reads as a UI bug in every
    /// other surface of the app. The 12 chosen here are deep,
    /// saturated-but-not-screaming brand-class hues that all carry
    /// the same visual weight against the avatar's white SF Symbol —
    /// so switching between two wallets reads as identity change,
    /// not as contrast change.
    ///
    /// **Why hex strings, not Color values.** The wallet's chosen
    /// identity is persisted as a hex string in
    /// `WalletRecord.iconColorHex` so it survives palette changes —
    /// adding / removing colors from this list never strands an
    /// existing wallet's chosen identity (the avatar primitive
    /// resolves the hex live; if the value isn't in the palette
    /// anymore, the value still renders correctly).
    ///
    /// **The 12 colors and what each says.**
    /// - **Ink** `#0B0D11` — the default. Aperture's monochrome brand.
    ///   Reads as "this is the brand wallet."
    /// - **Slate** `#3A3F4A` — warm graphite. The first step away from
    ///   the brand for users who want quiet differentiation.
    /// - **Crimson** `#B81F2D` — deep, restrained red. Strong enough
    ///   to identify, not so loud it reads as alarm.
    /// - **Tangerine** `#E0651F` — warm orange. Reads as the wallet
    ///   you reach for first; the "everyday" identity.
    /// - **Amber** `#C99020` — autumn gold. Quieter than tangerine.
    /// - **Olive** `#5F7028` — deep olive green. Calm, grounded.
    /// - **Forest** `#2D6E48` — deep, classic green. Reads as
    ///   "savings" or "long-term" without saying so.
    /// - **Teal** `#1D7390` — deep teal. The blue half of the
    ///   blue / green pivot.
    /// - **Cobalt** `#1F4FA8` — confident blue. Reads as a primary
    ///   identity — the "main" wallet for blue-leaning users.
    /// - **Indigo** `#3F2D8A` — deep blue-purple. Bridge between
    ///   blue and purple.
    /// - **Plum** `#7A2E80` — restrained royal purple.
    /// - **Magenta** `#9C2A6C` — warm wine. The most distinct
    ///   non-monochrome identity — for the user who wants their
    ///   wallets to read unmistakably apart at a glance.
    ///
    /// **Foreground contrast.** Every hex in this palette is dark
    /// enough that a white SF Symbol on it passes WCAG AA contrast
    /// (4.5:1 or better) at the 28pt / 36pt / 56pt avatar sizes the
    /// app ships. The avatar primitive renders the SF Symbol in
    /// `.white` for all palette entries; we do not flip to a dark
    /// foreground for lighter user-picked colors because the
    /// palette doesn't ship any.
    enum WalletAvatar {
        /// LEGACY (pre-2026-06-09). The original 12-flat-color palette
        /// used when the avatar was a flat circle + SF Symbol. The new
        /// avatar system uses vertical gradients (see `gradientStops(for:)`
        /// below) — but this legacy table stays for source compatibility
        /// with any caller that still reads
        /// `UniColors.WalletAvatar.curated` (no live consumers as of the
        /// 2026-06-09 rewrite; the symbol exists only so a future agent
        /// reading old code can find the migration path here).
        static let curated: [String] = [
            "#0B0D11", // Ink (default)
            "#3A3F4A", // Slate
            "#B81F2D", // Crimson
            "#E0651F", // Tangerine
            "#C99020", // Amber
            "#5F7028", // Olive
            "#2D6E48", // Forest
            "#1D7390", // Teal
            "#1F4FA8", // Cobalt
            "#3F2D8A", // Indigo
            "#7A2E80", // Plum
            "#9C2A6C"  // Magenta
        ]

        // MARK: - 2026-06-09 gradient palette (the design handoff)
        //
        // The 12 curated vertical gradients from
        // `/Users/thuglifex/Downloads/design_handoff_wallet_avatars/
        // tokens.json`. Each gradient resolves to a top→bottom Color
        // pair, suitable for handing directly to SwiftUI's
        // `LinearGradient(colors: ..., startPoint: .top, endPoint: .bottom)`.
        //
        // This is the only place in the codebase that constructs
        // `Color` from the gradient hex strings — Rule #4 §B exception.
        // Feature code calls `gradientStops(for:)` and never sees the
        // hex values directly.

        /// The top + bottom Color pair for a gradient key, suitable for
        /// `LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)`.
        ///
        /// Malformed hex falls back to `Brand.mark` (Ink light / Cloud
        /// dark) — the neutral brand role — rather than literal black:
        /// the avatar stays visibly on-system in both appearances, and
        /// the flat monochrome disc is itself the signal that a
        /// gradient definition is bad.
        static func gradientStops(for gradient: WalletAvatarGradient) -> [Color] {
            [
                Color(hex: gradient.topHex) ?? Brand.mark,
                Color(hex: gradient.bottomHex) ?? Brand.mark
            ]
        }

        /// Spec-aware gradient stops (2026-06-19). A user-picked custom
        /// colour (`spec.customColorHex`) overrides the preset gradient;
        /// otherwise the preset key resolves as before. The single
        /// resolver every `WalletAvatar` render should call.
        static func gradientStops(for spec: WalletAvatarSpec) -> [Color] {
            if let hex = spec.customColorHex {
                return gradientStops(forCustomHex: hex)
            }
            return gradientStops(for: spec.gradient)
        }

        /// A two-stop gradient derived from a single user-picked colour:
        /// the colour itself on top, a ~38%-darkened shade beneath, so a
        /// custom disc reads with the same lit-from-above depth as the
        /// curated presets. Malformed hex → `Brand.mark` (Rule #4 §B).
        static func gradientStops(forCustomHex hex: String) -> [Color] {
            guard let top = Color(hex: hex) else { return [Brand.mark, Brand.mark] }
            return [top, darkened(hex: hex, by: 0.38) ?? top]
        }

        /// `#RRGGBB` for a SwiftUI `Color` (Rule #4 §B keeps colour ↔ hex
        /// inside `UniColors`). Used by the icon picker to persist the
        /// native colour-picker selection.
        static func hex(from color: Color) -> String {
            let ui = UIColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            let clamp: (CGFloat) -> Int = { Int((max(0, min(1, $0)) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
        }

        /// A `Color` for a `#RRGGBB` string, falling back to the neutral
        /// brand mark on malformed input. The icon picker seeds its
        /// colour-picker state from a persisted custom hex through this.
        static func color(fromHex hex: String) -> Color {
            Color(hex: hex) ?? Brand.mark
        }

        /// `hex` scaled toward black by `fraction` (0…1), returned as a
        /// `Color`. `nil` on malformed input.
        private static func darkened(hex: String, by fraction: CGFloat) -> Color? {
            guard let base = Color(hex: hex) else { return nil }
            let ui = UIColor(base)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            let k = max(0, min(1, 1 - fraction))
            return Color(.sRGB, red: Double(r * k), green: Double(g * k), blue: Double(b * k), opacity: Double(a))
        }

        /// Inner-disc fill color for a wallet-avatar badge. The three
        /// badges (watch / hardware / shared) have fixed hex values per
        /// the design handoff. Same Rule #4 §B exception — hex →
        /// `Color` only inside `UniColors.swift`.
        static func badgeColor(for badge: WalletAvatarBadge) -> Color {
            switch badge {
            case .watch:    return Color(hex: "#2F6BD6") ?? Color.blue
            case .hardware: return Color(hex: "#3A3D45") ?? Color.gray
            case .shared:   return Color(hex: "#179A5B") ?? Color.green
            }
        }
    }

    // MARK: - Send (the money-leaving-your-hands flow)

    /// Brand-specific color roles for the Send flow's signature
    /// surfaces — the dark Sending / Sent screens, the swipe-to-send
    /// track, and the positive / negative status accents the design
    /// handoff (`design_handoff_send/README.md`) specifies as exact
    /// brand values rather than system semantics.
    ///
    /// **Why these are brand-fixed, not system-adaptive.** Per the
    /// handoff, the Sending and Sent screens are *always dark* —
    /// `#0E1015 → #08090C` — regardless of the user's appearance
    /// preference. They're the one moment the flow goes full-bleed
    /// dark to make the commit feel like a held breath: a brand
    /// surface, like the splash. The swipe track is brand Ink
    /// (`#0A0C10`) with a white knob, again fixed. These four values
    /// (`darkScreenTop`, `darkScreenBottom`, `track`, `knob`) do not
    /// flip with light/dark mode — they ARE the surface.
    ///
    /// **The status accents** (`positive` / `negative`) use the
    /// handoff's exact greens/reds (`#179A5B` / `#E0483D`) for the
    /// ENS-resolved row, the Sent hero check, and inline error text —
    /// slightly richer than `systemGreen` / `systemRed` to match the
    /// brand. They're defined once here so feature code references a
    /// role, never the hex (Rule #4 §B — hex → Color only inside this
    /// file). For genuinely system-semantic status (badges, alerts)
    /// continue to use `Status.*` / `Crypto.*`; the `Send.*` accents
    /// are for the Send flow's own surfaces.
    enum Send {
        /// Top stop of the dark Sending / Sent screen radial-lift
        /// gradient. `#0E1015`. Brand-fixed (does not flip with mode).
        static let darkScreenTop = Color(hex: "#0E1015") ?? Color.black
        /// Bottom stop of the dark Sending / Sent screen gradient.
        /// `#08090C`. Brand-fixed.
        static let darkScreenBottom = Color(hex: "#08090C") ?? Color.black
        /// A subtle lighter lift at the top of the dark screen, used as
        /// the radial highlight stop. `#1A1D24`. Brand-fixed.
        static let darkScreenLift = Color(hex: "#1A1D24") ?? Color.black
        /// Text drawn on the dark Sending / Sent screens. Always white
        /// because the surface is always dark.
        static let onDark = Color.white
        /// Secondary text on the dark screens (sub copy). White @ 0.6.
        static let onDarkSecondary = Color.white.opacity(0.6)

        /// The swipe-to-send track fill — brand Ink. `#0A0C10`.
        /// Brand-fixed (the commit gesture reads the same in any mode).
        static let track = Color(hex: "#0A0C10") ?? Color.black
        /// The label text floating on the unfilled track. White @ 0.6.
        static let trackLabel = Color.white.opacity(0.6)
        /// The draggable knob. Always white — it's the bright object
        /// the user pushes across the dark track.
        static let knob = Color.white
        /// The iris glyph painted inside the knob — brand Ink so it
        /// reads on the white knob.
        static let knobGlyph = Color(hex: "#0A0C10") ?? Color.black
        /// Drop-shadow color under the white knob, so it lifts off the
        /// dark track. Black at low opacity — defined here so the call
        /// site references a role, not a `Color.black` literal (Rule #4).
        static let knobShadow = Color.black.opacity(0.3)
        /// Glyph / text drawn over the positive (green) or negative
        /// (red) hero discs on the Sent / Failed screens. Always white —
        /// both discs are guaranteed-colored, so white reads in any
        /// appearance. (Mirrors `Text.onMedia`, named for this surface.)
        static let onAccentDisc = Color.white

        /// Positive accent — ENS-resolved row, the Sent hero check
        /// background. `#179A5B`. The brand green (richer than
        /// `systemGreen`).
        static let positive = Color(hex: "#179A5B") ?? Color.green
        /// A 10%-opacity wash of `positive` for chip / pill
        /// backgrounds behind positive text.
        static let positiveWash = (Color(hex: "#179A5B") ?? Color.green).opacity(0.1)
        /// Negative accent — failed-send copy, validation errors that
        /// must read as a stop. `#E0483D`. The brand red.
        static let negative = Color(hex: "#E0483D") ?? Color.red
        /// A wash of `negative` for the failed-state hero background.
        static let negativeWash = (Color(hex: "#E0483D") ?? Color.red).opacity(0.1)

        // MARK: - V2 bloom + glass surface (design_handoff_send_v2)

        /// **Send v2 bloom background.** The handoff specifies a quiet
        /// bloom — *"never pure white"* — `#F2F3F6 → #E8EAEE` base with two
        /// faint radial tints (blue-gray top-left, violet bottom-right).
        /// Per Rule #2 (honesty) the surface is appearance-adaptive: a
        /// soft light bloom in light mode, a quiet near-black bloom in dark
        /// mode so the whole Send flow respects the user's theme — unlike
        /// the terminal Sending/Sent screens, which are deliberately
        /// brand-fixed dark (a held-breath moment). The two bloom-tint
        /// roles are themselves fixed-hue (cool / warm) at low opacity so
        /// they read as a faint lift over either base. Rule #4 §B — hex →
        /// Color only inside this file.
        ///
        /// Base stops (resolved via Assets so they adapt):
        /// - `bloomBaseTop`    → `SendBloomBaseTop`    (`#F2F3F6` / `#0C0D11`)
        /// - `bloomBaseBottom` → `SendBloomBaseBottom` (`#E8EAEE` / `#070809`)
        static let bloomBaseTop = Color("SendBloomBaseTop")
        static let bloomBaseBottom = Color("SendBloomBaseBottom")
        /// Cool blue-gray radial tint, top-left. `rgba(150,165,200,.32)`.
        static let bloomCool = Color(.sRGB, red: 150/255, green: 165/255, blue: 200/255, opacity: 0.30)
        /// Warm violet radial tint, bottom-right. `rgba(170,150,200,.26)`.
        static let bloomWarm = Color(.sRGB, red: 170/255, green: 150/255, blue: 200/255, opacity: 0.24)
        /// The red attention tint for the poisoning interstitial's top
        /// bloom. `rgba(224,72,61,.16)` — the brand red at a wash.
        static let bloomDanger = (Color(hex: "#E0483D") ?? Color.red).opacity(0.16)

        /// **Glass cards on the bloom (v2).** The handoff's default glass
        /// is `rgba(255,255,255,.58)` + blur + a top specular edge. The
        /// honest native expression is iOS 26's `.regularMaterial` — which
        /// supplies translucency + specular + motion for free (Rule #3) —
        /// but for the *strong* sheet glass and the Reduce-Transparency
        /// solid fallback we need explicit roles. These two adapt:
        /// - `cardSpecular` — the top-edge specular highlight stroke on a
        ///   glass card. White at low opacity in light, soft white in dark.
        /// - `cardSolidFallback` — the opaque card fill under Reduce
        ///   Transparency (`#F7F8FA` light / `#16181D` dark per the handoff
        ///   "fall back to solid cards").
        static let cardSpecular = Color("SendGlassSpecular")
        static let cardSolidFallback = Color("SendGlassSolid")
        /// Hairline border on the Reduce-Transparency solid card.
        static let cardHairline = Color(uiColor: .separator)
        /// Soft drop shadow under a glass card on the bloom. The handoff's
        /// `0 18px 44px -22px rgba(15,18,28,.35)` — expressed as a
        /// low-opacity black so it reads over either base. Named here so the
        /// call site references a role, not a `Color.black` literal (Rule #4).
        static let cardShadow = Color.black.opacity(0.18)

        /// **Dark glass.** Primary buttons / selected chips / the swipe
        /// knob use `rgba(16,18,24,.82)` — a near-opaque brand-ink glass
        /// that reads on the bloom in both modes. We already have
        /// `track` (#0A0C10) for the slide; this is the lighter dark-glass
        /// for selected chip / preset fills.
        static let darkGlass = Color(hex: "#101218")?.opacity(0.92) ?? Color.black.opacity(0.92)
        /// Label drawn on a dark-glass surface — always near-white.
        static let onDarkGlass = Color.white

        /// Scrim over the camera feed (QR scanner). A black wash for chip /
        /// button pills floating over the guaranteed-dark camera surface
        /// (the From-photos / Light chips, the close button). Fixed
        /// black-over-media — the camera feed is dark in any appearance, so
        /// a black scrim is honest here (mirrors `Text.onMedia`). Defined
        /// as a role so feature code never writes `Color.black` at the call
        /// site (Rule #4).
        static let cameraScrim = Color.black.opacity(0.45)
        /// A lighter camera scrim for the small close-button disc.
        static let cameraScrimLight = Color.black.opacity(0.40)
        /// The opaque base behind the camera feed (QR scanner full-screen
        /// surface). Solid black — the camera is dark in any appearance, so
        /// this is the honest base while the feed warms up / when denied.
        static let cameraBase = Color.black
        /// On-camera icon, dimmed — the denied-camera surface glyph over
        /// the dark feed. Opacity lives here, not at the call site (Rule #4).
        static let cameraOnMediaDimIcon = Color.white.opacity(0.7)
        /// On-camera body copy, dimmed — secondary text over the dark feed
        /// on the denied surface. Opacity lives here (Rule #4).
        static let cameraOnMediaDimBody = Color.white.opacity(0.8)
        /// On-camera transient note, near-full — the gallery / paste status
        /// line above the action bar. Opacity lives here (Rule #4).
        static let cameraOnMediaNote = Color.white.opacity(0.9)
    }

    // MARK: - Reset (the factory-reset flow)

    /// Exact palette for the full-screen Reset Aperture flow
    /// (`design_handoff_reset`). The handoff's destructive red is a muted
    /// brick — `#E0483D` (light) / `#FF5B51` (dark) — distinct from the
    /// brighter system red, and the ONLY accent the flow uses (trash hero,
    /// erase buttons, type-field border, progress ring, checked
    /// acknowledgements). Defined here per Rule #4 §B (hex/UIColor only in
    /// `UniColors`); the flow references these roles.
    enum Reset {
        /// `#E0483D` light / `#FF5B51` dark — adaptive, matching the handoff.
        static let danger = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 1.0, green: 0x5B / 255.0, blue: 0x51 / 255.0, alpha: 1)
                : UIColor(red: 0xE0 / 255.0, green: 0x48 / 255.0, blue: 0x3D / 255.0, alpha: 1)
        })
        /// A 10% wash of `danger` (the handoff's `--danger-bg`).
        static let dangerWash = danger.opacity(0.10)
        /// Label on a danger fill — always white (the fill is a guaranteed red,
        /// so white reads in any appearance).
        static let onDanger = Color.white
    }

    // MARK: - PinLock (the unified passcode screen)

    /// Tokens transcribed verbatim from the PIN-lock design handoff
    /// (`design_handoff_pin_lock/`). The keypad is the flat iOS-dialer style —
    /// no key backgrounds, a circular press-dim — so these are the few
    /// brand-fixed values that surface needs beyond `Text` / `Background`
    /// (Rule #4 §B: hex / `UIColor` only inside `UniColors`).
    enum PinLock {
        /// Wrong-passcode accent — the same brick as the Reset flow
        /// (`#E0483D` light / `#FF5B51` dark). Drives the red dots, the shake,
        /// and the "N attempts remaining" line.
        static let danger = Reset.danger
        /// Unlock-success green — `#179A5B` light / `#2FD07F` dark. A brief
        /// fill on the dots when the passcode is correct, before the reveal.
        static let positive = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0x2F / 255.0, green: 0xD0 / 255.0, blue: 0x7F / 255.0, alpha: 1)
                : UIColor(red: 0x17 / 255.0, green: 0x9A / 255.0, blue: 0x5B / 255.0, alpha: 1)
        })
        /// Empty-dot ring — `rgba(10,12,16,.22)` light / `rgba(255,255,255,.3)`
        /// dark. A 2pt inner stroke; the filled dot is solid ink.
        static let dotEmpty = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.30)
                : UIColor(red: 0x0A / 255.0, green: 0x0C / 255.0, blue: 0x10 / 255.0, alpha: 0.22)
        })
        /// Keypad press-dim — the 62pt circle that fades in under a pressed
        /// digit. `rgba(10,12,16,.12)` light / `rgba(255,255,255,.18)` dark.
        static let keyPress = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.18)
                : UIColor(red: 0x0A / 255.0, green: 0x0C / 255.0, blue: 0x10 / 255.0, alpha: 0.12)
        })
        /// Delete-glyph gray — `#B9BCC4` light / `#54565E` dark. The filled
        /// rounded backspace with the knocked-out X.
        static let delete = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0x54 / 255.0, green: 0x56 / 255.0, blue: 0x5E / 255.0, alpha: 1)
                : UIColor(red: 0xB9 / 255.0, green: 0xBC / 255.0, blue: 0xC4 / 255.0, alpha: 1)
        })
    }

    // MARK: - SeedGrid (the recovery-phrase import word grid)

    /// Tokens transcribed from the import-flows handoff
    /// (`design_handoff_import_flows/`) for the per-word recovery-phrase grid.
    /// The per-word status borders reuse `PinLock.positive` (green = valid
    /// BIP-39 word) and `Reset.danger` (red = not in the list); these two are
    /// the grid-specific greys (Rule #4 §B — hex / `UIColor` only here).
    enum SeedGrid {
        /// Recovery-phrase display surface. It follows the normal card fill
        /// in light mode and the elevated card fill in dark mode so secret
        /// phrase cards keep clear separation from the page.
        static let surface = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(Card.elevated)
                : UIColor(Card.background)
        })
        /// Index numbers, the inline ghost completion, and the active (current)
        /// slot's border — `#BCBEC5` light / `#4A4C54` dark (the handoff's
        /// `--faint`).
        static let faint = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0x4A / 255.0, green: 0x4C / 255.0, blue: 0x54 / 255.0, alpha: 1)
                : UIColor(red: 0xBC / 255.0, green: 0xBE / 255.0, blue: 0xC5 / 255.0, alpha: 1)
        })
        /// The cell hairline dividers + the segmented-control track —
        /// `rgba(10,12,16,.05)` light / `rgba(255,255,255,.07)` dark (the
        /// handoff's `--seg-bg`).
        static let hairline = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.07)
                : UIColor(red: 0x0A / 255.0, green: 0x0C / 255.0, blue: 0x10 / 255.0, alpha: 0.05)
        })
    }

    // MARK: - BalanceCard (the flagship wallet-home surface)

    /// Every color the flagship balance card uses, transcribed verbatim
    /// from the design handoff
    /// (`design_handoff_balance_card 2/README.md` §Color tokens).
    ///
    /// **Why these are brand-fixed per mode (Rule #4 §B exception), not
    /// system semantics.** The card is its own gradient surface — it does
    /// NOT sit on the iOS grouped-card fill. The handoff specifies exact
    /// dark and light gradients (`#16181D→#0A0B0E` radial-lifted in dark,
    /// `#FBFBFD→#EFF1F5` in light), exact muted/decimals tints, exact
    /// up/down/flat semantic colors (a brighter green/red in dark so the
    /// chart glows, the deeper green/red in light), and exact pill
    /// background alphas. These are load-bearing brand values that the
    /// system palette can't express; they live here as the single hex
    /// surface (every other color in the app still flows through a
    /// semantic role). Each role is a `ColorScheme` function so the call
    /// site passes its resolved scheme and never sees a hex value — the
    /// card adapts to the app's appearance (dark card in dark mode, light
    /// card in light mode), matching the handoff's two-column reference.
    ///
    /// **`Increase Contrast` (handoff §Accessibility).** When the call
    /// site reports `legibilityWeight`/high-contrast, the muted/label
    /// tints lift to the stronger values the handoff names
    /// (`.7` / `#6E7079`); the card passes a `boostContrast` flag.
    enum BalanceCard {

        // MARK: Surface gradient

        /// Radial-lift top stop (`130% 90% at 12% 0%`). Dark: `#2B2E36`.
        /// Light: `#FFFFFF`. The bright corner that gives the card depth.
        static func surfaceLift(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? hex("#2B2E36") : hex("#FFFFFF")
        }
        /// Linear-gradient top stop (`165deg`). Dark: `#16181D`.
        /// Light: `#FBFBFD`.
        static func surfaceTop(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? hex("#16181D") : hex("#FBFBFD")
        }
        /// Linear-gradient bottom stop. Dark: `#0A0B0E`. Light: `#EFF1F5`.
        static func surfaceBottom(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? hex("#0A0B0E") : hex("#EFF1F5")
        }
        /// The card's drop shadow. Dark: `rgba(0,0,0,.7)`. Light:
        /// `rgba(10,12,16,.34)`. The handoff's offset/blur are applied at
        /// the call site; this is just the color.
        static func shadow(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color.black.opacity(0.5)
                : (hex("#0A0C10")).opacity(0.30)
        }
        /// The faint inner top-edge specular highlight
        /// (`inset 0 1px 0 …`). Dark: `rgba(255,255,255,.06)`. Light:
        /// `#fff`. Drawn as a 1pt top hairline overlay.
        static func innerEdge(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.06) : Color.white
        }
        /// The light-mode 1px hairline border (`0 0 0 1px rgba(10,12,16,.05)`).
        /// `nil` in dark (the dark card has no border, only the inner edge).
        static func hairline(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.clear : (hex("#0A0C10")).opacity(0.05)
        }

        // MARK: Text

        /// Primary text (wallet name, the balance integer). Dark:
        /// `#FFFFFF`. Light: `#0A0C10`. Fixed to the card surface, NOT
        /// `.label` — the card is its own appearance-fixed surface.
        static func textPrimary(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? hex("#FFFFFF") : hex("#0A0C10")
        }
        /// Label / muted (the "Total balance" caption, the "today" amount,
        /// the address line, resting segment text). Dark:
        /// `rgba(255,255,255,.55)`. Light: `#8B8D94`. Lifts under
        /// Increase Contrast to `.7` / `#6E7079`.
        static func textMuted(_ scheme: ColorScheme, boostContrast: Bool = false) -> Color {
            if boostContrast {
                return scheme == .dark ? Color.white.opacity(0.7) : hex("#6E7079")
            }
            return scheme == .dark ? Color.white.opacity(0.55) : hex("#8B8D94")
        }
        /// The fainter decimals tint. Dark: `rgba(255,255,255,.35)`.
        /// Light: `#B4B6BE`. The handoff's signature "decimals in a
        /// fainter tint" treatment on the balance number.
        static func decimals(_ scheme: ColorScheme, boostContrast: Bool = false) -> Color {
            if boostContrast {
                return scheme == .dark ? Color.white.opacity(0.5) : hex("#9A9CA4")
            }
            return scheme == .dark ? Color.white.opacity(0.35) : hex("#B4B6BE")
        }
        /// The "Copy address" action color — slightly stronger than the
        /// plain muted so it reads as tappable. Dark: `rgba(255,255,255,.6)`.
        /// Light: `#6E7079`.
        static func copyAction(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.6) : hex("#6E7079")
        }

        // MARK: Controls

        /// The circular eye/visibility button background. Dark:
        /// `rgba(255,255,255,.08)`. Light: `rgba(10,12,16,.05)`.
        static func eyeButtonFill(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.08) : (hex("#0A0C10")).opacity(0.05)
        }
        /// The eye glyph color. Dark: `rgba(255,255,255,.8)`. Light:
        /// `#54565E`.
        static func eyeGlyph(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.8) : hex("#54565E")
        }
        /// The avatar disc's 1px ring. Dark: `rgba(255,255,255,.1)`.
        /// Light: `rgba(10,12,16,.08)`.
        static func avatarRing(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.1) : (hex("#0A0C10")).opacity(0.08)
        }

        // MARK: Segmented selector

        /// Segment track fill. Dark: `rgba(255,255,255,.07)`. Light:
        /// `rgba(10,12,16,.05)`.
        static func segmentTrack(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.07) : (hex("#0A0C10")).opacity(0.05)
        }
        /// Active-segment pill fill. Dark: `rgba(255,255,255,.14)`.
        /// Light: `#fff` (with a soft drop shadow, applied at the call
        /// site).
        static func segmentActiveFill(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.14) : hex("#FFFFFF")
        }
        /// Active-segment text. Dark: `#fff`. Light: `#0A0C10`.
        static func segmentActiveText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? hex("#FFFFFF") : hex("#0A0C10")
        }
        /// Soft shadow under the light-mode active pill
        /// (`0 2px 8px -3px rgba(10,12,16,.3)`). Color only.
        static func segmentActiveShadow(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.clear : (hex("#0A0C10")).opacity(0.3)
        }

        // MARK: Watermark

        /// The iris watermark opacity behind the value. Dark: `0.05`.
        /// Light: `0.045`.
        static func watermarkOpacity(_ scheme: ColorScheme) -> Double {
            scheme == .dark ? 0.05 : 0.045
        }

        // MARK: Semantic (change pill + chart) — by sign

        /// The chart-state sign the card is rendering. Drives the stroke,
        /// fill, and pill colors together (handoff §State selection logic
        /// — pill icon, chart color, and percent always agree).
        enum Sign: Equatable {
            case up, down, flat
        }

        /// Stroke / accent color for the chart line + the pill foreground.
        /// Up: bright green in dark (`#3FE79A`, glow on) / deep green in
        /// light (`#179A5B`). Down: bright red dark (`#FF7A6B`) / deep red
        /// light (`#E0483D`). Flat: white@low-opacity dark / ink@low-opacity
        /// light (the neutral mid-line, no glow).
        static func accent(_ sign: Sign, _ scheme: ColorScheme) -> Color {
            switch sign {
            case .up:
                return scheme == .dark ? hex("#3FE79A") : hex("#179A5B")
            case .down:
                return scheme == .dark ? hex("#FF7A6B") : hex("#E0483D")
            case .flat:
                return scheme == .dark ? Color.white.opacity(0.65) : hex("#8B8D94")
            }
        }

        /// The chart STROKE color specifically. For up/down it equals
        /// `accent`; for flat the handoff draws the line in a dimmer
        /// neutral (`rgba(255,255,255,.45)` dark / `rgba(10,12,16,.4)`
        /// light) than the flat pill text — separated so the flat chart
        /// line reads quieter than its pill.
        static func chartStroke(_ sign: Sign, _ scheme: ColorScheme) -> Color {
            switch sign {
            case .up, .down:
                return accent(sign, scheme)
            case .flat:
                return scheme == .dark ? Color.white.opacity(0.45) : (hex("#0A0C10")).opacity(0.4)
            }
        }

        /// The hue the gradient area fill is built from (matches the
        /// stroke hue per handoff). For flat, the fill uses the card's
        /// monochrome primary at a low opacity.
        static func chartFillHue(_ sign: Sign, _ scheme: ColorScheme) -> Color {
            switch sign {
            case .up, .down:
                return accent(sign, scheme)
            case .flat:
                return textPrimary(scheme)
            }
        }

        /// The gradient area fill's top opacity. Up/down: `0.20` (up)
        /// / `0.18` (down) per the HTML reference. Flat: `0.06` (a
        /// barely-there wash). Bottom is always `0`.
        static func chartFillTopOpacity(_ sign: Sign) -> Double {
            switch sign {
            case .up:   return 0.20
            case .down: return 0.18
            case .flat: return 0.06
            }
        }

        /// Whether the dark-mode gaussian glow filter is applied to the
        /// stroke. On for up/down in dark; off for flat and always off
        /// in light (handoff: "Dark chart has the glow; light chart does
        /// not").
        static func chartGlow(_ sign: Sign, _ scheme: ColorScheme) -> Bool {
            scheme == .dark && sign != .flat
        }

        /// Change-pill background. Up dark `rgba(45,224,140,.16)` / light
        /// `rgba(23,154,91,.12)`. Down dark `rgba(255,122,107,.16)` /
        /// light `rgba(224,72,61,.1)`. Flat dark `rgba(255,255,255,.1)` /
        /// light `rgba(10,12,16,.06)`.
        static func pillBackground(_ sign: Sign, _ scheme: ColorScheme) -> Color {
            switch sign {
            case .up:
                return scheme == .dark
                    ? Color(.sRGB, red: 45/255, green: 224/255, blue: 140/255, opacity: 0.16)
                    : Color(.sRGB, red: 23/255, green: 154/255, blue: 91/255, opacity: 0.12)
            case .down:
                return scheme == .dark
                    ? Color(.sRGB, red: 255/255, green: 122/255, blue: 107/255, opacity: 0.16)
                    : Color(.sRGB, red: 224/255, green: 72/255, blue: 61/255, opacity: 0.10)
            case .flat:
                return scheme == .dark
                    ? Color.white.opacity(0.1)
                    : (hex("#0A0C10")).opacity(0.06)
            }
        }

        // MARK: Zero state

        /// The "Add funds" button fill. Dark: white (`#fff`). Light: ink
        /// (`#0A0C10`). The handoff inverts the button against the card.
        static func fundButtonFill(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? hex("#FFFFFF") : hex("#0A0C10")
        }
        /// The "Add funds" label/glyph. Dark: ink. Light: white. (Opposes
        /// `fundButtonFill`.)
        static func fundButtonLabel(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? hex("#0A0C10") : hex("#FFFFFF")
        }

        // MARK: Scrub cursor

        /// The scrub hairline / cursor color — the chart accent at the
        /// touched point (handoff §Interactions: "dot.style.background =
        /// d.col").
        static func scrubCursor(_ sign: Sign, _ scheme: ColorScheme) -> Color {
            chartStroke(sign, scheme)
        }

        /// File-local hex resolver — re-uses the Rule #4 §B `Color(hex:)`
        /// initializer that is fileprivate to this file. Falls back to a
        /// neutral so a typo never crashes the flagship surface.
        private static func hex(_ value: String) -> Color {
            Color(hex: value) ?? Color(uiColor: .label)
        }
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

// MARK: - Rule #4 §B hex initializer (file-scoped to UniColors.swift)
//
// Per Rule #4 §B, `UniColors.swift` is the ONLY place that may
// construct a `Color` from a hex string. This `fileprivate` initializer
// is the single such surface — the WalletAvatar gradient + badge
// resolvers above use it; feature code cannot reach it. Every other
// color in the app continues to flow through a named role.
fileprivate extension Color {
    /// Decode a `#RRGGBB` or `#RRGGBBAA` hex string to a SwiftUI `Color`.
    /// Returns `nil` on invalid input (callers fall back to a sensible
    /// default — see `gradientStops(for:)`).
    init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6 || trimmed.count == 8 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&rgb) else { return nil }
        let r, g, b, a: Double
        if trimmed.count == 6 {
            r = Double((rgb >> 16) & 0xFF) / 255.0
            g = Double((rgb >> 8)  & 0xFF) / 255.0
            b = Double(rgb         & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((rgb >> 24) & 0xFF) / 255.0
            g = Double((rgb >> 16) & 0xFF) / 255.0
            b = Double((rgb >> 8)  & 0xFF) / 255.0
            a = Double(rgb         & 0xFF) / 255.0
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
