import SwiftUI

/// Pre-wallet Settings sheet — the slim Settings surface presented from
/// the onboarding gear icon. Carries ONLY the rows that make sense
/// before the user has created or imported a wallet: language,
/// appearance, haptic feedback, help & support, and about.
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
/// `AppearancePickerView`, and `HelpAndSupportView` are the same
/// screens the full `SettingsView` uses. Their behavior is identical;
/// only the parent list differs.
struct OnboardingSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Hoisted navigation path. Lives on `OnboardingView` so the path
    /// survives sheet-content rebuilds on RTL/LTR direction flips
    /// (Rule #12 §G).
    @Binding var navigationPath: NavigationPath

    @GRDBStorage("themePreference") private var themeRaw: String = ThemePreference.defaultRaw
    @GRDBStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @GRDBStorage(HapticPreference.storageKey) private var hapticEnabled: Bool = HapticPreference.defaultValue

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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                // Preferences — what the user can set up before
                // creating a wallet.
                Section {
                    NavigationLink(value: OnboardingSettingsDestination.language) {
                        OnboardingSettingsRow(
                            systemImage: "globe",
                            title: "Language",
                            trailing: languageRowTrailing
                        )
                    }
                    .listRowBackground(UniColors.List.rowBackground)

                    NavigationLink(value: OnboardingSettingsDestination.appearance) {
                        OnboardingSettingsRow(
                            systemImage: "circle.lefthalf.filled",
                            title: "Appearance",
                            trailing: theme.label
                        )
                    }
                    .listRowBackground(UniColors.List.rowBackground)

                    OnboardingHapticToggleRow(isOn: $hapticEnabled)
                        .listRowBackground(UniColors.List.rowBackground)
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
                    .listRowBackground(UniColors.List.rowBackground)

                    NavigationLink(value: OnboardingSettingsDestination.about) {
                        OnboardingSettingsRow(
                            systemImage: "info.circle",
                            title: "About",
                            trailing: LocalizedStringKey(AboutInfo.versionString)
                        )
                    }
                    .listRowBackground(UniColors.List.rowBackground)
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
                case .help:            HelpAndSupportView()
                case .about:           OnboardingAboutView(
                                          onTapTerms: { isShowingTerms = true },
                                          onTapPrivacy: { isShowingPrivacyPolicy = true }
                                       )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(UniColors.Button.text)
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
    case help
    case about
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
        .uniListRowHitTarget()
    }
}

// MARK: - Haptic toggle row

private struct OnboardingHapticToggleRow: View {
    @Binding var isOn: Bool

    var body: some View {
        UniToggle(isOn: $isOn) {
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
        .tint(UniColors.Button.Primary.tint)
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: isOn)
    }
}

// MARK: - About (onboarding variant)

/// Slimmer About page than the wallet-home Settings → About row.
/// Carries Version + Prices + Terms + Privacy + the "Made with Liquid
/// Glass" footer.
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
                    .uniListRowHitTarget()
                }
                .buttonStyle(.uniListRow)

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
                    .uniListRowHitTarget()
                }
                .buttonStyle(.uniListRow)
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

// MARK: - Terms / Privacy sheets

private struct TermsPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        UniSheet(title: "Terms of Service") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                Image(systemName: "doc.text")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)

                UniBody(
                    text: "The Terms of Service haven't been written yet. Aperture is open source — the only thing governing your use of the app today is the MIT license in the repository.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)

                UniBody(
                    text: "When written, the Terms will state plainly: Aperture provides software, not custody. You are responsible for your keys.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) { dismiss() }
        }
    }
}

private struct PrivacyPolicyPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        UniSheet(title: "Privacy Policy") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)

                UniBody(
                    text: "Aperture collects no account, email, analytics, telemetry, or app-side logs of your wallet activity.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)

                UniBody(
                    text: "Network traffic goes only to public chain, market, and FX providers for the features you use. Those providers may log requests on their side; Aperture itself records nothing.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) { dismiss() }
        }
    }
}
