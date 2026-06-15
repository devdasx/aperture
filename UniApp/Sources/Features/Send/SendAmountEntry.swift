import SwiftUI

/// The single-recipient amount HERO — a large, calm, monospaced-digit
/// amount the user types in the active unit (crypto or fiat), with the
/// conversion shown beneath, a crypto⇄fiat toggle, a MAX button, and the
/// available balance line.
///
/// **Restraint (Rule #2).** The amount is the one large element; everything
/// else is quiet support. No decorative chrome. The number is LTR-locked
/// (Rule #11) because it's a value the user reads and transcribes.
struct SendAmountHero: View {
    @Bindable var model: SendComposeModel
    var amountFocused: FocusState<Bool>.Binding
    @Binding var selectionTapCount: Int

    var body: some View {
        VStack(spacing: UniSpacing.m) {
            // Recipient line — who this amount goes to.
            if let first = model.amounts.first {
                Text(verbatim: recipientLabel(first))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity)
            }

            // The amount field — big, centered, monospaced digits.
            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xs) {
                if model.entryUnit == .fiat {
                    Text(verbatim: currencySymbol)
                        .font(UniTypography.largeTitle.monospacedDigit())
                        .foregroundStyle(UniColors.Text.secondary)
                }
                TextField("0", text: $model.primaryAmountText)
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .focused(amountFocused)
                    .fixedSize(horizontal: true, vertical: false)
                    .environment(\.layoutDirection, .leftToRight)
                if model.entryUnit == .crypto {
                    Text(verbatim: model.assetSymbol)
                        .font(UniTypography.title2.monospacedDigit())
                        .foregroundStyle(UniColors.Text.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            // Conversion line (the inactive unit) — only when priced.
            conversionLine

            // Toggle + MAX row.
            HStack(spacing: UniSpacing.s) {
                if model.assetUnitPrice != nil {
                    quietButton(unitToggleLabel, systemImage: "arrow.up.arrow.down") {
                        model.toggleEntryUnit()
                        selectionTapCount &+= 1
                    }
                }
                quietButton("Max", systemImage: "arrow.up.to.line.compact",
                            isEnabled: (model.maxAmount ?? 0) > 0) {
                    model.engageMax()
                    selectionTapCount &+= 1
                }
            }
            .padding(.top, UniSpacing.xxs)

            // Available balance.
            availableLine
        }
        .padding(.vertical, UniSpacing.m)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var conversionLine: some View {
        let crypto = model.cryptoAmount(for: model.amounts.first ?? .init(address: "", name: nil))
        switch model.entryUnit {
        case .crypto:
            if let fiat = model.fiatValue(ofCrypto: crypto) {
                Text(verbatim: "≈ \(WalletFormatting.fiat(fiat, currencyCode: model.currencyCode))")
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        case .fiat:
            Text(verbatim: "≈ \(WalletFormatting.native(crypto, decimals: model.effectiveDecimals)) \(model.assetSymbol)")
                .font(UniTypography.callout.monospacedDigit())
                .foregroundStyle(UniColors.Text.tertiary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var availableLine: some View {
        let available = model.isToken ? (model.tokenBalance ?? 0) : model.spendableNative
        return HStack(spacing: UniSpacing.xxs) {
            Text("Available")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
            Text(verbatim: "\(WalletFormatting.native(available, decimals: model.effectiveDecimals)) \(model.assetSymbol)")
                .font(UniTypography.footnote.monospacedDigit())
                .foregroundStyle(UniColors.Text.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    // MARK: - Quiet pill buttons (selection-class affordances, not CTAs)

    private func quietButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: UniSpacing.xxs) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(UniTypography.footnote.weight(.semibold))
            }
            .foregroundStyle(isEnabled ? UniColors.Text.primary : UniColors.Text.disabled)
            .padding(.horizontal, UniSpacing.s)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .tint(isEnabled ? UniColors.Button.secondaryTint : UniColors.Button.disabledFill)
        .disabled(!isEnabled)
    }

    private var unitToggleLabel: LocalizedStringKey {
        model.entryUnit == .crypto ? "Enter in \(model.currencyCode.uppercased())" : "Enter in \(model.assetSymbol)"
    }

    private var currencySymbol: String {
        let formatted = Decimal(0).formatted(.currency(code: model.currencyCode))
        // Pull just the symbol prefix/suffix; fall back to the code.
        return formatted.filter { !$0.isNumber && $0 != "." && $0 != "," && !$0.isWhitespace && $0 != "0" }
            .ifEmpty(model.currencyCode.uppercased())
    }

    private func recipientLabel(_ entry: SendComposeModel.AmountEntry) -> String {
        if let name = entry.name { return "To \(name)" }
        return "To \(SendRecipientView.shorten(entry.address))"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The MULTI-recipient amount list — one row per recipient (resolved
/// address/name + its own amount field), inside one connected inset-grouped
/// `UniCard` (the iOS grouped-form pattern, matching the recipient step).
/// Shown only when the chain can pay many recipients atomically AND more
/// than one was passed from the recipient step.
struct SendAmountMultiList: View {
    @Bindable var model: SendComposeModel
    @Binding var selectionTapCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text("Amounts (\(model.amounts.count))")
                .font(UniTypography.footnote.weight(.semibold))
                .foregroundStyle(UniColors.Text.secondary)
                .textCase(.uppercase)
                .padding(.leading, UniSpacing.xs)

            UniCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array($model.amounts.enumerated()), id: \.element.id) { offset, $entry in
                        SendAmountRow(
                            entry: $entry,
                            index: offset + 1,
                            assetSymbol: model.assetSymbol,
                            decimals: model.effectiveDecimals,
                            fiat: { model.fiatValue(ofCrypto: model.cryptoAmount(for: entry)) },
                            currencyCode: model.currencyCode
                        )
                        if offset < model.amounts.count - 1 {
                            UniDivider().padding(.leading, UniSpacing.m)
                        }
                    }
                }
            }

            HStack(spacing: UniSpacing.xxs) {
                Text("Total")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                Text(verbatim: "\(WalletFormatting.native(model.totalCrypto, decimals: model.effectiveDecimals)) \(model.assetSymbol)")
                    .font(UniTypography.footnote.monospacedDigit())
                    .foregroundStyle(UniColors.Text.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .padding(.leading, UniSpacing.xs)
        }
    }
}

/// One recipient row in the multi-recipient amount list.
private struct SendAmountRow: View {
    @Binding var entry: SendComposeModel.AmountEntry
    let index: Int
    let assetSymbol: String
    let decimals: Int
    let fiat: () -> Decimal?
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            Text(verbatim: recipientLabel)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .environment(\.layoutDirection, .leftToRight)

            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xs) {
                TextField("0", text: $entry.amountText)
                    .font(UniTypography.title3.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .keyboardType(.decimalPad)
                    .environment(\.layoutDirection, .leftToRight)
                Text(verbatim: assetSymbol)
                    .font(UniTypography.callout)
                    .foregroundStyle(UniColors.Text.secondary)
                Spacer(minLength: UniSpacing.s)
                if let f = fiat() {
                    Text(verbatim: WalletFormatting.fiat(f, currencyCode: currencyCode))
                        .font(UniTypography.caption1.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    private var recipientLabel: String {
        if let name = entry.name { return "\(index). \(name)" }
        return "\(index). \(SendRecipientView.shorten(entry.address))"
    }
}
