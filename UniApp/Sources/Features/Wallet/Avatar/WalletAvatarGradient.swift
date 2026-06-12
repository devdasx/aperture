import SwiftUI

/// The 12 curated gradients from the 2026-06-09 wallet-avatar design
/// handoff (`tokens.json`). Each gradient has a top color and a bottom
/// color; the disc fills with a vertical linear gradient between them.
/// The keys are the raw values that persist in `WalletRecord.avatarGradient`.
///
/// **Why a curated 12, not a free color picker.** Per Rule #2 §A.6
/// (*"Less, but better"*) and the design handoff's hard rule #2:
/// *"Use the 12 curated gradients and 20 glyphs from tokens.json — do
/// not invent new colors."* A user picking from a calibrated set lands
/// at a tasteful identity within seconds; a free RGB / HSB wheel lets
/// them ship a neon-on-white identity that reads as a UI bug in every
/// other surface of the app. The 12 hues here are calm, premium, and
/// distinct — graphite anchor at one end, full chromatic walk through
/// the spectrum on the other, no two adjacent entries reading as
/// duplicates.
///
/// **Why the gradients live on this enum and not in `UniColors`.**
/// Rule #4 says "every color reference resolves to a role in
/// `UniColors`." It also says `UniColors.swift` is the *only* file
/// that may construct `Color` from hex / RGB. The gradient values
/// here are the user's identity choices, not brand-class semantic
/// roles. So we expose them through `UniColors.WalletAvatar.gradient(_:)`
/// (a typed function that resolves a `WalletAvatarGradient` case to
/// a pair of SwiftUI Colors), and we route the actual hex-to-Color
/// resolution through `UniColors.swift` — the single Rule #4
/// exception file. This file holds the keys and the hex constants;
/// `UniColors.swift` holds the resolver.
enum WalletAvatarGradient: String, Hashable, Sendable, Codable, CaseIterable {
    case graphite
    case slate
    case indigo
    case blue
    case teal
    case green
    case lime
    case amber
    case orange
    case red
    case pink
    case violet

    /// Top hex of the vertical gradient (`#RRGGBB`). Per tokens.json.
    var topHex: String {
        switch self {
        case .graphite: return "#3A3D45"
        case .slate:    return "#6B7280"
        case .indigo:   return "#7C8CF8"
        case .blue:     return "#4DA8FF"
        case .teal:     return "#3FD6C8"
        case .green:    return "#5BD98A"
        case .lime:     return "#B6E06A"
        case .amber:    return "#FFCB5C"
        case .orange:   return "#FF9F6B"
        case .red:      return "#FF7C72"
        case .pink:     return "#FF8FC4"
        case .violet:   return "#B488FF"
        }
    }

    /// Bottom hex of the vertical gradient (`#RRGGBB`). Per tokens.json.
    var bottomHex: String {
        switch self {
        case .graphite: return "#0B0D11"
        case .slate:    return "#374151"
        case .indigo:   return "#3B43C4"
        case .blue:     return "#1668D6"
        case .teal:     return "#0E9C8E"
        case .green:    return "#179A5B"
        case .lime:     return "#5FAE2E"
        case .amber:    return "#E0991C"
        case .orange:   return "#EF5F2C"
        case .red:      return "#E0433D"
        case .pink:     return "#E0489C"
        case .violet:   return "#6B2BD9"
        }
    }
}
