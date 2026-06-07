import SwiftUI

/// Pre-wallet Settings sheet — the slim Settings surface presented from
/// the onboarding gear icon. Carries ONLY the rows that make sense
/// before the user has created or imported a wallet: language,
/// appearance, currency, haptic feedback, help & support, about,
/// acknowledgments.
///
/// **Why a separate view (and not a flag on `SettingsView`).** Per
/// Rule #2 §A.2 ("simplicity through reduction"), feature flags on a
/// shared view lead to drift — the post-wallet sections (Wallets,
/// Security, Privacy, Hide-balance toggles, Advanced) reference state
/// that doesn't exist pre-wallet (no `WalletRecord`, no PIN,
/// nothing to refresh or reset). A separate view names the contract
/// honestly: this is the *pre-wallet* Settings.
///
/// **Pushed picker destinations are reused** — `LanguagePickerView`,
/// `AppearancePickerView`, `CurrencyPickerView`, `HelpAndSupportView`,
/// `AcknowledgmentsView` are the same screens the full `SettingsView`
/// uses. Their behavior is identical; only the parent list differs.
struct OnboardingSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Hoisted navigation path. Lives on `OnboardingView` so the path
    /// survives sheet-content rebuilds on RTL/LTR direction flips
    /// (Rule #12 §G).
    @Binding var navigationPath: NavigationPath

    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.defaultRaw
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @AppStorage(HapticPreference.storageKey) private var hapticEnabled: Bool = HapticPreference.defaultValue
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    @State private var isShowingTerms: Bool = false
    @State private var isShowingPrivacyPolicy: Bool = false

    private var theme: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .system
    }

    private var languageRowTrailing: LocalizedStringKey {
        if languageCode == LanguagePreference.systemCode {
            return "System"
        }
        let native = LanguagePreference.language(for: languageCode)?.nativeName ?? "System"
        return LocalizedStringKey(native)
    }

    private var currencyRowTrailing: LocalizedStringKey {
        let currency = CurrencyPreference.currency(for: currencyCode)
            ?? CurrencyPreference.all[0]
        return LocalizedStringKey("\(currency.symbol) · \(currency.code)")
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                // Preferences — what the user can set up before
                // creating a wallet. Currency is included because
                // pre-selecting it now means the future wallet-home
                // hero balance renders correctly the moment a wallet
                // is created — no scramble back to Settings later.
                Section {
                    NavigationLink(value: OnboardingSettingsDestination.language) {
                        OnboardingSettingsRow(
                            systemImage: "globe",
                            title: "Language",
                            trailing: languageRowTrailing
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: OnboardingSettingsDestination.appearance) {
                        OnboardingSettingsRow(
                            systemImage: "circle.lefthalf.filled",
                            title: "Appearance",
                            trailing: theme.label
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: OnboardingSettingsDestination.currency) {
                        OnboardingSettingsRow(
                            systemImage: "dollarsign.circle",
                            title: "Currency",
                            trailing: currencyRowTrailing
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    OnboardingHapticToggleRow(isOn: $hapticEnabled)
                        .listRowBackground(UniColors.Background.secondary)
                }

                // Help & About — external links and version surface
                // are useful pre-wallet too (user might want to read
                // the docs or check the open-source repo before
                // trusting the app with their keys).
                Section {
                    NavigationLink(value: OnboardingSettingsDestination.help) {
                        OnboardingSettingsRow(
                            systemImage: "questionmark.circle",
                            title: "Help & Support",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: OnboardingSettingsDestination.about) {
                        OnboardingSettingsRow(
                            systemImage: "info.circle",
                            title: "About",
                            trailing: LocalizedStringKey(AboutInfo.versionString)
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: OnboardingSettingsDestination.acknowledgments) {
                        OnboardingSettingsRow(
                            systemImage: "text.book.closed",
                            title: "Acknowledgments",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: OnboardingSettingsDestination.self) { destination in
                switch destination {
                case .language:        LanguagePickerView()
                case .appearance:      AppearancePickerView()
                case .currency:        CurrencyPickerView()
                case .help:            HelpAndSupportView()
                case .about:           OnboardingAboutView(
                                          onTapTerms: { isShowingTerms = true },
                                          onTapPrivacy: { isShowingPrivacyPolicy = true }
                                       )
                case .acknowledgments: AcknowledgmentsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $isShowingTerms) {
                TermsPlaceholderSheet()
                    .uniAppEnvironment()
                    .intrinsicHeightSheet()
                    .presentationBackground(UniColors.Background.primary)
            }
            .sheet(isPresented: $isShowingPrivacyPolicy) {
                PrivacyPolicyPlaceholderSheet()
                    .uniAppEnvironment()
                    .intrinsicHeightSheet()
                    .presentationBackground(UniColors.Background.primary)
            }
        }
    }
}

// MARK: - Destinations

/// Destinations the pre-wallet Settings can push. Intentionally a
/// *subset* of `SettingsDestination` — onboarding cannot route to
/// Wallets / Security / Privacy / Advanced / Hide-balance picker
/// because those destinations read state that doesn't exist pre-wallet.
/// Naming this as a separate enum prevents a future refactor from
/// accidentally exposing post-wallet destinations to the onboarding
/// surface.
enum OnboardingSettingsDestination: Hashable, Codable {
    case language
    case appearance
    case currency
    case help
    case about
    case acknowledgments
}

// MARK: - Row primitive

/// Pre-wallet row primitive. Same shape as `SettingsView`'s
/// `SettingsRow` / `SettingsRowShared`; duplicated here so the
/// onboarding surface stays a stand-alone unit (small honest cost vs.
/// the larger cost of accidentally introducing a cross-context
/// coupling later).
private struct OnboardingSettingsRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let trailing: LocalizedStringKey?

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
            if let trailing {
                Text(trailing)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}

// MARK: - Haptic toggle row

private struct OnboardingHapticToggleRow: View {
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

// MARK: - About (onboarding variant)

/// Slimmer About page than the wallet-home Settings → About row.
/// Carries Version + Prices + Terms + Privacy + the "Made with Liquid
/// Glass" footer. No "Made by" / contributor list / etc. — the
/// Acknowledgments page is the canonical attribution surface and
/// links to it from the root.
private struct OnboardingAboutView: View {
    let onTapTerms: () -> Void
    let onTapPrivacy: () -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Version")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer()
                    Text(verbatim: AboutInfo.versionString)
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                .padding(.vertical, UniSpacing.xxs)

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
                Button { onTapTerms() } label: {
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

                Button { onTapPrivacy() } label: {
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
        .navigationBarTitleDisplayMode(.large)
    }
}
