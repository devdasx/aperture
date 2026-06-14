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
        /// adapts. Existing consumers (`BrowserQRScanSheet`, white
        /// over the camera feed) are correct with white and should
        /// migrate to the honestly-named `onMedia` below.
        static let onTint = Color.white
        /// Always-white text over media (camera feed, imagery) that is
        /// dark in both appearances. The properly-named home for the
        /// `onTint` consumers above.
        static let onMedia = Color.white
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
        /// Primary CTA (`UniButton.primary` → `.glassProminent`).
        ///
        /// Adapts against the **monochrome accent** (Ink `#0B0D11`
        /// light / Cloud `#F5F5F7` dark — see the `Brand` doc below):
        /// `systemBackground` resolves to white in light (on Ink) and
        /// black in dark (on Cloud), so the label always opposes the
        /// accent fill. Literal `Color.white` here was invisible in
        /// dark mode (~1:1 contrast on Cloud) — e.g. the selected
        /// word chips in `BackupVerifyView`.
        static let primaryLabel = Color(uiColor: .systemBackground)
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
        /// Disabled fill for PROMINENT CTAs (`.primary` / `.destructive`
        /// / `.actionCircle` → `.glassProminent`). One step heavier than
        /// `disabledFill` so a disabled prominent button still reads as a
        /// solid (but inert) surface rather than a faint outline.
        static let disabledProminentFill = Color(uiColor: .tertiarySystemFill)
        /// Disabled fill for NEUTRAL / glass CTAs (`.secondary` /
        /// `.toolbarPill` / `.walletPill` → `.glass`). The lightest fill
        /// — the glass surface goes quiet when its action is unavailable.
        static let disabledFill = Color(uiColor: .quaternarySystemFill)
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
