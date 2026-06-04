import SwiftUI

/// Settings screen — presented as a `.sheet(...)` from the onboarding app
/// bar (gear icon). Four sections by design, top to bottom:
///
///   1. **Language** — picks one of 20 supported languages (or System).
///   2. **Appearance** — Light / Dark / System (T-006).
///   3. **Haptic feedback** — Rule #10 toggle (in section 1, after appearance).
///   4. **Currency** — fiat-display preference (20 fiats, Coinbase-backed).
///   5. **About** — app version, Terms, Privacy, design attribution.
///
/// Layered honestly: the sheet itself carries the system Liquid Glass
/// chrome; the `List` rows inside are opaque content (Rule #2 §B.3 — max
/// two glass layers in a region). System `insetGrouped` style gives the
/// native iOS 26 Settings feel without inventing chrome.
///
/// All visible strings flow through `LocalizedStringKey` and the String
/// Catalog (Rule #9). Language switching uses the iOS-level locale we
/// override at the app root in `UniAppApp.swift`; it propagates here for
/// free via the SwiftUI environment.
/// Destinations the Settings sheet can push. Encoded as a value enum so
/// the navigation path can be hoisted to the presenter (`OnboardingView`)
/// and preserved across sheet content rebuilds (Rule #12 §G).
enum SettingsDestination: Hashable, Codable {
    case language
    case appearance
    case currency
    case about
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Hoisted navigation path. Lives on `OnboardingView` so that when
    /// the sheet's content tree is rebuilt (on a layout-direction flip),
    /// the path survives the rebuild and the rebuilt `NavigationStack`
    /// reconstructs the same destination — the user stays on the picker
    /// they were inside, no matter the trigger.
    @Binding var navigationPath: NavigationPath

    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.light.rawValue
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @AppStorage(HapticPreference.storageKey) private var hapticEnabled: Bool = HapticPreference.defaultValue
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    private var theme: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .light
    }

    /// User-visible label for the language row — the *native* name of the
    /// currently selected language, or the localized "System" sentinel.
    private var languageRowTrailing: LocalizedStringKey {
        if languageCode == LanguagePreference.systemCode {
            return "System"
        }
        // SupportedLanguage.nativeName is a runtime String; wrap it so the
        // row's trailing label still flows through `LocalizedStringKey`'s
        // formatting (the value itself is the language's own self-name —
        // not localized further, since the string IS the localization).
        let native = LanguagePreference.language(for: languageCode)?.nativeName ?? "System"
        return LocalizedStringKey(native)
    }

    /// Trailing label for the Currency row — `<symbol> · <code>`. The symbol
    /// (`$`, `€`, `¥`, …) is a glyph, not localized; the code (`USD`, `EUR`)
    /// is an ISO-4217 string, also not localized. We wrap as `LocalizedStringKey`
    /// to satisfy `SettingsRow`'s API; the value passes through verbatim.
    private var currencyRowTrailing: LocalizedStringKey {
        let currency = CurrencyPreference.currency(for: currencyCode)
            ?? CurrencyPreference.all[0]
        return LocalizedStringKey("\(currency.symbol) · \(currency.code)")
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    NavigationLink(value: SettingsDestination.language) {
                        SettingsRow(
                            systemImage: "globe",
                            title: "Language",
                            trailing: languageRowTrailing
                        )
                    }

                    NavigationLink(value: SettingsDestination.appearance) {
                        SettingsRow(
                            systemImage: "circle.lefthalf.filled",
                            title: "Appearance",
                            trailing: theme.label
                        )
                    }

                    HapticToggleRow(isOn: $hapticEnabled)
                }

                Section {
                    NavigationLink(value: SettingsDestination.currency) {
                        SettingsRow(
                            systemImage: "dollarsign.circle",
                            title: "Currency",
                            trailing: currencyRowTrailing
                        )
                    }
                }

                Section {
                    NavigationLink(value: SettingsDestination.about) {
                        SettingsRow(
                            systemImage: "info.circle",
                            title: "About",
                            trailing: LocalizedStringKey(AboutInfo.versionString)
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .language:    LanguagePickerView()
                case .appearance:  AppearancePickerView()
                case .currency:    CurrencyPickerView()
                case .about:       AboutView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    UniButton(title: "Done", variant: .tertiary) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Row primitive (Settings-local, not a design-system component)

/// Local List-row composition for Settings — leading SF Symbol + title +
/// trailing detail. Not promoted to the design-system because it is
/// specific to `List` rows (NavigationLink supplies the trailing chevron;
/// promoting it would couple the system to NavigationStack).
private struct SettingsRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let trailing: LocalizedStringKey

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)

            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)

            Spacer()

            Text(trailing)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}

// MARK: - About

/// Read-only About screen — Version, Terms, Privacy, design attribution.
private struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("Version")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer()
                    // App version is data, not copy — render verbatim so it
                    // does not try to localize through the catalog.
                    Text(verbatim: AboutInfo.versionString)
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                .padding(.vertical, UniSpacing.xxs)

                // Provenance line — token prices in Aperture come from
                // Coinbase's public spot endpoint. Restrained, single line,
                // tertiary text. Honesty over decoration (Rule #2 §A.3).
                HStack {
                    Text("Prices")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer()
                    Text(verbatim: "Coinbase")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                .padding(.vertical, UniSpacing.xxs)
            }

            Section {
                Button {
                    // TODO: (T-004) present Terms of Service
                } label: {
                    HStack {
                        Text("Terms")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(UniColors.Icon.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    // TODO: (T-005) present Privacy Policy
                } label: {
                    HStack {
                        Text("Privacy")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(UniColors.Icon.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                Text("Made with Liquid Glass")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, UniSpacing.s)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("About"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - AboutInfo (bundle metadata helper)

/// Bundle-version helper. Kept fileprivate so future agents looking for a
/// reusable BundleInfo type promote it to the design-system intentionally
/// rather than discovering an accidental dependency.
private enum AboutInfo {
    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

// MARK: - Haptic toggle row

/// Row primitive for the haptic-feedback preference. Native SwiftUI `Toggle`
/// over an `@AppStorage`-bound `Bool`, dressed in the same leading-icon +
/// title shape as the other Settings rows.
///
/// Per `CLAUDE.md` Rule #10 Part C, the storage default is `true`. The
/// `.uniHaptic(.selection, trigger: isOn)` modifier provides on-flip
/// confirmation: when the user turns the toggle ON, the modifier reads
/// the freshly-updated preference (now `true`) and fires one selection
/// beat — the user feels the change at the moment it lands. When the
/// toggle is flipped OFF, the modifier reads the preference as `false`
/// and short-circuits to silent — which is itself the correct feedback
/// (the absence of a tap is what "haptics off" should feel like).
private struct HapticToggleRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)

                Text("Haptic feedback")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .tint(UniColors.Button.primaryTint)
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: isOn)
    }
}

// MARK: - Previews

#Preview("Light") {
    SettingsView(navigationPath: .constant(NavigationPath()))
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SettingsView(navigationPath: .constant(NavigationPath()))
        .preferredColorScheme(.dark)
}
