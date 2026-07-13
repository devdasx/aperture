import SwiftUI

/// Curated wallet identity colours. Each case is a vertical gradient
/// (top → bottom). Keys persist in `WalletRecord.avatarGradient`.
///
/// **Picker vs stored.** `pickerCases` excludes neutral monochrome
/// (graphite / slate — black & grey). Those cases remain so existing
/// wallets that already chose them still hydrate. Create / import use
/// `randomAssignable` (chromatic only).
enum WalletAvatarGradient: String, Hashable, Sendable, Codable, CaseIterable {
    // Neutrals — not shown in the icon picker; kept for legacy rows.
    case graphite
    case slate
    // Chromatic set (picker + auto-assign).
    case indigo
    case blue
    case sky
    case cyan
    case teal
    case mint
    case green
    case emerald
    case lime
    case amber
    case sunflower
    case orange
    case coral
    case red
    case rose
    case pink
    case peach
    case violet
    case lavender
    case sapphire
    case ocean
    case sunset

    /// Black / grey identities — valid if already stored, never offered
    /// in the picker or create/import random pool.
    var isNeutralMonochrome: Bool {
        switch self {
        case .graphite, .slate: return true
        default: return false
        }
    }

    /// Single chromatic identity pool: icon-picker list **and**
    /// create / import random assignment. Excludes graphite / slate
    /// (black & grey). Adding a case here automatically feeds both
    /// surfaces once it is non-monochrome.
    static var chromaticCases: [WalletAvatarGradient] {
        allCases.filter { !$0.isNeutralMonochrome }
    }

    /// Colours shown in Wallet icon picker (named list).
    static var pickerCases: [WalletAvatarGradient] { chromaticCases }

    /// Pool for create / import random colour — same as the picker.
    static var randomAssignable: [WalletAvatarGradient] { chromaticCases }

    /// Human-readable name for the picker list.
    var displayName: LocalizedStringKey {
        switch self {
        case .graphite:  return "Graphite"
        case .slate:     return "Slate"
        case .indigo:    return "Indigo"
        case .blue:      return "Blue"
        case .sky:       return "Sky"
        case .cyan:      return "Cyan"
        case .teal:      return "Teal"
        case .mint:      return "Mint"
        case .green:     return "Green"
        case .emerald:   return "Emerald"
        case .lime:      return "Lime"
        case .amber:     return "Amber"
        case .sunflower: return "Sunflower"
        case .orange:    return "Orange"
        case .coral:     return "Coral"
        case .red:       return "Red"
        case .rose:      return "Rose"
        case .pink:      return "Pink"
        case .peach:     return "Peach"
        case .violet:    return "Violet"
        case .lavender:  return "Lavender"
        case .sapphire:  return "Sapphire"
        case .ocean:     return "Ocean"
        case .sunset:    return "Sunset"
        }
    }

    /// Short design note under the colour name in the picker.
    var displayDetail: LocalizedStringKey {
        switch self {
        case .graphite:  return "Deep monochrome ink"
        case .slate:     return "Soft cool grey"
        case .indigo:    return "Soft violet-blue"
        case .blue:      return "Clear sky blue"
        case .sky:       return "Light open air"
        case .cyan:      return "Bright aqua"
        case .teal:      return "Balanced blue-green"
        case .mint:      return "Fresh cool green"
        case .green:     return "Living spring green"
        case .emerald:   return "Rich jewel green"
        case .lime:      return "Bright citrus"
        case .amber:     return "Warm golden honey"
        case .sunflower: return "Sunny yellow"
        case .orange:    return "Warm sunset orange"
        case .coral:     return "Soft living coral"
        case .red:       return "Clear energetic red"
        case .rose:      return "Soft pink-red"
        case .pink:      return "Bright blossom"
        case .peach:     return "Soft warm peach"
        case .violet:    return "Deep purple"
        case .lavender:  return "Light purple haze"
        case .sapphire:  return "Deep gemstone blue"
        case .ocean:     return "Sea to sky blend"
        case .sunset:    return "Warm evening glow"
        }
    }

    /// Top hex of the vertical gradient (`#RRGGBB`).
    var topHex: String {
        switch self {
        case .graphite:  return "#3A3D45"
        case .slate:     return "#6B7280"
        case .indigo:    return "#7C8CF8"
        case .blue:      return "#4DA8FF"
        case .sky:       return "#7DD3FC"
        case .cyan:      return "#67E8F9"
        case .teal:      return "#3FD6C8"
        case .mint:      return "#6EE7B7"
        case .green:     return "#5BD98A"
        case .emerald:   return "#34D399"
        case .lime:      return "#B6E06A"
        case .amber:     return "#FFCB5C"
        case .sunflower: return "#FDE047"
        case .orange:    return "#FF9F6B"
        case .coral:     return "#FF8A80"
        case .red:       return "#FF7C72"
        case .rose:      return "#FF8FAB"
        case .pink:      return "#FF8FC4"
        case .peach:     return "#FDBA74"
        case .violet:    return "#B488FF"
        case .lavender:  return "#C4B5FD"
        case .sapphire:  return "#60A5FA"
        case .ocean:     return "#22D3EE"
        case .sunset:    return "#FB923C"
        }
    }

    /// Bottom hex of the vertical gradient (`#RRGGBB`).
    var bottomHex: String {
        switch self {
        case .graphite:  return "#0B0D11"
        case .slate:     return "#374151"
        case .indigo:    return "#3B43C4"
        case .blue:      return "#1668D6"
        case .sky:       return "#0284C7"
        case .cyan:      return "#0891B2"
        case .teal:      return "#0E9C8E"
        case .mint:      return "#0D9488"
        case .green:     return "#179A5B"
        case .emerald:   return "#059669"
        case .lime:      return "#5FAE2E"
        case .amber:     return "#E0991C"
        case .sunflower: return "#CA8A04"
        case .orange:    return "#EF5F2C"
        case .coral:     return "#E11D48"
        case .red:       return "#E0433D"
        case .rose:      return "#E11D48"
        case .pink:      return "#E0489C"
        case .peach:     return "#EA580C"
        case .violet:    return "#6B2BD9"
        case .lavender:  return "#7C3AED"
        case .sapphire:  return "#1D4ED8"
        case .ocean:     return "#0369A1"
        case .sunset:    return "#DC2626"
        }
    }
}
