import SwiftUI
import UIKit

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
/// SwiftUI environment propagation when `.apertureEnvironment()`'s
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
private enum SettingsInternalVisibility {
    static let showsDiagnostics = false
}

enum SettingsDestination: Hashable, Codable {
    case wallets
    case walletDetail(UUID)
    case security
    case autoLock
    case hideSmallBalances

    case language
    case appearance
    case currency
    case preferences
    case diagnostics
    case about

    /// Whether this destination may be auto-restored on a cold launch.
    /// The Security screen is auth-gated (passcode-only) — restoring
    /// straight back into it would re-show the screen the user
    /// authenticated for minutes ago without a fresh challenge, which is
    /// exactly the bypass the user reported (2026-06-17). So `.security`
    /// (and anything pushed beneath it, e.g. `.autoLock`) is excluded:
    /// the user lands on the Settings root and re-enters Security with a
    /// fresh passcode prompt. Mirrors
    /// `WalletHomeDestination.isColdLaunchRestorable`.
    var isColdLaunchRestorable: Bool {
        switch self {
        case .security:
            return false
        case .diagnostics:
            return SettingsInternalVisibility.showsDiagnostics
        case .wallets, .walletDetail, .autoLock, .hideSmallBalances,
             .language, .appearance, .currency, .preferences, .about:
            return true
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let showsCloseButton: Bool
    private let allowsSplitLayout: Bool

    /// Settings is a top-level tab root (`MainTabView` — 2026-06-09)
    /// so its `NavigationStack` path is owned internally. The
    /// prior `@Binding var navigationPath: NavigationPath`
    /// existed only to thread Rule #12 §G's direction-flip rebuild
    /// across the sheet-presentation boundary the wallet-home used
    /// to host this view. A tab root doesn't have that boundary —
    /// rebuilds propagate via SwiftUI's standard environment
    /// channel, so the path stays here.
    ///
    /// **Navigation mirror (2026-06-13, launch reset 2026-07-09).**
    /// Seeded from `ScreenRestoration`'s mirror in `init` and mirrored back on
    /// every change via `.onChange` below. New app processes clear the mirror
    /// before this view is constructed; in-session root rebuilds, such as
    /// direction flips, can still re-seed the current stack.
    // Typed stack (not the opaque `NavigationPath`) so restoration can
    // inspect it and refuse to re-open the auth-gated Security screen on
    // a cold launch — same pattern as `WalletHomeDestination`.
    @State private var navigationPath: [SettingsDestination]
    @State private var splitSelection: SettingsDestination?
    @State private var splitDetailPath: [SettingsDestination]
    @State private var protectedNavigationDestination: SettingsDestination?
    @State private var isShowingProtectedNavigationGate = false

    init(showsCloseButton: Bool = false, allowsSplitLayout: Bool = true) {
        self.showsCloseButton = showsCloseButton
        self.allowsSplitLayout = allowsSplitLayout
        let restoredStack = ScreenRestoration.restoredSettingsStack()
        let splitState = Self.splitState(from: restoredStack)
        // `@State` reads its initial value only when the view's
        // identity is fresh (cold launch, tab-shell rebuild, root
        // direction flip) — exactly the moments restoration should
        // apply. Re-running this on routine `MainTabView` body passes
        // is a no-op against existing state, and the decode cost is a
        // few enum cases of JSON. `restoredSettingsStack()` truncates at
        // the first non-restorable destination (e.g. `.security`).
        _navigationPath = State(initialValue: restoredStack)
        _splitSelection = State(initialValue: splitState.selection)
        _splitDetailPath = State(initialValue: splitState.detailPath)
    }

    @GRDBStorage("themePreference") private var themeRaw: String = ThemePreference.defaultRaw
    @GRDBStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @GRDBStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    // Preference keys used only by child screens must not be declared
    // here: `@GRDBStorage` invalidates this stack owner on every flip.
    // **M-005:** Preferences is a slim sub-screen (haptics, amount display,
    // hide small balances). Home hide-balance is the eye on BalanceCard;
    // privacy mask is the lock overlay — not Preferences rows.

    /// Deep-link token stamped by `MainTabView`'s long-press menu
    /// ("Manage wallets" → Settings tab + push `.wallets`). The
    /// token is consumed on appear and cleared so the push fires
    /// exactly once. Empty string = no deep link.
    @GRDBStorage("settingsDeepLink") private var settingsDeepLink: String = ""

    private var theme: ThemePreference {
        ThemePreference.stored(themeRaw)
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
        Group {
            if usesSplitLayout {
                splitBody
            } else {
                compactBody
            }
        }
        .sheet(isPresented: $isShowingProtectedNavigationGate) {
            protectedNavigationGate
        }
    }

    private var usesSplitLayout: Bool {
        allowsSplitLayout && !showsCloseButton && horizontalSizeClass == .regular
    }

    @ViewBuilder
    private var compactBody: some View {
        NavigationStack(path: $navigationPath) {
            compactSettingsRootList
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Close"))
                    }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                settingsDestination(destination)
            }
            .onAppear { consumeDeepLink() }
            .onChange(of: settingsDeepLink) { _, _ in consumeDeepLink() }
            // Navigation mirror for root rebuilds. Cold launch clears it
            // before this view's `init`; live rebuilds can consume it.
            .onChange(of: navigationPath) { _, newPath in
                ScreenRestoration.saveSettingsStack(newPath)
            }
        }
    }

    @ViewBuilder
    private var splitBody: some View {
        NavigationSplitView {
            splitSettingsRootList
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
        } detail: {
            NavigationStack(path: $splitDetailPath) {
                if let splitSelection {
                    settingsDestination(splitSelection)
                        .navigationDestination(for: SettingsDestination.self) { destination in
                            settingsDestination(destination)
                        }
                } else {
                    SettingsSplitPlaceholderView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if splitSelection == nil {
                splitSelection = Self.defaultSplitSelection
            }
            consumeDeepLink()
        }
        .onChange(of: settingsDeepLink) { _, _ in consumeDeepLink() }
        .onChange(of: splitSelection) { _, _ in
            splitDetailPath.removeAll()
            saveSplitStack()
        }
        .onChange(of: splitDetailPath) { _, _ in saveSplitStack() }
    }

    @ViewBuilder
    private var compactSettingsRootList: some View {
        List {
            settingsRootSections
        }
        .settingsRootListChrome()
    }

    @ViewBuilder
    private var splitSettingsRootList: some View {
        List(selection: $splitSelection) {
            settingsRootSections
        }
        .settingsRootListChrome()
    }

    @ViewBuilder
    private var settingsRootSections: some View {
            // Section 1 — Wallets (multi-wallet management)
            Section {
                NavigationLink(value: SettingsDestination.wallets) {
                    SettingsRow(
                        systemImage: "creditcard.and.123",
                        title: "Wallets",
                        trailing: nil,
                        iconTint: .blue
                    )
                }
                .listRowBackground(UniColors.List.rowBackground)
            }

            // Section 2 — Security
            Section {
                Button {
                    navigateToProtectedDestination(.security)
                } label: {
                    SettingsRow(
                        systemImage: "lock",
                        title: "Security",
                        trailing: nil,
                        iconTint: .green
                    )
                }
                .buttonStyle(.uniListRow)
                .tag(SettingsDestination.security)
                .listRowBackground(UniColors.List.rowBackground)
            }

            // Section 3 — Preferences (existing + new hide toggles)
            Section {
                NavigationLink(value: SettingsDestination.language) {
                    SettingsRow(
                        systemImage: "globe",
                        title: "Language",
                        trailing: languageRowTrailing,
                        iconTint: .indigo
                    )
                }
                .listRowBackground(UniColors.List.rowBackground)

                NavigationLink(value: SettingsDestination.appearance) {
                    SettingsRow(
                        systemImage: "circle.lefthalf.filled",
                        title: "Appearance",
                        trailing: theme.label,
                        iconTint: .gray
                    )
                }
                .listRowBackground(UniColors.List.rowBackground)

                NavigationLink(value: SettingsDestination.currency) {
                    SettingsRow(
                        systemImage: "dollarsign.circle",
                        title: "Currency",
                        trailing: currencyRowTrailing,
                        iconTint: .green
                    )
                }
                .listRowBackground(UniColors.List.rowBackground)

                // Preferences hosts haptics, transaction display, and
                // Hide small balances. Home hide-balance is also available
                // from the wallet filter / Min value surface.
                NavigationLink(value: SettingsDestination.preferences) {
                    SettingsRow(
                        systemImage: "slider.horizontal.3",
                        title: "Preferences",
                        trailing: nil,
                        iconTint: .orange
                    )
                }
                .listRowBackground(UniColors.List.rowBackground)
            }

            // Section 4 — About
            Section {
                NavigationLink(value: SettingsDestination.about) {
                    SettingsRow(
                        systemImage: "info.circle",
                        title: "About",
                        trailing: LocalizedStringKey(AboutInfo.versionString),
                        iconTint: .gray
                    )
                }
                .listRowBackground(UniColors.List.rowBackground)

                if SettingsInternalVisibility.showsDiagnostics {
                    NavigationLink(value: SettingsDestination.diagnostics) {
                        SettingsRow(
                            systemImage: "doc.text.magnifyingglass",
                            title: "Diagnostics Logs",
                            trailing: nil,
                            iconTint: .purple
                        )
                    }
                    .listRowBackground(UniColors.List.rowBackground)
                }
            }

            // Section 6 — Reset Aperture (terminal nuclear hatch). Moved
            // here from the removed Advanced screen (2026-06-19).
            ResetApertureSection()
    }

    @ViewBuilder
    private func settingsDestination(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .wallets:                   WalletsListView()
        case .walletDetail(let id):      WalletDetailView(walletId: id)
        case .security:                  SecuritySettingsView()
        case .autoLock:                  AutoLockPickerView()
        case .hideSmallBalances:         HideSmallBalancesPicker()
        case .language:                  LanguagePickerView()
        case .appearance:                AppearancePickerView()
        case .currency:                  CurrencyPickerView()
        case .preferences:               PreferencesView()
        case .diagnostics:               DiagnosticsLogView()
        case .about:                     AboutView()
        }
    }

    @ViewBuilder
    private var protectedNavigationGate: some View {
        NavigationStack {
            PinCodeView(
                mode: .verify,
                onComplete: { _ in
                    guard let destination = protectedNavigationDestination else {
                        isShowingProtectedNavigationGate = false
                        return
                    }
                    protectedNavigationDestination = nil
                    isShowingProtectedNavigationGate = false
                    completeProtectedNavigation(to: destination)
                },
                onCancel: {
                    protectedNavigationDestination = nil
                    isShowingProtectedNavigationGate = false
                },
                allowsBiometrics: false,
                showsNavigationControls: false,
                accessContext: .accessSecurity
            )
        }
        .apertureEnvironment()
        .uniSheetDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(UniColors.Background.primary)
    }

    private func navigateToProtectedDestination(_ destination: SettingsDestination) {
        guard PinCodeStorage.hasPin else {
            completeProtectedNavigation(to: destination)
            return
        }
        protectedNavigationDestination = destination
        isShowingProtectedNavigationGate = true
    }

    private func completeProtectedNavigation(to destination: SettingsDestination) {
        if usesSplitLayout {
            splitSelection = destination
            splitDetailPath.removeAll()
            saveSplitStack()
        } else if navigationPath.last != destination {
            navigationPath.append(destination)
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
            if usesSplitLayout {
                splitSelection = .wallets
                splitDetailPath.removeAll()
                saveSplitStack()
            } else {
                navigationPath.append(SettingsDestination.wallets)
            }
        default:
            break
        }
    }

    private func saveSplitStack() {
        guard usesSplitLayout, let splitSelection else { return }
        ScreenRestoration.saveSettingsStack([splitSelection] + splitDetailPath)
    }

    private static let defaultSplitSelection: SettingsDestination = .wallets

    private static func splitState(from stack: [SettingsDestination]) -> (selection: SettingsDestination, detailPath: [SettingsDestination]) {
        guard let first = stack.first else {
            return (defaultSplitSelection, [])
        }
        if isSplitRoot(first) {
            return (first, Array(stack.dropFirst()))
        }
        switch first {
        case .walletDetail:
            return (.wallets, stack)
        case .autoLock:
            return (.security, stack)
        case .hideSmallBalances:
            return (.preferences, stack)
        case .wallets, .security, .language, .appearance, .currency,
             .preferences, .diagnostics, .about:
            return (first, Array(stack.dropFirst()))
        }
    }

    private static func isSplitRoot(_ destination: SettingsDestination) -> Bool {
        switch destination {
        case .wallets, .security, .language, .appearance, .currency,
             .preferences, .diagnostics, .about:
            return true
        case .walletDetail, .autoLock, .hideSmallBalances:
            return false
        }
    }
}

// MARK: - Row primitive

private extension View {
    func settingsRootListChrome() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.large)
    }
}

/// P3-003: honest empty iPad detail when no sidebar selection is active.
private struct SettingsSplitPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Choose a section", systemImage: "sidebar.leading")
        } description: {
            Text("Select Wallets, Security, Preferences, or About from the sidebar.")
        }
        .background(UniColors.Background.primary)
        .accessibilityIdentifier("settings.split.placeholder")
    }
}

struct SettingsIconTile: View {
    let systemImage: String
    let tint: Color
    var compactTint: Color = UniColors.Icon.secondary

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesIPadTile: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if usesIPadTile {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint)
                    .frame(width: 29, height: 29)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.72)
                            .padding(4)
                    }
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(compactTint)
                    .frame(width: 28, alignment: .center)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SettingsRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    /// Optional trailing summary. `nil` for rows that don't carry a
    /// status — the row collapses without the right-side `Text`.
    let trailing: LocalizedStringKey?
    var iconTint: Color = .gray

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            SettingsIconTile(systemImage: systemImage, tint: iconTint)
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
            }

            // Legal + support — each opens the live page on aperturex.io
            // outside the app (trailing ↗ signals it leaves the app).
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

    /// A row that opens a web page outside the app. The trailing
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
                .uniListRowHitTarget()
            }
            .buttonStyle(.uniListRow)
            .accessibilityHint(Text("Opens outside Aperture"))
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
// **M-005 (honest surface):** slim Preferences — haptic feedback,
// transaction amount display, and hide-small-balances picker. Home
// hide-balance is the BalanceCard eye; privacy blur is the lock overlay.
// Not a full privacy control center.
struct PreferencesView: View {
    @GRDBStorage(HapticPreference.storageKey) private var hapticEnabled: Bool = HapticPreference.defaultValue
    /// Show transaction-detail headline amounts in the user's local currency
    /// (default) vs. the native coin amount. Activity rows now show both
    /// native and local values at once.
    @GRDBStorage(TransactionAmountDisplayPreference.storageKey)
    private var txAmountsInLocalCurrency: Bool = TransactionAmountDisplayPreference.defaultValue

    var body: some View {
        List {
            Section {
                HapticToggleRow(isOn: $hapticEnabled)
                    .listRowBackground(UniColors.List.rowBackground)
            }

            // Transaction-detail amount display. Activity lists always show
            // native + local value together, so this toggle now controls the
            // transaction receipt hero ordering only.
            Section {
                UniToggle(isOn: $txAmountsInLocalCurrency) {
                    HStack(spacing: UniSpacing.s) {
                        SettingsIconTile(systemImage: "coloncurrencysign.circle", tint: .green)
                            .accessibilityHidden(true)
                        Text("Amounts in local currency")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                    }
                }
                .tint(UniColors.Button.Primary.tint)
                .padding(.vertical, UniSpacing.xxs)
                .listRowBackground(UniColors.List.rowBackground)
            } header: {
                Text("Transactions")
            } footer: {
                Text("Use your local currency as the main amount in transaction details. Activity lists show both native and local amounts.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // P2-020: surface hide-small-balances (destination existed but was unreachable).
            Section {
                NavigationLink(value: SettingsDestination.hideSmallBalances) {
                    HStack(spacing: UniSpacing.s) {
                        SettingsIconTile(systemImage: "line.3.horizontal.decrease.circle", tint: .purple)
                            .accessibilityHidden(true)
                        Text("Hide small balances")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                    }
                    .padding(.vertical, UniSpacing.xxs)
                }
                .listRowBackground(UniColors.List.rowBackground)
            } footer: {
                Text("Also available from Home → Min value. Assets below the threshold stay hidden from portfolio totals.")
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
                SettingsIconTile(systemImage: "hand.tap", tint: .orange)
                    .accessibilityHidden(true)

                Text("Haptic feedback")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .tint(UniColors.Button.Primary.tint)
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
                SettingsIconTile(systemImage: "eye.slash", tint: .indigo)
                    .accessibilityHidden(true)
                Text("Hide balance on home")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .tint(UniColors.Button.Primary.tint)
        .padding(.vertical, UniSpacing.xxs)
        // Haptic fires inside UniToggle (`.toggle` per handoff)
    }
}

struct HideSmallBalancesPicker: View {
    @GRDBStorage(HideBalancesPreference.thresholdKey) private var raw: Double = HideBalancesPreference.defaultThreshold
    @GRDBStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

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
                        .uniListRowHitTarget()
                    }
                    .buttonStyle(.uniListRow)
                    .listRowBackground(UniColors.List.rowBackground)
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
