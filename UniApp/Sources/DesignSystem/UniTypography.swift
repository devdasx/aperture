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
}
