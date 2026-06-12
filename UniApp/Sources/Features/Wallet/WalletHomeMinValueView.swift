import SwiftUI

/// **Min value threshold sub-screen** — the user picks the minimum
/// fiat value an asset must carry to appear in the wallet-home
/// holdings list. Pushed onto the filter sheet's `NavigationStack`
/// via the "Min value" row.
///
/// **Design intent (Rule #2 §D.1):** give the user one quiet way
/// to dim everything below a value they care about — without
/// having to hide each dust row individually.
///
/// **Separate from the global "Hide small balances" preference.**
/// `HideBalancesPreference.thresholdKey` is a Settings preference
/// whose intent is "stop showing dust everywhere, forever." This
/// screen drives `walletHomeMinFiatThreshold` — a per-wallet-home
/// filter the user might raise to $10 for a focused-look session
/// then drop back to 0 tomorrow. The two compose — both apply
/// (whichever cuts more wins).
///
/// **Layout (Rule #15 §A).** Pushed sub-screen — does NOT wrap its
/// content in a `NavigationStack`. The parent sheet owns the stack
/// and the sub-screen consumes it.
///
/// **Two surfaces.**
///
/// 1. **Preset options.** Seven canonical step values from
///    `MinFiatOption` — `0, 0.01, 0.1, 1, 10, 100, 1000` in the
///    user's display currency. Each row carries a leading icon, a
///    localized label ("Under $1"), and a trailing `checkmark`
///    when selected. Tapping fires the haptic and writes the value
///    through.
///
/// 2. **Custom** — a section below the presets with a numeric
///    `TextField` for an arbitrary threshold. When the value
///    doesn't match any preset, the Custom row holds the active
///    selection (and presets show no checkmark). When the value
///    matches a preset, the Custom field is empty.
struct WalletHomeMinValueView: View {
    @AppStorage(WalletHomeFilterPreferences.minFiatThresholdKey)
    private var thresholdRaw: Double = WalletHomeFilterPreferences.defaultMinFiatThreshold
    @AppStorage(CurrencyPreference.storageKey)
    private var currencyCode: String = CurrencyPreference.defaultCode

    /// Mirror of the persisted threshold used by the Custom-row
    /// `TextField`. Initialized lazily on first appear to the
    /// non-preset value if any; updated on commit.
    @State private var customText: String = ""

    /// Focus on the Custom field — drives the keyboard "Done"
    /// accessory and the commit-on-focus-loss path. The commit no
    /// longer fires per keystroke (typing "10" used to commit "1"
    /// first); it fires on submit, on Done, or when focus leaves
    /// the field.
    @FocusState private var isCustomFieldFocused: Bool

    var body: some View {
        List {
            presetSection
            customSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Min value"))
        .navigationBarTitleDisplayMode(.large)
        .uniHaptic(.selection, trigger: thresholdRaw)
        .onAppear { syncCustomText() }
        .onChange(of: isCustomFieldFocused) { _, focused in
            guard !focused else { return }
            // Don't clobber a preset choice when the field loses
            // focus while empty (e.g. the user tapped a preset row
            // mid-edit, which clears the Custom field).
            let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && !thresholdIsCustom { return }
            commitCustom()
        }
        .toolbar {
            // `.decimalPad` has no return key — the keyboard
            // accessory "Done" is the explicit commit affordance.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    commitCustom()
                    isCustomFieldFocused = false
                }
            }
        }
    }

    // MARK: - Preset section

    @ViewBuilder
    private var presetSection: some View {
        Section {
            ForEach(WalletHomeFilterPreferences.MinFiatOption.allCases) { option in
                Button {
                    thresholdRaw = option.rawValue
                    syncCustomText()
                } label: {
                    HStack(spacing: UniSpacing.s) {
                        Image(systemName: optionIcon(option))
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(UniColors.Icon.secondary)
                            .frame(width: 28, alignment: .center)
                            .accessibilityHidden(true)
                        Text(verbatim: option.label(currencyCode: currencyCode))
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer(minLength: UniSpacing.s)
                        if matchesPreset(option) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(UniColors.Button.primaryTint)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, UniSpacing.xxs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
            }
        } header: {
            Text("Threshold")
        } footer: {
            Text("Holdings worth less than the chosen amount are hidden from the wallet home until you change this back to Show all.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Custom section

    @ViewBuilder
    private var customSection: some View {
        Section {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)
                Text("Custom")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer(minLength: UniSpacing.s)
                TextField("0", text: $customText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                    .frame(minWidth: 80)
                    .focused($isCustomFieldFocused)
                    .onSubmit { commitCustom() }
                    .accessibilityLabel(Text("Custom minimum value"))
            }
            .padding(.vertical, UniSpacing.xxs)
            .listRowBackground(UniColors.Background.secondary)
        } header: {
            Text("Custom")
        } footer: {
            Text("Type any threshold in your display currency.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    /// SF Symbol for the preset row's leading slot. Restraint —
    /// each option gets a calm glyph that hints at the "scale" of
    /// the threshold without being decorative.
    private func optionIcon(_ option: WalletHomeFilterPreferences.MinFiatOption) -> String {
        switch option {
        case .zero:        return "eye"
        case .oneCent:     return "circle.dotted"
        case .tenCents:    return "circle.dashed"
        case .one:         return "circle"
        case .ten:         return "circle.fill"
        case .oneHundred:  return "square"
        case .oneThousand: return "square.fill"
        }
    }

    /// True when the stored threshold matches this preset's value.
    /// The comparison is `Decimal`-based so 0.1 doesn't drift off
    /// 0.1 through `Double` round-trips.
    private func matchesPreset(_ option: WalletHomeFilterPreferences.MinFiatOption) -> Bool {
        Decimal(thresholdRaw) == Decimal(option.rawValue)
    }

    /// `true` when the stored threshold doesn't match any preset.
    /// Drives whether the Custom field shows the active value or
    /// stays empty.
    private var thresholdIsCustom: Bool {
        !WalletHomeFilterPreferences.MinFiatOption.allCases.contains { matchesPreset($0) }
    }

    /// Push the persisted threshold into the Custom `TextField`
    /// state. Called on first appear AND whenever a preset row
    /// commits, so the Custom field always reflects "is the
    /// active threshold a non-preset value, and if so what is it?"
    private func syncCustomText() {
        if thresholdIsCustom {
            customText = String(thresholdRaw)
        } else {
            customText = ""
        }
    }

    /// Parse the Custom field and write through. Ignores trailing
    /// whitespace; empty input collapses to `0` (the Show all
    /// preset). Non-numeric input is rejected silently — the
    /// previous threshold stays in effect.
    private func commitCustom() {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            thresholdRaw = 0
            return
        }
        if let parsed = Double(trimmed), parsed >= 0 {
            thresholdRaw = parsed
        }
    }
}
