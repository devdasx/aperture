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
    case connectionApprovals
    case hideSmallBalances

    case language
    case appearance
    case currency
    case preferences
    case help
    case about

    /// Whether this destination may be auto-restored on a cold launch.
    /// The Security screen is auth-gated (PIN / Face ID) — restoring
    /// straight back into it would re-show the screen the user
    /// authenticated for minutes ago without a fresh challenge, which is
    /// exactly the bypass the user reported (2026-06-17). So `.security`
    /// (and anything pushed beneath it, e.g. `.autoLock`) is excluded:
    /// the user lands on the Settings root and re-enters Security with a
    /// fresh PIN / Face ID prompt. Mirrors
    /// `WalletHomeDestination.isColdLaunchRestorable`.
    var isColdLaunchRestorable: Bool {
        switch self {
        case .security:
            return false
        case .wallets, .walletDetail, .autoLock, .privacy,
             .connectionApprovals, .hideSmallBalances,
             .language, .appearance, .currency, .preferences, .help, .about:
            return true
        }
    }
}

struct SettingsView: View {
    /// 2026-06-23 — Settings is no longer a tab; it's presented full screen
    /// from the wallet-home toolbar's gear, so it gets a Done item again
    /// (a full screen cover has no swipe-to-dismiss).
    @Environment(\.dismiss) private var dismiss

    /// Settings is a top-level tab root (`MainTabView` — 2026-06-09)
    /// so its `NavigationStack` path is owned internally. The
    /// prior `@Binding var navigationPath: NavigationPath`
    /// existed only to thread Rule #12 §G's direction-flip rebuild
    /// across the sheet-presentation boundary the wallet-home used
    /// to host this view. A tab root doesn't have that boundary —
    /// rebuilds propagate via SwiftUI's standard environment
    /// channel, so the path stays here.
    ///
    /// **Last-screen restoration (2026-06-13).** Seeded from
    /// `ScreenRestoration`'s mirror in `init` and mirrored back on
    /// every change via `.onChange` below. On a cold launch within
    /// the 2-minute window the user lands back on the Settings
    /// sub-screen they left; `ScreenRestoration.resolveOnLaunch()`
    /// clears the mirror beforehand for longer absences, so the seed
    /// is an empty path then. The same seeding makes the stack
    /// survive the root direction-flip rebuild (`AppRoot.
    /// rootDirectionKey`) — the Choose-language screen stays put
    /// when its own selection flips LTR ↔ RTL.
    // Typed stack (not the opaque `NavigationPath`) so restoration can
    // inspect it and refuse to re-open the auth-gated Security screen on
    // a cold launch — same pattern as `WalletHomeDestination`.
    @State private var navigationPath: [SettingsDestination]

    init() {
        // `@State` reads its initial value only when the view's
        // identity is fresh (cold launch, tab-shell rebuild, root
        // direction flip) — exactly the moments restoration should
        // apply. Re-running this on routine `MainTabView` body passes
        // is a no-op against existing state, and the decode cost is a
        // few enum cases of JSON. `restoredSettingsStack()` truncates at
        // the first non-restorable destination (e.g. `.security`).
        _navigationPath = State(initialValue: ScreenRestoration.restoredSettingsStack())
    }

    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.defaultRaw
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    // NOTE (2026-06-13): the haptic / privacy-mask / hide-balance /
    // hide-small-threshold `@AppStorage` declarations that used to sit
    // here were vestigial — the rows moved into `PreferencesView` on
    // 2026-06-09 and this view's body never read them again. They were
    // not inert, though: an `@AppStorage` subscribes to its key even
    // when body never reads it, so every toggle flip on the pushed
    // Preferences screen invalidated THIS view — the owner of the
    // `NavigationStack` path. Removed so toggling a preference can
    // never disturb the stack owner. Do not re-add a preference key
    // here unless this view's body actually renders it.

    /// Deep-link token stamped by `MainTabView`'s long-press menu
    /// ("Manage wallets" → Settings tab + push `.wallets`). The
    /// token is consumed on appear and cleared so the push fires
    /// exactly once. Empty string = no deep link.
    @AppStorage("settingsDeepLink") private var settingsDeepLink: String = ""

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

                    // 2026-06-09 — Haptic, Privacy mask, Hide balance
                    // toggles + Hide small balances picker moved into
                    // a dedicated `PreferencesView` sub-screen per
                    // user direction. The main Settings list keeps
                    // Language / Appearance / Currency (display +
                    // region settings) inline; the rest live one
                    // tap away.
                    NavigationLink(value: SettingsDestination.preferences) {
                        SettingsRow(
                            systemImage: "slider.horizontal.3",
                            title: "Preferences",
                            trailing: nil
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

                // Section 4b — Connected dApps (manage browser + WalletConnect
                // connections). On-chain token approvals were removed with EVM
                // data fetching (2026-06-21).
                Section {
                    NavigationLink(value: SettingsDestination.connectionApprovals) {
                        SettingsRow(
                            systemImage: "app.connected.to.app.below.fill",
                            title: "Connected dApps",
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
                }

                // Section 6 — Reset Aperture (terminal nuclear hatch). Moved
                // here from the removed Advanced screen (2026-06-19).
                ResetApertureSection()
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.large)
            // 2026-06-23 — presented full screen from the wallet-home toolbar
            // gear (no longer a tab), so a Done item closes it.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .wallets:                   WalletsListView()
                case .walletDetail(let id):      WalletDetailView(walletId: id)
                case .security:                  SecuritySettingsView()
                case .autoLock:                  AutoLockPickerView()
                case .privacy:                   PrivacySettingsView()
                case .connectionApprovals:       ConnectionApprovalsView()
                case .hideSmallBalances:         HideSmallBalancesPicker()
                case .language:                  LanguagePickerView()
                case .appearance:                AppearancePickerView()
                case .currency:                  CurrencyPickerView()
                case .preferences:               PreferencesView()
                case .help:                      HelpAndSupportView()
                case .about:                     AboutView()
                }
            }
            // Done item restored (2026-06-23): Settings is presented full
            // screen from the wallet-home toolbar gear, so it has a parent
            // presentation to dismiss back to (see the `.toolbar` above).
            // The deep-link stamp is still consumed on appear.
            .onAppear { consumeDeepLink() }
            .onChange(of: settingsDeepLink) { _, _ in consumeDeepLink() }
            // Last-screen restoration mirror (2026-06-13). Every push
            // / pop lands in `ScreenRestoration`'s UserDefaults mirror
            // so a force-quit needs no last-moment save. Consumed by
            // `init` above on the next fresh identity.
            .onChange(of: navigationPath) { _, newPath in
                ScreenRestoration.saveSettingsStack(newPath)
            }
        }
    }

    /// Consume the `settingsDeepLink` token. Currently supports
    /// `"wallets"` (from `MainTabView`'s long-press "Manage
    /// wallets" entry). Token is cleared after consumption so the
    /// push fires exactly once per stamp; re-stamping pushes again.
    private func consumeDeepLink() {
        let token = settingsDeepLink
        guard !token.isEmpty else { return }
        // Clear the stamp BEFORE navigating: `onAppear` and
        // `onChange` can both observe the same stamp in one frame,
        // and clearing first means the second call reads an empty
        // token and returns — the push fires exactly once per stamp.
        settingsDeepLink = ""
        switch token {
        case "wallets":
            navigationPath.append(SettingsDestination.wallets)
        default:
            break
        }
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
    @Environment(\.openURL) private var openURL

    /// Canonical web destinations live in the shared `ApertureWeb` constant
    /// (also used by the onboarding legal footer) so the URLs never drift.
    private typealias Web = ApertureWeb

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

            // Legal + support — each opens the live page on aperturex.io
            // in the system browser (trailing ↗ signals it leaves the app).
            Section {
                externalRow("Terms of Service", Web.terms)
                externalRow("Privacy Policy", Web.privacy)
                externalRow("Your Privacy Choices", Web.privacyChoices)
                externalRow("Support", Web.support)
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

    /// A row that opens a web page in the system browser. The trailing
    /// `arrow.up.right` glyph signals the tap leaves the app (vs the
    /// `chevron.right` used for in-app push navigation).
    @ViewBuilder
    private func externalRow(_ title: LocalizedStringKey, _ urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Button { openURL(url) } label: {
                HStack {
                    Text(title)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens in browser"))
        }
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

// MARK: - PreferencesView
//
// 2026-06-09 — user direction: *"create preferences section in the
// settings screen, and move haptic, privacy, hide balance, hide
// small balance to this screen."* Dedicated sub-screen reached via
// `SettingsDestination.preferences` from the main Settings list.
// Same row primitives the main Settings list uses, hosted under a
// `List` with `.insetGrouped` style + `UniColors.Background.primary`
// — visually consistent with the rest of Settings.
struct PreferencesView: View {
    @AppStorage(HapticPreference.storageKey) private var hapticEnabled: Bool = HapticPreference.defaultValue
    /// Show transaction-history amounts in the user's local currency
    /// (default) vs. the native coin amount. Read by `ActivityRow` across
    /// every activity surface (2026-06-18 user direction).
    @AppStorage("txAmountsInLocalCurrency") private var txAmountsInLocalCurrency: Bool = true
    // Privacy-mask / hide-balance-on-home / hide-small-balances rows were
    // removed from this screen per user direction (2026-06-18). The
    // underlying preferences still exist (the wallet-home reads its own
    // @AppStorage for each, keeping whatever the user last set); they're
    // simply no longer surfaced here.

    var body: some View {
        List {
            Section {
                HapticToggleRow(isOn: $hapticEnabled)
                    .listRowBackground(UniColors.Background.secondary)
            }

            // Transaction-history amount display (2026-06-18). On (default)
            // shows the local-currency value; off shows the native coin
            // amount. Read by `ActivityRow` everywhere it renders.
            Section {
                UniToggle(isOn: $txAmountsInLocalCurrency) {
                    HStack(spacing: UniSpacing.s) {
                        Image(systemName: "coloncurrencysign.circle")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(UniColors.Icon.secondary)
                            .frame(width: 28, alignment: .center)
                            .accessibilityHidden(true)
                        Text("Amounts in local currency")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                    }
                }
                .tint(UniColors.Button.primaryTint)
                .padding(.vertical, UniSpacing.xxs)
                .listRowBackground(UniColors.Background.secondary)
            } header: {
                Text("Transactions")
            } footer: {
                Text("Show transaction-history amounts in your local currency. Turn off to show the native coin amount instead.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Preferences"))
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Haptic toggle row

private struct HapticToggleRow: View {
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
        .tint(UniColors.Button.primaryTint)
        .padding(.vertical, UniSpacing.xxs)
        // Haptic fires inside UniToggle (`.toggle` per handoff)
    }
}

// MARK: - Hide-balance toggle + threshold picker

private struct HideBalanceToggleRow: View {
    @Binding var isOn: Bool

    var body: some View {
        UniToggle(isOn: $isOn) {
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
        // Haptic fires inside UniToggle (`.toggle` per handoff)
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
