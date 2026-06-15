import SwiftUI

/// Full Apple type ramp using `Font.system(_:design:weight:)` so every label
/// scales with Dynamic Type and respects bold-text accessibility.
///
/// Use these tokens via the `UniTitle` / `UniSubtitle` / `UniBody` / `UniCaption`
/// components — never apply `.font(...)` ad-hoc in feature code.
enum UniTypography {
    // Display & headlines
    static let largeTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    static let title1 = Font.system(.title, design: .default, weight: .semibold)
    static let title2 = Font.system(.title2, design: .default, weight: .semibold)
    static let title3 = Font.system(.title3, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)

    // Body
    static let body = Font.system(.body, design: .default, weight: .regular)
    static let bodyEmphasized = Font.system(.body, design: .default, weight: .semibold)

    // Supporting
    static let callout = Font.system(.callout, design: .default, weight: .regular)
    static let subheadline = Font.system(.subheadline, design: .default, weight: .regular)
    static let subheadlineEmphasized = Font.system(.subheadline, design: .default, weight: .semibold)
    static let footnote = Font.system(.footnote, design: .default, weight: .regular)
    static let caption1 = Font.system(.caption, design: .default, weight: .regular)
    static let caption2 = Font.system(.caption2, design: .default, weight: .regular)

    // Controls
    static let buttonLabel = Font.system(.body, design: .default, weight: .semibold)

    // Numeric (use for balances / prices — tabular figures align decimals)
    static let monoBalance = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()
    static let monoBody = Font.system(.body, design: .default, weight: .regular).monospacedDigit()

    /// Hero balance — the wallet-home total. Rounded-design, semibold,
    /// monospaced-digit so the decimals never shift as the balance
    /// refreshes. Larger than `monoBalance` because it carries the
    /// screen's single most important fact and the design's calm is
    /// expressed through the size + space around it, not through
    /// decoration. Tied to the system `largeTitle` style so Dynamic
    /// Type still scales it.
    static let heroBalance = Font.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit()

    // MARK: - Balance card (flagship — fixed-size by design)

    /// The flagship balance card's type ramp, transcribed verbatim from
    /// the design handoff (`design_handoff_balance_card 2/README.md` §Type:
    /// "SF Pro Display, tabular figures everywhere numeric"). These are
    /// **fixed point sizes** — unlike the system-style tokens above —
    /// because the card is a pixel-exact handoff where the relationship
    /// between the 44pt balance, the 21pt currency code, and the 13pt
    /// pill is load-bearing; letting Dynamic Type rescale them
    /// independently would break the composition the designer specified.
    /// The card still honors accessibility through its own
    /// `minimumScaleFactor` on the balance and `Dynamic Type`-respecting
    /// chrome around it (VoiceOver reads one combined label per the
    /// handoff §Accessibility). All numeric styles carry
    /// `.monospacedDigit()` so digits never reflow as the value ticks.
    ///
    /// Tracking: the handoff specifies the balance at `−0.03em`. SwiftUI
    /// applies this via `.tracking(...)` at the call site (a negative
    /// point value derived from the size); the font tokens here carry
    /// only size + weight + design + figure style.
    enum BalanceCard {
        /// Balance integer + decimals — 44 / 700, tabular. SF Pro Display
        /// (the system `.default` design IS SF Pro on iOS). The decimals
        /// share this size; only their color differs (fainter tint).
        static let balance = Font.system(size: 44, weight: .bold).monospacedDigit()
        /// Currency code prefix — 21 / 600, tabular, muted color.
        static let currency = Font.system(size: 21, weight: .semibold).monospacedDigit()
        /// "Total balance" label — 13 / 500, muted.
        static let label = Font.system(size: 13, weight: .medium)
        /// Change pill (▲/▼ + percent) — 13 / 600, tabular.
        static let pill = Font.system(size: 13, weight: .semibold).monospacedDigit()
        /// "+293.10 today" amount line — 13 / 500, tabular, muted.
        static let amount = Font.system(size: 13, weight: .medium).monospacedDigit()
        /// Wallet name in the header — 14.5 / 600.
        static let walletName = Font.system(size: 14.5, weight: .semibold)
        /// "Copy address" action beneath the name — 11.5 / 500, muted.
        static let address = Font.system(size: 11.5, weight: .medium)
        /// Segmented time-selector item — 12.5 / 600.
        static let segment = Font.system(size: 12.5, weight: .semibold)
        /// Zero-state prompt copy — 13.5 / 400, muted.
        static let zeroPrompt = Font.system(size: 13.5, weight: .regular)
        /// "Add funds" button label — 14 / 600.
        static let fundButton = Font.system(size: 14, weight: .semibold)
        /// The scrub-readout time stamp suffix — 13 / 500, tabular,
        /// matches `amount` so the live readout reads as the same line.
        static let scrubReadout = Font.system(size: 13, weight: .medium).monospacedDigit()
    }
}
