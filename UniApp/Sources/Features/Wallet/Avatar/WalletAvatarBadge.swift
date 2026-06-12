import SwiftUI

/// The optional type badge that sits in the bottom-right corner of a
/// wallet avatar. Per the design handoff's hard rule #4:
///
/// > "The type badge (watch / hardware / shared) is DERIVED from wallet
/// > type (WalletRecord.kind), NOT user-selectable."
///
/// The three cases here map 1:1 with the three persistent wallet kinds
/// that carry a distinguishing identity beyond "this is a wallet":
///
/// | Badge       | Derived from                  | Glyph    | Inner color |
/// |-------------|-------------------------------|----------|-------------|
/// | `.watch`    | `WalletKind.watchOnly`        | eye       | `#2F6BD6`   |
/// | `.hardware` | `WalletKind.importedKey`      | chip      | `#3A3D45`   |
/// | `.shared`   | (future: multisig / shared)   | people    | `#179A5B`   |
///
/// `.created` and `.importedMnemonic` carry no badge — they're the
/// "ordinary" self-custody case and the avatar disc is the entire
/// identity. The badge surfaces meaning ONLY when there's meaning to
/// surface (a watch-only's read-only constraint; an imported single
/// key's external origin; a future shared wallet's multi-party
/// nature).
///
/// **Composition (matches the design handoff JS engine — port of the
/// `BADGES` object in `aperture-wallet-avatars.js`).** The badge
/// renders at the bottom-right corner translated to `(64, 64)` in the
/// 100-pt avatar viewBox:
/// 1. White outer ring — `Circle r=17`.
/// 2. Colored inner disc — `Circle r=14`, fill = the badge's color.
/// 3. White inner glyph — SF Symbol scaled to the inner disc.
///
/// The white outer ring separates the badge from the gradient disc
/// behind it; on a graphite avatar with a graphite-hex hardware badge,
/// the ring is what makes the badge readable rather than blending in.
///
/// **Why SF Symbols for the inner glyphs and not the JS port's
/// hand-built SVG paths.** The JS engine's `eye / chip / people` paths
/// are bespoke SVG approximating common iconography. iOS has the
/// canonical versions of all three (`eye.fill`, `cpu.fill`,
/// `person.2.fill`) shipped as SF Symbols — real Apple-designed
/// glyphs, optimal at every size, automatically tinted, automatically
/// accessible. Rule #7 §B priority 1 names SF Symbols as the first
/// choice "anywhere SF Symbols covers the need." The badge inner
/// glyph is exactly that case.
enum WalletAvatarBadge: String, Hashable, Sendable, Codable, CaseIterable {
    /// Watch-only wallet (`WalletKind.watchOnly`). Eye glyph; blue inner.
    case watch
    /// Imported from a single private key (`WalletKind.importedKey`).
    /// Chip glyph; graphite inner. The "hardware" label preserves
    /// design-handoff parity (the JS engine names it `hardware`);
    /// it covers single-key imports today and will cover real
    /// hardware-wallet imports when that ships (T-061).
    case hardware
    /// Shared / multisig wallet (future). People glyph; green inner.
    case shared

    /// Inner disc color for the badge. Per tokens.json + the design
    /// handoff: watch `#2F6BD6`, hardware `#3A3D45`, shared `#179A5B`.
    fileprivate var innerHex: String {
        switch self {
        case .watch:    return "#2F6BD6"
        case .hardware: return "#3A3D45"
        case .shared:   return "#179A5B"
        }
    }

    /// SF Symbol for the inner glyph. Hard rule #1 of the design
    /// handoff: "never clip-art, emoji, or photos" — we use Apple's
    /// canonical symbols, not the JS prototype's hand-built SVG
    /// approximations.
    fileprivate var systemImage: String {
        switch self {
        case .watch:    return "eye.fill"
        case .hardware: return "cpu.fill"
        case .shared:   return "person.2.fill"
        }
    }

    /// Derives the badge from a `WalletKind`. Per hard rule #4 — the
    /// badge is read-only from the kind, never user-pickable. This is
    /// the single source of truth for that derivation.
    static func derive(from kind: WalletKind) -> WalletAvatarBadge? {
        switch kind {
        case .created:          return nil
        case .importedMnemonic: return nil
        case .importedKey:      return .hardware
        case .watchOnly:        return .watch
        }
    }
}

// MARK: - Corner overlay view

/// Renders a `WalletAvatarBadge` as the bottom-right corner overlay on
/// a `WalletAvatar`. Composed as three concentric layers (white ring +
/// colored inner disc + white SF Symbol) matching the JS engine's
/// `BADGES` composition. The badge size scales with the parent avatar
/// diameter so it reads correctly at every wallet-identity surface
/// (tab-icon 28pt all the way to hero 120pt).
///
/// **Sizing.** The JS engine renders the badge at `Circle r=17` (white
/// ring) and `Circle r=14` (colored inner) inside the 100-pt viewBox,
/// translated to `(64, 64)` — so the badge's outer diameter is 34pt
/// and its inner diameter is 28pt, both in viewBox units. At the
/// renderer's actual draw size we multiply by `size / 100` so the
/// badge tracks the avatar.
struct WalletAvatarBadgeOverlay: View {
    let badge: WalletAvatarBadge
    /// Outer diameter of the parent avatar. The badge sizes relative
    /// to this so it stays proportional across all `WalletAvatar.Size`
    /// values.
    let avatarDiameter: CGFloat

    /// White outer-ring diameter in points at the requested avatar
    /// size. The JS engine's 34/100 ratio.
    private var outerDiameter: CGFloat { avatarDiameter * 0.34 }
    /// Colored inner-disc diameter. The JS engine's 28/100 ratio.
    private var innerDiameter: CGFloat { avatarDiameter * 0.28 }
    /// Inner SF Symbol point size. Calibrated empirically to read
    /// inside the 28/100 inner disc — ~0.16x the avatar diameter
    /// gives a glyph that fills ~60% of the inner disc, which is
    /// the same ratio iOS uses for the canonical Badge views.
    private var glyphPointSize: CGFloat { max(8, avatarDiameter * 0.16) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: outerDiameter, height: outerDiameter)
            Circle()
                .fill(UniColors.WalletAvatar.badgeColor(for: badge))
                .frame(width: innerDiameter, height: innerDiameter)
            Image(systemName: badge.systemImage)
                .font(.system(size: glyphPointSize, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - UniColors-routed badge color resolver
//
// The badge inner-color hexes are routed through `UniColors`
// (`badgeColor(for:)`) so Rule #4 §B holds — the file that constructs
// `Color` from hex is `UniColors.swift` alone. The resolver lives
// alongside the rest of the WalletAvatar palette resolvers there.
