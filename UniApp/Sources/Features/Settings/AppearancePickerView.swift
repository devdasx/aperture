import SwiftUI

/// Picker for the three `ThemePreference` options — System, Light, Dark.
///
/// Selection writes through `@AppStorage("themePreference")`, which
/// `UniAppApp` reads and binds to `.preferredColorScheme(_:)`. The
/// switch is animated by SwiftUI's native appearance transition — no
/// hand-rolled motion. Implements T-006.
struct AppearancePickerView: View {
    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.light.rawValue

    private var current: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .light
    }

    var body: some View {
        List {
            Section {
                ForEach(ThemePreference.allCases) { option in
                    Button {
                        themeRaw = option.rawValue
                    } label: {
                        HStack(spacing: UniSpacing.s) {
                            Image(systemName: option.symbolName)
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(UniColors.Icon.secondary)
                                .frame(width: 28, alignment: .center)
                                .accessibilityHidden(true)

                            Text(option.label)
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Text.primary)

                            Spacer()

                            if current == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(UniColors.Icon.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, UniSpacing.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current == option ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("Choose appearance"))
        .navigationBarTitleDisplayMode(.inline)
        // Rule #10: every preference change fires one selection beat.
        .uniHaptic(.selection, trigger: themeRaw)
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        AppearancePickerView()
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        AppearancePickerView()
    }
    .preferredColorScheme(.dark)
}
