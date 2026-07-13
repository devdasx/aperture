import SwiftUI
import Testing
import UIKit
@testable import Aperture

@Suite("Three-mode color system")
struct UniColorPaletteTests {
    @Test("Handoff publishes every semantic color")
    func completeTokenCount() {
        #expect(UniColorPalette.tokenCount == 381)
    }

    @Test("Core elevation ladder matches the handoff")
    func elevationLadder() {
        #expect(UniColorPalette.rgbaHex(for: "UniColors.Page.background", appearance: .cloud) == 0xF5F5F7FF)
        #expect(UniColorPalette.rgbaHex(for: "UniColors.Page.background", appearance: .midnight) == 0x191A1EFF)
        #expect(UniColorPalette.rgbaHex(for: "UniColors.Page.background", appearance: .dark) == 0x000000FF)

        #expect(UniColorPalette.rgbaHex(for: "UniColors.Card.background", appearance: .cloud) == 0xFFFFFFFF)
        #expect(UniColorPalette.rgbaHex(for: "UniColors.Card.background", appearance: .midnight) == 0x212229FF)
        #expect(UniColorPalette.rgbaHex(for: "UniColors.Card.background", appearance: .dark) == 0x1C1C1EFF)
    }

    @Test("Stored Light preference migrates to Cloud")
    func legacyLightMigration() {
        #expect(ThemePreference.stored("light") == .cloud)
        #expect(ThemePreference.stored("midnight") == .midnight)
        #expect(ThemePreference.stored("dark") == .dark)
    }

    @Test("Dynamic colors distinguish Midnight from Dark")
    @MainActor
    func dynamicAppearanceTrait() {
        let color = UniColorPalette.uiColor("UniColors.Page.background")
        let previous = ApertureAppearanceResolution.current
        defer { ApertureAppearanceResolution.current = previous }

        let systemDark = UITraitCollection(userInterfaceStyle: .dark)
        let systemLight = UITraitCollection(userInterfaceStyle: .light)

        // System preference: light → Cloud, dark → Midnight.
        ApertureAppearanceResolution.current = .system
        #expect(rgba(color.resolvedColor(with: systemDark)) == 0x191A1EFF)
        #expect(rgba(color.resolvedColor(with: systemLight)) == 0xF5F5F7FF)

        // Explicit Cloud / Midnight / Dark via the app-published preference
        // (the path `.apertureEnvironment()` drives at runtime). This is the
        // authoritative discriminator when both Midnight and Dark force
        // system dark interface style.
        ApertureAppearanceResolution.current = .cloud
        #expect(rgba(color.resolvedColor(with: systemDark)) == 0xF5F5F7FF)
        ApertureAppearanceResolution.current = .midnight
        #expect(rgba(color.resolvedColor(with: systemDark)) == 0x191A1EFF)
        ApertureAppearanceResolution.current = .dark
        #expect(rgba(color.resolvedColor(with: systemDark)) == 0x000000FF)
    }

    @MainActor
    private func rgba(_ color: UIColor) -> UInt32 {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let channel: (CGFloat) -> UInt32 = {
            UInt32((max(0, min(1, $0)) * 255).rounded())
        }
        return channel(red) << 24
            | channel(green) << 16
            | channel(blue) << 8
            | channel(alpha)
    }
}
