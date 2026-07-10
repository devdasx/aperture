import SwiftUI

/// Picker for System plus the three Aperture appearances: Cloud, Midnight,
/// and true-black Dark.
///
/// Selection writes through `@GRDBStorage("themePreference")`, which
/// `UniAppApp` reads and binds to `.preferredColorScheme(_:)`. Implements T-006.
struct AppearancePickerView: View {
    @GRDBStorage("themePreference") private var themeRaw: String = ThemePreference.defaultRaw

    private var current: ThemePreference {
        ThemePreference.stored(themeRaw)
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
                        .uniListRowHitTarget()
                    }
                    .buttonStyle(.uniListRow)
                    .accessibilityAddTraits(current == option ? [.isSelected, .isButton] : .isButton)
                    .listRowBackground(UniColors.List.rowBackground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Choose appearance"))
        .navigationBarTitleDisplayMode(.large)
        .uniHaptic(.selection, trigger: themeRaw)
    }
}

#Preview("Cloud") {
    NavigationStack {
        AppearancePickerView()
    }
    .preferredColorScheme(.light)
    .environment(\.apertureAppearance, .cloud)
}

#Preview("Midnight") {
    NavigationStack {
        AppearancePickerView()
    }
    .preferredColorScheme(.dark)
    .environment(\.apertureAppearance, .midnight)
}

#Preview("Dark") {
    NavigationStack {
        AppearancePickerView()
    }
    .preferredColorScheme(.dark)
    .environment(\.apertureAppearance, .dark)
}
