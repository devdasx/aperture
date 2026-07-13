import SwiftUI
import UIKit

/// The three visual floors shipped by Aperture plus the automatic system
/// resolver. System maps light to Cloud and dark to Midnight.
enum ApertureAppearance: Int, CaseIterable, Sendable {
    case system
    case cloud
    case midnight
    case dark

    fileprivate func resolved(for interfaceStyle: UIUserInterfaceStyle) -> ApertureAppearance {
        guard self == .system else { return self }
        return interfaceStyle == .dark ? .midnight : .cloud
    }
}

/// Custom UIKit trait used by dynamic colors. Marking it as color-affecting
/// makes UIKit invalidate resolved colors when users switch between Midnight
/// and Dark even though both use the system dark interface style.
struct ApertureAppearanceTrait: UITraitDefinition {
    static let defaultValue: ApertureAppearance = .system
    static let identifier = "com.aperture.wallet.appearance"
    static let name = "Aperture Appearance"
    static let affectsColorAppearance = true
}

private struct ApertureAppearanceEnvironmentKey: UITraitBridgedEnvironmentKey {
    static let defaultValue: ApertureAppearance = .system

    static func read(from traitCollection: UITraitCollection) -> ApertureAppearance {
        traitCollection[ApertureAppearanceTrait.self]
    }

    static func write(
        to mutableTraits: inout any UIMutableTraits,
        value: ApertureAppearance
    ) {
        mutableTraits[ApertureAppearanceTrait.self] = value
    }
}

extension EnvironmentValues {
    var apertureAppearance: ApertureAppearance {
        get { self[ApertureAppearanceEnvironmentKey.self] }
        set { self[ApertureAppearanceEnvironmentKey.self] = newValue }
    }
}

/// Machine-generated runtime palette from the Aperture Colors Handoff.
///
/// Each token is an exact #RRGGBBAA value for Cloud, Midnight, and Dark.
/// Views continue to consume semantic `UniColors` roles; those roles resolve
/// through this table and the custom appearance trait.
enum UniColorPalette {
    struct Swatch: Sendable {
        let cloud: UInt32
        let midnight: UInt32
        let dark: UInt32

        func value(for appearance: ApertureAppearance) -> UInt32 {
            switch appearance {
            case .system, .cloud: return cloud
            case .midnight: return midnight
            case .dark: return dark
            }
        }
    }

    static var tokenCount: Int { swatches.count }

    static func color(_ token: String) -> Color {
        Color(uiColor: uiColor(token))
    }

    static func uiColor(_ token: String) -> UIColor {
        guard let swatch = swatches[token] else {
            assertionFailure("Missing Aperture color token: \(token)")
            return .clear
        }

        return UIColor { traits in
            // Midnight and Dark both force `UIUserInterfaceStyle.dark`. The
            // only discriminator is `ApertureAppearance`. SwiftUI's trait
            // bridge does not always deliver the custom trait into every
            // `Color(uiColor:)` / `UIColor` resolution site, so the
            // app-published preference (set by `.apertureEnvironment()`)
            // is authoritative. An explicit non-system trait still wins
            // for previews and isolated UIKit hosts that set traitOverrides
            // without publishing process state.
            let published = ApertureAppearanceResolution.current
            let traitValue = traits[ApertureAppearanceTrait.self]
            let requested: ApertureAppearance
            if published != .system {
                requested = published
            } else if traitValue != .system {
                requested = traitValue
            } else {
                requested = .system
            }
            let appearance = requested.resolved(for: traits.userInterfaceStyle)
            return uiColor(from: swatch.value(for: appearance))
        }
    }

    static func rgbaHex(
        for token: String,
        appearance: ApertureAppearance
    ) -> UInt32? {
        swatches[token]?.value(for: appearance)
    }

    private static func uiColor(from rgba: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }

    private static let swatches: [String: Swatch] = [
        "UniColors.Page.background": Swatch(cloud: 0xF5F5F7FF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Card.background": Swatch(cloud: 0xFFFFFFFF, midnight: 0x212229FF, dark: 0x1C1C1EFF),
        "UniColors.Card.elevated": Swatch(cloud: 0xF5F5F7FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Card.stroke": Swatch(cloud: 0x3C3C434A, midnight: 0x54545899, dark: 0x54545899),
        "UniColors.Card.secondaryText": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.List.background": Swatch(cloud: 0xF5F5F7FF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.List.rowBackground": Swatch(cloud: 0xFFFFFFFF, midnight: 0x212229FF, dark: 0x1C1C1EFF),
        "UniColors.List.rowBackgroundElevated": Swatch(cloud: 0xF5F5F7FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.List.rowPressed": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.List.separator": Swatch(cloud: 0x3C3C434A, midnight: 0x54545899, dark: 0x54545899),
        "UniColors.List.sectionHeader": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Background.primary": Swatch(cloud: 0xF5F5F7FF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Background.secondary": Swatch(cloud: 0xFFFFFFFF, midnight: 0x212229FF, dark: 0x1C1C1EFF),
        "UniColors.Background.tertiary": Swatch(cloud: 0xF5F5F7FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Background.groupedPrimary": Swatch(cloud: 0xF5F5F7FF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Background.groupedSecondary": Swatch(cloud: 0xFFFFFFFF, midnight: 0x212229FF, dark: 0x1C1C1EFF),
        "UniColors.Background.groupedTertiary": Swatch(cloud: 0xF5F5F7FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Text.primary": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Text.secondary": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Text.tertiary": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Text.disabled": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Text.quaternary": Swatch(cloud: 0x3C3C432E, midnight: 0xEBEBF52E, dark: 0xEBEBF52E),
        "UniColors.Text.placeholder": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Text.onTint": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Text.onMedia": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Text.inverted": Swatch(cloud: 0xFFFFFFFF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Text.link": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Text.success": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Text.warning": Swatch(cloud: 0xFF9500FF, midnight: 0xFF9F0AFF, dark: 0xFF9F0AFF),
        "UniColors.Text.error": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Text.info": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Copy.largeTitle": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Copy.title": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Copy.headline": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Copy.body": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Copy.subtitle": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Copy.callout": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Copy.footnote": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Copy.caption": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Icon.primary": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Icon.secondary": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Icon.tertiary": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Icon.disabled": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Icon.quaternary": Swatch(cloud: 0x3C3C432E, midnight: 0xEBEBF52E, dark: 0xEBEBF52E),
        "UniColors.Icon.accent": Swatch(cloud: 0x0B0D11FF, midnight: 0xF5F5F7FF, dark: 0xF5F5F7FF),
        "UniColors.Icon.onTint": Swatch(cloud: 0xFFFFFFFF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Icon.success": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Icon.warning": Swatch(cloud: 0xFF9500FF, midnight: 0xFF9F0AFF, dark: 0xFF9F0AFF),
        "UniColors.Icon.error": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Icon.info": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Navigation.title": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Navigation.largeTitle": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Navigation.icon": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Navigation.iconSecondary": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Sheet.background": Swatch(cloud: 0xF5F5F7FF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Sheet.title": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Sheet.body": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Sheet.subtitle": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Sheet.backIcon": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Fill.primary": Swatch(cloud: 0x78788033, midnight: 0x7878805C, dark: 0x7878805C),
        "UniColors.Fill.secondary": Swatch(cloud: 0x78788029, midnight: 0x78788052, dark: 0x78788052),
        "UniColors.Fill.tertiary": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.Fill.quaternary": Swatch(cloud: 0x74748014, midnight: 0x7676802E, dark: 0x7676802E),
        "UniColors.Separator.regular": Swatch(cloud: 0x3C3C434A, midnight: 0x54545899, dark: 0x54545899),
        "UniColors.Separator.opaque": Swatch(cloud: 0xC6C6C8FF, midnight: 0x3A3C42FF, dark: 0x38383AFF),
        "UniColors.Stroke.regular": Swatch(cloud: 0x3C3C434A, midnight: 0x54545899, dark: 0x54545899),
        "UniColors.Stroke.opaque": Swatch(cloud: 0xC6C6C8FF, midnight: 0x3A3C42FF, dark: 0x38383AFF),
        "UniColors.Tint.accent": Swatch(cloud: 0x0B0D11FF, midnight: 0xF5F5F7FF, dark: 0xF5F5F7FF),
        "UniColors.Tint.red": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Tint.orange": Swatch(cloud: 0xFF9500FF, midnight: 0xFF9F0AFF, dark: 0xFF9F0AFF),
        "UniColors.Tint.yellow": Swatch(cloud: 0xFFCC00FF, midnight: 0xFFD60AFF, dark: 0xFFD60AFF),
        "UniColors.Tint.green": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Tint.mint": Swatch(cloud: 0x00C7BEFF, midnight: 0x66D4CFFF, dark: 0x66D4CFFF),
        "UniColors.Tint.teal": Swatch(cloud: 0x30B0C7FF, midnight: 0x40C8E0FF, dark: 0x40C8E0FF),
        "UniColors.Tint.cyan": Swatch(cloud: 0x32ADE6FF, midnight: 0x64D2FFFF, dark: 0x64D2FFFF),
        "UniColors.Tint.blue": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Tint.indigo": Swatch(cloud: 0x5856D6FF, midnight: 0x5E5CE6FF, dark: 0x5E5CE6FF),
        "UniColors.Tint.purple": Swatch(cloud: 0xAF52DEFF, midnight: 0xBF5AF2FF, dark: 0xBF5AF2FF),
        "UniColors.Tint.pink": Swatch(cloud: 0xFF2D55FF, midnight: 0xFF375FFF, dark: 0xFF375FFF),
        "UniColors.Tint.brown": Swatch(cloud: 0xA2845EFF, midnight: 0xAC8E68FF, dark: 0xAC8E68FF),
        "UniColors.Tint.gray": Swatch(cloud: 0x8E8E93FF, midnight: 0x8E8E93FF, dark: 0x8E8E93FF),
        "UniColors.Button.Primary.label": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.Primary.tint": Swatch(cloud: 0x000000FF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Button.Primary.disabledTint": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.Button.Primary.disabledLabel": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.Secondary.label": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.Secondary.tint": Swatch(cloud: 0x000000FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Button.Secondary.disabledTint": Swatch(cloud: 0x74748014, midnight: 0x7676802E, dark: 0x7676802E),
        "UniColors.Button.Secondary.disabledLabel": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.Destructive.label": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.Destructive.tint": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Button.Destructive.disabledTint": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.Button.Destructive.disabledLabel": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.TextAction.foreground": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Button.TextAction.disabled": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.SecondaryTextAction.foreground": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Button.SecondaryTextAction.disabled": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.ToolbarPill.label": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.ToolbarPill.tint": Swatch(cloud: 0x000000FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Button.ToolbarPill.disabledTint": Swatch(cloud: 0x74748014, midnight: 0x7676802E, dark: 0x7676802E),
        "UniColors.Button.ToolbarPill.disabledLabel": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.WalletPill.label": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.WalletPill.tint": Swatch(cloud: 0x000000FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Button.WalletPill.disabledTint": Swatch(cloud: 0x74748014, midnight: 0x7676802E, dark: 0x7676802E),
        "UniColors.Button.WalletPill.disabledLabel": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.ActionCircle.label": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.ActionCircle.tint": Swatch(cloud: 0x000000FF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Button.ActionCircle.disabledTint": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.Button.ActionCircle.disabledLabel": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.primaryLabel": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.controlSurface": Swatch(cloud: 0x000000FF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Button.primaryTint": Swatch(cloud: 0x000000FF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Button.secondaryLabel": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.secondaryTint": Swatch(cloud: 0x000000FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Button.destructiveLabel": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Button.destructiveTint": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Button.text": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Button.secondaryText": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Button.tertiaryLabel": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Button.disabledLabel": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Button.disabledProminentFill": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.Button.disabledFill": Swatch(cloud: 0x74748014, midnight: 0x7676802E, dark: 0x7676802E),
        "UniColors.Button.disabledTint": Swatch(cloud: 0x74748014, midnight: 0x7676802E, dark: 0x7676802E),
        "UniColors.Input.background": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.Input.focusedBackground": Swatch(cloud: 0xFFFFFFFF, midnight: 0x212229FF, dark: 0x1C1C1EFF),
        "UniColors.Input.backgroundElevated": Swatch(cloud: 0x74748014, midnight: 0x7676802E, dark: 0x7676802E),
        "UniColors.Input.text": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Input.placeholder": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Input.icon": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Input.revealIcon": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Input.border": Swatch(cloud: 0x00000000, midnight: 0x191A1E00, dark: 0x00000000),
        "UniColors.Input.focusedBorder": Swatch(cloud: 0x00000000, midnight: 0x191A1E00, dark: 0x00000000),
        "UniColors.Input.disabledBackground": Swatch(cloud: 0x74748014, midnight: 0x7676802E, dark: 0x7676802E),
        "UniColors.Input.disabledText": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Toggle.tint": Swatch(cloud: 0x0B0D11FF, midnight: 0xF5F5F7FF, dark: 0xF5F5F7FF),
        "UniColors.Toggle.label": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Toggle.secondaryLabel": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Toggle.trackOn": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Toggle.trackOff": Swatch(cloud: 0xE4E4E7FF, midnight: 0x3A3C42FF, dark: 0x48484AFF),
        "UniColors.Toggle.knob": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Toggle.knobOn": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Toggle.knobShadow": Swatch(cloud: 0x00000026, midnight: 0x0000004D, dark: 0x0000004D),
        "UniColors.Toggle.trackOnDestructive": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Toggle.trackDisabled": Swatch(cloud: 0xEBEBEDFF, midnight: 0x2A2C32FF, dark: 0x1C1C1EFF),
        "UniColors.Toggle.knobDisabled": Swatch(cloud: 0xFCFCFCFF, midnight: 0x8A8A90FF, dark: 0x8A8A90FF),
        "UniColors.Feedback.Success.background": Swatch(cloud: 0x34C75926, midnight: 0x30D15826, dark: 0x30D15826),
        "UniColors.Feedback.Success.foreground": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Feedback.Success.stroke": Swatch(cloud: 0x34C7594D, midnight: 0x30D1584D, dark: 0x30D1584D),
        "UniColors.Badge.Success.background": Swatch(cloud: 0x34C75926, midnight: 0x30D15826, dark: 0x30D15826),
        "UniColors.Badge.Success.foreground": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Badge.Success.stroke": Swatch(cloud: 0x34C7594D, midnight: 0x30D1584D, dark: 0x30D1584D),
        "UniColors.Feedback.Warning.background": Swatch(cloud: 0xFF950026, midnight: 0xFF9F0A26, dark: 0xFF9F0A26),
        "UniColors.Feedback.Warning.foreground": Swatch(cloud: 0xFF9500FF, midnight: 0xFF9F0AFF, dark: 0xFF9F0AFF),
        "UniColors.Feedback.Warning.stroke": Swatch(cloud: 0xFF95004D, midnight: 0xFF9F0A4D, dark: 0xFF9F0A4D),
        "UniColors.Badge.Warning.background": Swatch(cloud: 0xFF950026, midnight: 0xFF9F0A26, dark: 0xFF9F0A26),
        "UniColors.Badge.Warning.foreground": Swatch(cloud: 0xFF9500FF, midnight: 0xFF9F0AFF, dark: 0xFF9F0AFF),
        "UniColors.Badge.Warning.stroke": Swatch(cloud: 0xFF95004D, midnight: 0xFF9F0A4D, dark: 0xFF9F0A4D),
        "UniColors.Feedback.Error.background": Swatch(cloud: 0xFF3B3026, midnight: 0xFF453A26, dark: 0xFF453A26),
        "UniColors.Feedback.Error.foreground": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Feedback.Error.stroke": Swatch(cloud: 0xFF3B304D, midnight: 0xFF453A4D, dark: 0xFF453A4D),
        "UniColors.Badge.Error.background": Swatch(cloud: 0xFF3B3026, midnight: 0xFF453A26, dark: 0xFF453A26),
        "UniColors.Badge.Error.foreground": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Badge.Error.stroke": Swatch(cloud: 0xFF3B304D, midnight: 0xFF453A4D, dark: 0xFF453A4D),
        "UniColors.Feedback.Info.background": Swatch(cloud: 0x007AFF26, midnight: 0x0A84FF26, dark: 0x0A84FF26),
        "UniColors.Feedback.Info.foreground": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Feedback.Info.stroke": Swatch(cloud: 0x007AFF4D, midnight: 0x0A84FF4D, dark: 0x0A84FF4D),
        "UniColors.Badge.Info.background": Swatch(cloud: 0x007AFF26, midnight: 0x0A84FF26, dark: 0x0A84FF26),
        "UniColors.Badge.Info.foreground": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Badge.Info.stroke": Swatch(cloud: 0x007AFF4D, midnight: 0x0A84FF4D, dark: 0x0A84FF4D),
        "UniColors.Feedback.Neutral.background": Swatch(cloud: 0xE5E5EAFF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Feedback.Neutral.foreground": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Feedback.Neutral.stroke": Swatch(cloud: 0x3C3C434A, midnight: 0x54545899, dark: 0x54545899),
        "UniColors.Badge.Neutral.background": Swatch(cloud: 0xE5E5EAFF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Badge.Neutral.foreground": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Badge.Neutral.stroke": Swatch(cloud: 0x3C3C434A, midnight: 0x54545899, dark: 0x54545899),
        "UniColors.Status.successBackground": Swatch(cloud: 0x34C75926, midnight: 0x30D15826, dark: 0x30D15826),
        "UniColors.Status.successForeground": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Status.successStroke": Swatch(cloud: 0x34C7594D, midnight: 0x30D1584D, dark: 0x30D1584D),
        "UniColors.Status.warningBackground": Swatch(cloud: 0xFF950026, midnight: 0xFF9F0A26, dark: 0xFF9F0A26),
        "UniColors.Status.warningForeground": Swatch(cloud: 0xFF9500FF, midnight: 0xFF9F0AFF, dark: 0xFF9F0AFF),
        "UniColors.Status.warningStroke": Swatch(cloud: 0xFF95004D, midnight: 0xFF9F0A4D, dark: 0xFF9F0A4D),
        "UniColors.Status.errorBackground": Swatch(cloud: 0xFF3B3026, midnight: 0xFF453A26, dark: 0xFF453A26),
        "UniColors.Status.errorForeground": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Status.errorStroke": Swatch(cloud: 0xFF3B304D, midnight: 0xFF453A4D, dark: 0xFF453A4D),
        "UniColors.Status.infoBackground": Swatch(cloud: 0x007AFF26, midnight: 0x0A84FF26, dark: 0x0A84FF26),
        "UniColors.Status.infoForeground": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Status.infoStroke": Swatch(cloud: 0x007AFF4D, midnight: 0x0A84FF4D, dark: 0x0A84FF4D),
        "UniColors.Status.neutralBackground": Swatch(cloud: 0xE5E5EAFF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.Status.neutralForeground": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Status.neutralStroke": Swatch(cloud: 0x3C3C434A, midnight: 0x54545899, dark: 0x54545899),
        "UniColors.Splash.lift": Swatch(cloud: 0xFFFFFFFF, midnight: 0x211C1AFF, dark: 0x211C1AFF),
        "UniColors.Splash.base": Swatch(cloud: 0xF4F0EEFF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Splash.mark": Swatch(cloud: 0x110D0BFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Splash.glow": Swatch(cloud: 0x110D0B14, midnight: 0xFFFFFF24, dark: 0xFFFFFF24),
        "UniColors.Splash.loaderTrack": Swatch(cloud: 0x110D0B1A, midnight: 0xFFFFFF29, dark: 0xFFFFFF29),
        "UniColors.Splash.tagline": Swatch(cloud: 0x110D0B80, midnight: 0xFFFFFF80, dark: 0xFFFFFF80),
        "UniColors.Brand.mark": Swatch(cloud: 0x0B0D11FF, midnight: 0xF5F5F7FF, dark: 0xF5F5F7FF),
        "UniColors.Brand.logoDisc": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Brand.logoIris": Swatch(cloud: 0xFFFFFFFF, midnight: 0x191A1EFF, dark: 0x000000FF),
        // Fixed content on wallet-identity colour (not appearance-adaptive).
        "UniColors.WalletAvatar.contentInk": Swatch(cloud: 0x0B0D11FF, midnight: 0x0B0D11FF, dark: 0x0B0D11FF),
        "UniColors.WalletAvatar.contentCloud": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Seal.secured": Swatch(cloud: 0x179A5BFF, midnight: 0x2FD07FFF, dark: 0x2FD07FFF),
        "UniColors.Seal.watching": Swatch(cloud: 0x2F6BD6FF, midnight: 0x5A93F6FF, dark: 0x5A93F6FF),
        "UniColors.Validation.valid": Swatch(cloud: 0x34C759EB, midnight: 0x30D158EB, dark: 0x30D158EB),
        "UniColors.Validation.invalid": Swatch(cloud: 0xFF3B30EB, midnight: 0xFF453AEB, dark: 0xFF453AEB),
        "UniColors.Validation.pending": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Crypto.up": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Crypto.down": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Crypto.stable": Swatch(cloud: 0x8E8E93FF, midnight: 0x8E8E93FF, dark: 0x8E8E93FF),
        "UniColors.Crypto.stablecoin": Swatch(cloud: 0x007AFFFF, midnight: 0x0A84FFFF, dark: 0x0A84FFFF),
        "UniColors.Crypto.pending": Swatch(cloud: 0xFF9500FF, midnight: 0xFF9F0AFF, dark: 0xFF9F0AFF),
        "UniColors.Crypto.confirmed": Swatch(cloud: 0x34C759FF, midnight: 0x30D158FF, dark: 0x30D158FF),
        "UniColors.Crypto.failed": Swatch(cloud: 0xFF3B30FF, midnight: 0xFF453AFF, dark: 0xFF453AFF),
        "UniColors.Material.card": Swatch(cloud: 0xFFFFFFFF, midnight: 0x212229FF, dark: 0x1C1C1EFF),
        "UniColors.Material.elevated": Swatch(cloud: 0xF5F5F7FF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.FeatureRow.icon": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.FeatureRow.title": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.FeatureRow.detail": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.EmptyState.background": Swatch(cloud: 0xFFFFFFFF, midnight: 0x212229FF, dark: 0x1C1C1EFF),
        "UniColors.EmptyState.liftStart": Swatch(cloud: 0xFFFFFFFF, midnight: 0x211C1AFF, dark: 0x211C1AFF),
        "UniColors.EmptyState.liftEnd": Swatch(cloud: 0xF4F0EEFF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.EmptyState.title": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.EmptyState.detail": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.EmptyState.icon": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.EmptyState.logoShadow": Swatch(cloud: 0x00000014, midnight: 0x191A1E14, dark: 0x00000014),
        "UniColors.Loading.spinner": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Loading.caption": Swatch(cloud: 0x3C3C4399, midnight: 0xEBEBF599, dark: 0xEBEBF599),
        "UniColors.Loading.background": Swatch(cloud: 0xF5F5F7FF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Focus.selection": Swatch(cloud: 0x0B0D1133, midnight: 0xF5F5F733, dark: 0xF5F5F733),
        "UniColors.Focus.pressed": Swatch(cloud: 0x78788033, midnight: 0x7878805C, dark: 0x7878805C),
        "UniColors.Skeleton.base": Swatch(cloud: 0x78788029, midnight: 0x78788052, dark: 0x78788052),
        "UniColors.Skeleton.highlight": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.WalletAvatar.curated.Ink": Swatch(cloud: 0x0B0D11FF, midnight: 0x0B0D11FF, dark: 0x0B0D11FF),
        "UniColors.WalletAvatar.curated.Slate": Swatch(cloud: 0x3A3F4AFF, midnight: 0x3A3F4AFF, dark: 0x3A3F4AFF),
        "UniColors.WalletAvatar.curated.Crimson": Swatch(cloud: 0xB81F2DFF, midnight: 0xB81F2DFF, dark: 0xB81F2DFF),
        "UniColors.WalletAvatar.curated.Tangerine": Swatch(cloud: 0xE0651FFF, midnight: 0xE0651FFF, dark: 0xE0651FFF),
        "UniColors.WalletAvatar.curated.Amber": Swatch(cloud: 0xC99020FF, midnight: 0xC99020FF, dark: 0xC99020FF),
        "UniColors.WalletAvatar.curated.Olive": Swatch(cloud: 0x5F7028FF, midnight: 0x5F7028FF, dark: 0x5F7028FF),
        "UniColors.WalletAvatar.curated.Forest": Swatch(cloud: 0x2D6E48FF, midnight: 0x2D6E48FF, dark: 0x2D6E48FF),
        "UniColors.WalletAvatar.curated.Teal": Swatch(cloud: 0x1D7390FF, midnight: 0x1D7390FF, dark: 0x1D7390FF),
        "UniColors.WalletAvatar.curated.Cobalt": Swatch(cloud: 0x1F4FA8FF, midnight: 0x1F4FA8FF, dark: 0x1F4FA8FF),
        "UniColors.WalletAvatar.curated.Indigo": Swatch(cloud: 0x3F2D8AFF, midnight: 0x3F2D8AFF, dark: 0x3F2D8AFF),
        "UniColors.WalletAvatar.curated.Plum": Swatch(cloud: 0x7A2E80FF, midnight: 0x7A2E80FF, dark: 0x7A2E80FF),
        "UniColors.WalletAvatar.curated.Magenta": Swatch(cloud: 0x9C2A6CFF, midnight: 0x9C2A6CFF, dark: 0x9C2A6CFF),
        "UniColors.WalletAvatar.gradientStops.graphite.top": Swatch(cloud: 0x3A3D45FF, midnight: 0x3A3D45FF, dark: 0x3A3D45FF),
        "UniColors.WalletAvatar.gradientStops.graphite.bottom": Swatch(cloud: 0x0B0D11FF, midnight: 0x0B0D11FF, dark: 0x0B0D11FF),
        "UniColors.WalletAvatar.gradientStops.slate.top": Swatch(cloud: 0x6B7280FF, midnight: 0x6B7280FF, dark: 0x6B7280FF),
        "UniColors.WalletAvatar.gradientStops.slate.bottom": Swatch(cloud: 0x374151FF, midnight: 0x374151FF, dark: 0x374151FF),
        "UniColors.WalletAvatar.gradientStops.indigo.top": Swatch(cloud: 0x7C8CF8FF, midnight: 0x7C8CF8FF, dark: 0x7C8CF8FF),
        "UniColors.WalletAvatar.gradientStops.indigo.bottom": Swatch(cloud: 0x3B43C4FF, midnight: 0x3B43C4FF, dark: 0x3B43C4FF),
        "UniColors.WalletAvatar.gradientStops.blue.top": Swatch(cloud: 0x4DA8FFFF, midnight: 0x4DA8FFFF, dark: 0x4DA8FFFF),
        "UniColors.WalletAvatar.gradientStops.blue.bottom": Swatch(cloud: 0x1668D6FF, midnight: 0x1668D6FF, dark: 0x1668D6FF),
        "UniColors.WalletAvatar.gradientStops.sky.top": Swatch(cloud: 0x7DD3FCFF, midnight: 0x7DD3FCFF, dark: 0x7DD3FCFF),
        "UniColors.WalletAvatar.gradientStops.sky.bottom": Swatch(cloud: 0x0284C7FF, midnight: 0x0284C7FF, dark: 0x0284C7FF),
        "UniColors.WalletAvatar.gradientStops.cyan.top": Swatch(cloud: 0x67E8F9FF, midnight: 0x67E8F9FF, dark: 0x67E8F9FF),
        "UniColors.WalletAvatar.gradientStops.cyan.bottom": Swatch(cloud: 0x0891B2FF, midnight: 0x0891B2FF, dark: 0x0891B2FF),
        "UniColors.WalletAvatar.gradientStops.teal.top": Swatch(cloud: 0x3FD6C8FF, midnight: 0x3FD6C8FF, dark: 0x3FD6C8FF),
        "UniColors.WalletAvatar.gradientStops.teal.bottom": Swatch(cloud: 0x0E9C8EFF, midnight: 0x0E9C8EFF, dark: 0x0E9C8EFF),
        "UniColors.WalletAvatar.gradientStops.mint.top": Swatch(cloud: 0x6EE7B7FF, midnight: 0x6EE7B7FF, dark: 0x6EE7B7FF),
        "UniColors.WalletAvatar.gradientStops.mint.bottom": Swatch(cloud: 0x0D9488FF, midnight: 0x0D9488FF, dark: 0x0D9488FF),
        "UniColors.WalletAvatar.gradientStops.green.top": Swatch(cloud: 0x5BD98AFF, midnight: 0x5BD98AFF, dark: 0x5BD98AFF),
        "UniColors.WalletAvatar.gradientStops.green.bottom": Swatch(cloud: 0x179A5BFF, midnight: 0x179A5BFF, dark: 0x179A5BFF),
        "UniColors.WalletAvatar.gradientStops.emerald.top": Swatch(cloud: 0x34D399FF, midnight: 0x34D399FF, dark: 0x34D399FF),
        "UniColors.WalletAvatar.gradientStops.emerald.bottom": Swatch(cloud: 0x059669FF, midnight: 0x059669FF, dark: 0x059669FF),
        "UniColors.WalletAvatar.gradientStops.lime.top": Swatch(cloud: 0xB6E06AFF, midnight: 0xB6E06AFF, dark: 0xB6E06AFF),
        "UniColors.WalletAvatar.gradientStops.lime.bottom": Swatch(cloud: 0x5FAE2EFF, midnight: 0x5FAE2EFF, dark: 0x5FAE2EFF),
        "UniColors.WalletAvatar.gradientStops.amber.top": Swatch(cloud: 0xFFCB5CFF, midnight: 0xFFCB5CFF, dark: 0xFFCB5CFF),
        "UniColors.WalletAvatar.gradientStops.amber.bottom": Swatch(cloud: 0xE0991CFF, midnight: 0xE0991CFF, dark: 0xE0991CFF),
        "UniColors.WalletAvatar.gradientStops.sunflower.top": Swatch(cloud: 0xFDE047FF, midnight: 0xFDE047FF, dark: 0xFDE047FF),
        "UniColors.WalletAvatar.gradientStops.sunflower.bottom": Swatch(cloud: 0xCA8A04FF, midnight: 0xCA8A04FF, dark: 0xCA8A04FF),
        "UniColors.WalletAvatar.gradientStops.orange.top": Swatch(cloud: 0xFF9F6BFF, midnight: 0xFF9F6BFF, dark: 0xFF9F6BFF),
        "UniColors.WalletAvatar.gradientStops.orange.bottom": Swatch(cloud: 0xEF5F2CFF, midnight: 0xEF5F2CFF, dark: 0xEF5F2CFF),
        "UniColors.WalletAvatar.gradientStops.coral.top": Swatch(cloud: 0xFF8A80FF, midnight: 0xFF8A80FF, dark: 0xFF8A80FF),
        "UniColors.WalletAvatar.gradientStops.coral.bottom": Swatch(cloud: 0xE11D48FF, midnight: 0xE11D48FF, dark: 0xE11D48FF),
        "UniColors.WalletAvatar.gradientStops.red.top": Swatch(cloud: 0xFF7C72FF, midnight: 0xFF7C72FF, dark: 0xFF7C72FF),
        "UniColors.WalletAvatar.gradientStops.red.bottom": Swatch(cloud: 0xE0433DFF, midnight: 0xE0433DFF, dark: 0xE0433DFF),
        "UniColors.WalletAvatar.gradientStops.rose.top": Swatch(cloud: 0xFF8FABFF, midnight: 0xFF8FABFF, dark: 0xFF8FABFF),
        "UniColors.WalletAvatar.gradientStops.rose.bottom": Swatch(cloud: 0xE11D48FF, midnight: 0xE11D48FF, dark: 0xE11D48FF),
        "UniColors.WalletAvatar.gradientStops.pink.top": Swatch(cloud: 0xFF8FC4FF, midnight: 0xFF8FC4FF, dark: 0xFF8FC4FF),
        "UniColors.WalletAvatar.gradientStops.pink.bottom": Swatch(cloud: 0xE0489CFF, midnight: 0xE0489CFF, dark: 0xE0489CFF),
        "UniColors.WalletAvatar.gradientStops.peach.top": Swatch(cloud: 0xFDBA74FF, midnight: 0xFDBA74FF, dark: 0xFDBA74FF),
        "UniColors.WalletAvatar.gradientStops.peach.bottom": Swatch(cloud: 0xEA580CFF, midnight: 0xEA580CFF, dark: 0xEA580CFF),
        "UniColors.WalletAvatar.gradientStops.violet.top": Swatch(cloud: 0xB488FFFF, midnight: 0xB488FFFF, dark: 0xB488FFFF),
        "UniColors.WalletAvatar.gradientStops.violet.bottom": Swatch(cloud: 0x6B2BD9FF, midnight: 0x6B2BD9FF, dark: 0x6B2BD9FF),
        "UniColors.WalletAvatar.gradientStops.lavender.top": Swatch(cloud: 0xC4B5FDFF, midnight: 0xC4B5FDFF, dark: 0xC4B5FDFF),
        "UniColors.WalletAvatar.gradientStops.lavender.bottom": Swatch(cloud: 0x7C3AEDFF, midnight: 0x7C3AEDFF, dark: 0x7C3AEDFF),
        "UniColors.WalletAvatar.gradientStops.sapphire.top": Swatch(cloud: 0x60A5FAFF, midnight: 0x60A5FAFF, dark: 0x60A5FAFF),
        "UniColors.WalletAvatar.gradientStops.sapphire.bottom": Swatch(cloud: 0x1D4ED8FF, midnight: 0x1D4ED8FF, dark: 0x1D4ED8FF),
        "UniColors.WalletAvatar.gradientStops.ocean.top": Swatch(cloud: 0x22D3EEFF, midnight: 0x22D3EEFF, dark: 0x22D3EEFF),
        "UniColors.WalletAvatar.gradientStops.ocean.bottom": Swatch(cloud: 0x0369A1FF, midnight: 0x0369A1FF, dark: 0x0369A1FF),
        "UniColors.WalletAvatar.gradientStops.sunset.top": Swatch(cloud: 0xFB923CFF, midnight: 0xFB923CFF, dark: 0xFB923CFF),
        "UniColors.WalletAvatar.gradientStops.sunset.bottom": Swatch(cloud: 0xDC2626FF, midnight: 0xDC2626FF, dark: 0xDC2626FF),
        "UniColors.WalletAvatar.badgeColor.watch": Swatch(cloud: 0x2F6BD6FF, midnight: 0x2F6BD6FF, dark: 0x2F6BD6FF),
        "UniColors.WalletAvatar.badgeColor.hardware": Swatch(cloud: 0x3A3D45FF, midnight: 0x3A3D45FF, dark: 0x3A3D45FF),
        "UniColors.WalletAvatar.badgeColor.shared": Swatch(cloud: 0x179A5BFF, midnight: 0x179A5BFF, dark: 0x179A5BFF),
        "UniColors.Send.darkScreenTop": Swatch(cloud: 0x0E1015FF, midnight: 0x0E1015FF, dark: 0x0E1015FF),
        "UniColors.Send.darkScreenBottom": Swatch(cloud: 0x08090CFF, midnight: 0x08090CFF, dark: 0x08090CFF),
        "UniColors.Send.darkScreenLift": Swatch(cloud: 0x1A1D24FF, midnight: 0x1A1D24FF, dark: 0x1A1D24FF),
        "UniColors.Send.onDark": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Send.onDarkSecondary": Swatch(cloud: 0xFFFFFF99, midnight: 0xFFFFFF99, dark: 0xFFFFFF99),
        "UniColors.Send.track": Swatch(cloud: 0x0A0C10FF, midnight: 0x0A0C10FF, dark: 0x0A0C10FF),
        "UniColors.Send.trackLabel": Swatch(cloud: 0xFFFFFF99, midnight: 0xFFFFFF99, dark: 0xFFFFFF99),
        "UniColors.Send.knob": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Send.knobGlyph": Swatch(cloud: 0x0A0C10FF, midnight: 0x0A0C10FF, dark: 0x0A0C10FF),
        "UniColors.Send.knobShadow": Swatch(cloud: 0x0000004D, midnight: 0x191A1E4D, dark: 0x0000004D),
        "UniColors.Send.onAccentDisc": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Send.positive": Swatch(cloud: 0x179A5BFF, midnight: 0x179A5BFF, dark: 0x179A5BFF),
        "UniColors.Send.positiveWash": Swatch(cloud: 0x179A5B1A, midnight: 0x179A5B1A, dark: 0x179A5B1A),
        "UniColors.Send.negative": Swatch(cloud: 0xE0483DFF, midnight: 0xE0483DFF, dark: 0xE0483DFF),
        "UniColors.Send.negativeWash": Swatch(cloud: 0xE0483D1A, midnight: 0xE0483D1A, dark: 0xE0483D1A),
        "UniColors.Send.bloomBaseTop": Swatch(cloud: 0xF2F3F6FF, midnight: 0x0C0D11FF, dark: 0x0C0D11FF),
        "UniColors.Send.bloomBaseBottom": Swatch(cloud: 0xE8EAEEFF, midnight: 0x070809FF, dark: 0x070809FF),
        "UniColors.Send.bloomCool": Swatch(cloud: 0x96A5C84D, midnight: 0x96A5C84D, dark: 0x96A5C84D),
        "UniColors.Send.bloomWarm": Swatch(cloud: 0xAA96C83D, midnight: 0xAA96C83D, dark: 0xAA96C83D),
        "UniColors.Send.bloomDanger": Swatch(cloud: 0xE0483D29, midnight: 0xE0483D29, dark: 0xE0483D29),
        "UniColors.Send.cardSpecular": Swatch(cloud: 0xFFFFFFA6, midnight: 0xFFFFFF29, dark: 0xFFFFFF29),
        "UniColors.Send.cardSolidFallback": Swatch(cloud: 0xF7F8FAFF, midnight: 0x16181DFF, dark: 0x16181DFF),
        "UniColors.Send.cardHairline": Swatch(cloud: 0x3C3C434A, midnight: 0x54545899, dark: 0x54545899),
        "UniColors.Send.cardShadow": Swatch(cloud: 0x0000002E, midnight: 0x191A1E2E, dark: 0x0000002E),
        "UniColors.Send.darkGlass": Swatch(cloud: 0x101218EB, midnight: 0x101218EB, dark: 0x101218EB),
        "UniColors.Send.onDarkGlass": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Send.cameraScrim": Swatch(cloud: 0x00000073, midnight: 0x191A1E73, dark: 0x00000073),
        "UniColors.Send.cameraScrimLight": Swatch(cloud: 0x00000066, midnight: 0x191A1E66, dark: 0x00000066),
        "UniColors.Send.cameraBase": Swatch(cloud: 0x000000FF, midnight: 0x191A1EFF, dark: 0x000000FF),
        "UniColors.Send.cameraOnMediaDimIcon": Swatch(cloud: 0xFFFFFFB3, midnight: 0xFFFFFFB3, dark: 0xFFFFFFB3),
        "UniColors.Send.cameraOnMediaDimBody": Swatch(cloud: 0xFFFFFFCC, midnight: 0xFFFFFFCC, dark: 0xFFFFFFCC),
        "UniColors.Send.cameraOnMediaNote": Swatch(cloud: 0xFFFFFFE6, midnight: 0xFFFFFFE6, dark: 0xFFFFFFE6),
        "UniColors.Reset.danger": Swatch(cloud: 0xE0483DFF, midnight: 0xFF5B51FF, dark: 0xFF5B51FF),
        "UniColors.Reset.dangerWash": Swatch(cloud: 0xE0483D1A, midnight: 0xFF5B511A, dark: 0xFF5B511A),
        "UniColors.Reset.onDanger": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.PinLock.danger": Swatch(cloud: 0xE0483DFF, midnight: 0xFF5B51FF, dark: 0xFF5B51FF),
        "UniColors.PinLock.positive": Swatch(cloud: 0x179A5BFF, midnight: 0x2FD07FFF, dark: 0x2FD07FFF),
        "UniColors.PinLock.dotEmpty": Swatch(cloud: 0x0A0C1038, midnight: 0xFFFFFF4D, dark: 0xFFFFFF4D),
        "UniColors.PinLock.keyPress": Swatch(cloud: 0x0A0C101F, midnight: 0xFFFFFF2E, dark: 0xFFFFFF2E),
        "UniColors.PinLock.delete": Swatch(cloud: 0xB9BCC4FF, midnight: 0x54565EFF, dark: 0x54565EFF),
        "UniColors.SeedGrid.surface": Swatch(cloud: 0xFFFFFFFF, midnight: 0x2A2C32FF, dark: 0x2C2C2EFF),
        "UniColors.SeedGrid.faint": Swatch(cloud: 0xBCBEC5FF, midnight: 0x4A4C54FF, dark: 0x4A4C54FF),
        "UniColors.SeedGrid.hairline": Swatch(cloud: 0x0A0C100D, midnight: 0xFFFFFF12, dark: 0xFFFFFF12),
        "UniColors.BalanceCard.surfaceLift": Swatch(cloud: 0xFFFFFFFF, midnight: 0x2B2E36FF, dark: 0x2B2E36FF),
        "UniColors.BalanceCard.surfaceTop": Swatch(cloud: 0xFBFBFDFF, midnight: 0x16181DFF, dark: 0x16181DFF),
        "UniColors.BalanceCard.surfaceBottom": Swatch(cloud: 0xEFF1F5FF, midnight: 0x0A0B0EFF, dark: 0x0A0B0EFF),
        "UniColors.BalanceCard.shadow": Swatch(cloud: 0x0A0C104D, midnight: 0x191A1E80, dark: 0x00000080),
        "UniColors.BalanceCard.innerEdge": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFF0F, dark: 0xFFFFFF0F),
        "UniColors.BalanceCard.hairline": Swatch(cloud: 0x0A0C100D, midnight: 0x191A1E00, dark: 0x00000000),
        "UniColors.BalanceCard.textPrimary": Swatch(cloud: 0x0A0C10FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.BalanceCard.textMuted": Swatch(cloud: 0x8B8D94FF, midnight: 0xFFFFFF8C, dark: 0xFFFFFF8C),
        "UniColors.BalanceCard.textMuted.boostContrast": Swatch(cloud: 0x6E7079FF, midnight: 0xFFFFFFB3, dark: 0xFFFFFFB3),
        "UniColors.BalanceCard.decimals": Swatch(cloud: 0xB4B6BEFF, midnight: 0xFFFFFF59, dark: 0xFFFFFF59),
        "UniColors.BalanceCard.decimals.boostContrast": Swatch(cloud: 0x9A9CA4FF, midnight: 0xFFFFFF80, dark: 0xFFFFFF80),
        "UniColors.BalanceCard.copyAction": Swatch(cloud: 0x6E7079FF, midnight: 0xFFFFFF99, dark: 0xFFFFFF99),
        "UniColors.BalanceCard.eyeButtonFill": Swatch(cloud: 0x0A0C100D, midnight: 0xFFFFFF14, dark: 0xFFFFFF14),
        "UniColors.BalanceCard.eyeGlyph": Swatch(cloud: 0x54565EFF, midnight: 0xFFFFFFCC, dark: 0xFFFFFFCC),
        "UniColors.BalanceCard.avatarRing": Swatch(cloud: 0x0A0C1014, midnight: 0xFFFFFF1A, dark: 0xFFFFFF1A),
        "UniColors.BalanceCard.segmentTrack": Swatch(cloud: 0x0A0C100D, midnight: 0xFFFFFF12, dark: 0xFFFFFF12),
        "UniColors.BalanceCard.segmentActiveFill": Swatch(cloud: 0xFFFFFFFF, midnight: 0xFFFFFF24, dark: 0xFFFFFF24),
        "UniColors.BalanceCard.segmentActiveText": Swatch(cloud: 0x0A0C10FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.BalanceCard.segmentActiveShadow": Swatch(cloud: 0x0A0C104D, midnight: 0x191A1E00, dark: 0x00000000),
        "UniColors.BalanceCard.accent.up": Swatch(cloud: 0x179A5BFF, midnight: 0x3FE79AFF, dark: 0x3FE79AFF),
        "UniColors.BalanceCard.accent.down": Swatch(cloud: 0xE0483DFF, midnight: 0xFF7A6BFF, dark: 0xFF7A6BFF),
        "UniColors.BalanceCard.accent.flat": Swatch(cloud: 0x8B8D94FF, midnight: 0xFFFFFFA6, dark: 0xFFFFFFA6),
        "UniColors.BalanceCard.chartStroke.up": Swatch(cloud: 0x179A5BFF, midnight: 0x3FE79AFF, dark: 0x3FE79AFF),
        "UniColors.BalanceCard.chartStroke.down": Swatch(cloud: 0xE0483DFF, midnight: 0xFF7A6BFF, dark: 0xFF7A6BFF),
        "UniColors.BalanceCard.chartStroke.flat": Swatch(cloud: 0x0A0C1066, midnight: 0xFFFFFF73, dark: 0xFFFFFF73),
        "UniColors.BalanceCard.chartFillHue.up": Swatch(cloud: 0x179A5BFF, midnight: 0x3FE79AFF, dark: 0x3FE79AFF),
        "UniColors.BalanceCard.chartFillHue.down": Swatch(cloud: 0xE0483DFF, midnight: 0xFF7A6BFF, dark: 0xFF7A6BFF),
        "UniColors.BalanceCard.chartFillHue.flat": Swatch(cloud: 0x0A0C10FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.BalanceCard.pillBackground.up": Swatch(cloud: 0x179A5B1F, midnight: 0x2DE08C29, dark: 0x2DE08C29),
        "UniColors.BalanceCard.pillBackground.down": Swatch(cloud: 0xE0483D1A, midnight: 0xFF7A6B29, dark: 0xFF7A6B29),
        "UniColors.BalanceCard.pillBackground.flat": Swatch(cloud: 0x0A0C100F, midnight: 0xFFFFFF1A, dark: 0xFFFFFF1A),
        "UniColors.BalanceCard.fundButtonFill": Swatch(cloud: 0x0A0C10FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.BalanceCard.fundButtonLabel": Swatch(cloud: 0xFFFFFFFF, midnight: 0x0A0C10FF, dark: 0x0A0C10FF),
        "UniColors.BalanceCard.scrubCursor.up": Swatch(cloud: 0x179A5BFF, midnight: 0x3FE79AFF, dark: 0x3FE79AFF),
        "UniColors.BalanceCard.scrubCursor.down": Swatch(cloud: 0xE0483DFF, midnight: 0xFF7A6BFF, dark: 0xFF7A6BFF),
        "UniColors.BalanceCard.scrubCursor.flat": Swatch(cloud: 0x0A0C1066, midnight: 0xFFFFFF73, dark: 0xFFFFFF73),
        "UniColors.Illustration.primaryLine": Swatch(cloud: 0x000000FF, midnight: 0xFFFFFFFF, dark: 0xFFFFFFFF),
        "UniColors.Illustration.secondaryLine": Swatch(cloud: 0x3C3C434D, midnight: 0xEBEBF54D, dark: 0xEBEBF54D),
        "UniColors.Illustration.tertiaryLine": Swatch(cloud: 0x3C3C432E, midnight: 0xEBEBF52E, dark: 0xEBEBF52E),
        "UniColors.Illustration.surface": Swatch(cloud: 0x78788029, midnight: 0x78788052, dark: 0x78788052),
        "UniColors.Illustration.surfaceDeep": Swatch(cloud: 0x7676801F, midnight: 0x7676803D, dark: 0x7676803D),
        "UniColors.Illustration.accentFill": Swatch(cloud: 0x0B0D11FF, midnight: 0xF5F5F7FF, dark: 0xF5F5F7FF),
        "UniColors.Illustration.accentMuted": Swatch(cloud: 0x0B0D114D, midnight: 0xF5F5F74D, dark: 0xF5F5F74D),
    ]
}
