import SwiftUI

/// Settings screen — the root of the Settings tab in `MainTabView`
/// (2026-06-09). Was a `.sheet(...)` presented from the wallet-home
/// toolbar's gear icon through 2026-06-08; the four-tab shell
/// promoted it to a top-level destination.
///
/// **Architecture note.** Settings is a *navigation experience* — a
/// root list of options that pushes per-option pickers, each with its
/// own `List` and (for Language / Currency) a `.searchable` field.
/// That requires a real `NavigationStack`. As a tab root the
/// `NavigationStack`'s path is owned internally as `@State`; it no
/// longer needs the parent-`@Binding` shape that the sheet-host
/// variant carried (the binding existed only to thread Rule #12 §G's
/// direction-flip rebuild, which is a sheet-presentation concern that
/// doesn't apply to a tab root — tab roots rebuild via the standard
/// SwiftUI environment propagation when `.uniAppEnvironment()`'s
/// `\.locale` or `\.layoutDirection` flips).
///
/// **Still presented from onboarding pre-wallet as a sheet.** The
/// pre-wallet language/appearance Settings surface (reached from the
/// onboarding chrome before any wallet exists) is a different view —
/// `OnboardingSettingsView` — and remains a sheet for that surface
/// because no tab bar is present pre-wallet. Only the post-wallet
/// Settings surface (this view) migrated to the tab.
///
/// Layered honestly: this tab's chrome IS the system Liquid Glass
/// nav bar + tab bar; the `List` rows inside are opaque content
/// (Rule #2 §B.3). All visible strings flow through
/// `LocalizedStringKey` and the String Catalog (Rule #9).
enum SettingsDestination: Hashable, Codable {
    case wallets
    case walletDetail(UUID)
    case security
    case autoLock
    case privacy
    case acknowledgments
    case networkProviders
    case advanced
    case hideSmallBalances

    case language
    case appearance
    case currency
    case help
    case about

    /// **Developer / Design playground.** Pushes `TestScreenView` — a
    /// faithful copy of the wallet-home surface with mock data and
    /// inert actions, used by the design team (and the user) to
    /// evaluate design experiments before promoting them to the real
    /// wallet screen. Lives under the dedicated "Developer" section
    /// so its provenance is honest — this is not a user feature, it's
    /// a design/dev affordance.
    case testScreen
}

struct SettingsView: View {
    /// Settings is a top-level tab root (`MainTabView` — 2026-06-09)
    /// so its `NavigationStack` path is owned internally. The
    /// prior `@Binding var navigationPath: NavigationPath`
    /// existed only to thread Rule #12 §G's direction-flip rebuild
    /// across the sheet-presentation boundary the wallet-home used
    /// to host this view. A tab root doesn't have that boundary —
    /// rebuilds propagate via SwiftUI's standard environment
    /// channel, so the path stays here.
    @State private var navigationPath: NavigationPath = NavigationPath()

    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.defaultRaw
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @AppStorage(HapticPreference.storageKey) private var hapticEnabled: Bool = HapticPreference.defaultValue
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var hideBalanceOnHome: Bool = false
    @AppStorage(HideBalancesPreference.thresholdKey) private var hideSmallThreshold: Double = HideBalancesPreference.defaultThreshold
    /// Test-mode toggle — same `@AppStorage` key the wallet-home
    /// reads. Flipping here updates the wallet view in place
    /// (2026-06-09 — replaced the toolbar flask).
    @AppStorage("isTestMode") private var isTestMode: Bool = false

    /// Deep-link token stamped by `MainTabView`'s long-press menu
    /// ("Manage wallets" → Settings tab + push `.wallets`). The
    /// token is consumed on appear and cleared so the push fires
    /// exactly once. Empty string = no deep link.
    @AppStorage("settingsDeepLink") private var settingsDeepLink: String = ""

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
                // Section 1 — Wallets (multi-wallet management)
                Section {
                    NavigationLink(value: SettingsDestination.wallets) {
                        SettingsRow(
                            systemImage: "creditcard.and.123",
                            title: "Wallets",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)
                }

                // Section 2 — Security
                Section {
                    NavigationLink(value: SettingsDestination.security) {
                        SettingsRow(
                            systemImage: "lock.shield",
                            title: "Security",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)
                }

                // Section 3 — Preferences (existing + new hide toggles)
                Section {
                    NavigationLink(value: SettingsDestination.language) {
                        SettingsRow(
                            systemImage: "globe",
                            title: "Language",
                            trailing: languageRowTrailing
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: SettingsDestination.appearance) {
                        SettingsRow(
                            systemImage: "circle.lefthalf.filled",
                            title: "Appearance",
                            trailing: theme.label
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: SettingsDestination.currency) {
                        SettingsRow(
                            systemImage: "dollarsign.circle",
                            title: "Currency",
                            trailing: currencyRowTrailing
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    HapticToggleRow(isOn: $hapticEnabled)
                        .listRowBackground(UniColors.Background.secondary)

                    HideBalanceToggleRow(isOn: $hideBalanceOnHome)
                        .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: SettingsDestination.hideSmallBalances) {
                        SettingsRow(
                            systemImage: "eye.slash.circle",
                            title: "Hide small balances",
                            trailing: LocalizedStringKey(HideBalancesPreference.option(for: hideSmallThreshold).label(currencyCode: currencyCode))
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)
                }

                // Section 4 — Privacy
                Section {
                    NavigationLink(value: SettingsDestination.privacy) {
                        SettingsRow(
                            systemImage: "hand.raised",
                            title: "Privacy",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)
                }

                // Section 5 — Help & About
                Section {
                    NavigationLink(value: SettingsDestination.help) {
                        SettingsRow(
                            systemImage: "questionmark.circle",
                            title: "Help & Support",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: SettingsDestination.about) {
                        SettingsRow(
                            systemImage: "info.circle",
                            title: "About",
                            trailing: LocalizedStringKey(AboutInfo.versionString)
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: SettingsDestination.acknowledgments) {
                        SettingsRow(
                            systemImage: "text.book.closed",
                            title: "Acknowledgments",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    NavigationLink(value: SettingsDestination.networkProviders) {
                        SettingsRow(
                            systemImage: "network",
                            title: "Network providers",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)
                }

                // Section 6 — Developer (design playground)
                //
                // Surfaces the `TestScreen` route — a faithful copy of
                // the wallet-home with mock data and inert actions, used
                // by the design team (and the user) to evaluate design
                // experiments before promoting them to the real wallet
                // surface. Lives in a dedicated "Developer" section
                // (header on the section) so its provenance is honest:
                // this is a dev / design affordance, not a user feature.
                Section {
                    NavigationLink(value: SettingsDestination.testScreen) {
                        SettingsRow(
                            systemImage: "flask",
                            title: "Test Screen",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)

                    // Test against public addresses toggle. The flask
                    // icon used to live in the wallet-home toolbar
                    // (2026-06-06 ship); moved here on 2026-06-09 per
                    // user direction so the toolbar reads cleaner —
                    // gear on the left, wallet pill centred, nothing
                    // trailing. `isTestMode` is `@AppStorage` so
                    // toggling here flips the wallet-home's view in
                    // place; no extra plumbing.
                    Toggle(isOn: $isTestMode) {
                        SettingsRow(
                            systemImage: "atom",
                            title: "Test against public addresses",
                            trailing: nil
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)
                } header: {
                    Text("Developer")
                }

                // Section 7 — Advanced (terminal nuclear hatch)
                Section {
                    NavigationLink(value: SettingsDestination.advanced) {
                        SettingsRow(
                            systemImage: "wrench.and.screwdriver",
                            title: "Advanced",
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
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .wallets:                   WalletsListView()
                case .walletDetail(let id):      WalletDetailView(walletId: id)
                case .security:                  SecuritySettingsView()
                case .autoLock:                  AutoLockPickerView()
                case .privacy:                   PrivacySettingsView()
                case .acknowledgments:           AcknowledgmentsView()
                case .networkProviders:          NetworkProvidersView()
                case .advanced:                  AdvancedSettingsView()
                case .hideSmallBalances:         HideSmallBalancesPicker()
                case .language:                  LanguagePickerView()
                case .appearance:                AppearancePickerView()
                case .currency:                  CurrencyPickerView()
                case .help:                      HelpAndSupportView()
                case .about:                     AboutView(
                                                    onTapTerms: { isShowingTerms = true },
                                                    onTapPrivacy: { isShowingPrivacyPolicy = true }
                                                 )
                case .testScreen:                TestScreenView()
                }
            }
            // No `.toolbar` Done item — as a tab root in
            // `MainTabView`, Settings has no parent presentation to
            // dismiss back to. The tab bar IS the back-stop; the
            // user leaves Settings by tapping another tab. The prior
            // Done item existed for the sheet-host era (the wallet-
            // home's `.sheet { SettingsView }`) and is retired with
            // the host.
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
            .onAppear { consumeDeepLink() }
            .onChange(of: settingsDeepLink) { _, _ in consumeDeepLink() }
        }
    }

    /// Consume the `settingsDeepLink` token. Currently supports
    /// `"wallets"` (from `MainTabView`'s long-press "Manage
    /// wallets" entry). Token is cleared after consumption so the
    /// push fires exactly once per stamp; re-stamping pushes again.
    private func consumeDeepLink() {
        guard !settingsDeepLink.isEmpty else { return }
        switch settingsDeepLink {
        case "wallets":
            navigationPath.append(SettingsDestination.wallets)
        default:
            break
        }
        settingsDeepLink = ""
    }
}

// MARK: - Row primitive

private struct SettingsRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    /// Optional trailing summary. `nil` for rows that don't carry a
    /// status (Help & Support, future external-link rows) — the row
    /// collapses without the right-side `Text`.
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

// MARK: - About

private struct AboutView: View {
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

// MARK: - AboutInfo

enum AboutInfo {
    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

// MARK: - Haptic toggle row

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

// MARK: - Hide-balance toggle + threshold picker

private struct HideBalanceToggleRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)
                Text("Hide balance on home")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .tint(UniColors.Button.primaryTint)
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: isOn)
    }
}

struct HideSmallBalancesPicker: View {
    @AppStorage(HideBalancesPreference.thresholdKey) private var raw: Double = HideBalancesPreference.defaultThreshold
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    var body: some View {
        List {
            Section {
                ForEach(HideBalancesPreference.ThresholdOption.allCases) { option in
                    Button {
                        raw = option.rawValue
                    } label: {
                        HStack {
                            Text(LocalizedStringKey(option.label(currencyCode: currencyCode)))
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Text.primary)
                            Spacer()
                            if raw == option.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(UniColors.Icon.accent)
                            }
                        }
                        .padding(.vertical, UniSpacing.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                }
            } footer: {
                Text("Holdings worth less than this amount are hidden from the wallet screen. They're still in the local store — only the display is filtered.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("Hide small balances"))
        .navigationBarTitleDisplayMode(.large)
        .uniHaptic(.selection, trigger: raw)
    }
}

// MARK: - Previews

#Preview("Light") {
    SettingsView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SettingsView()
        .preferredColorScheme(.dark)
}
