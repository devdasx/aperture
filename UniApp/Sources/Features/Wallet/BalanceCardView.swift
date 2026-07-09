import SwiftUI

/// Wallet-home balance summary group.
///
/// The native `GroupBox` renders only the wallet identity, current total,
/// visibility toggle, and zero-state CTA. Its style uses the app's semantic
/// card fill so the surface adapts with the rest of the light/dark card
/// system. Chart UI, chart range tabs, chart scrubbing, and history
/// reconstruction are intentionally not part of this surface.
struct BalanceCardView: View {
    let walletId: UUID?
    let walletName: String
    let totalFiat: Decimal
    let currencyCode: String
    let lastUpdated: Date?
    let onSwitchWallet: () -> Void
    let onAddFunds: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @GRDBStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var isHidden: Bool = false

    init(
        walletId: UUID?,
        walletName: String,
        totalFiat: Decimal,
        currencyCode: String,
        lastUpdated: Date?,
        onSwitchWallet: @escaping () -> Void,
        onAddFunds: @escaping () -> Void
    ) {
        self.walletId = walletId
        self.walletName = walletName
        self.totalFiat = totalFiat
        self.currencyCode = currencyCode
        self.lastUpdated = lastUpdated
        self.onSwitchWallet = onSwitchWallet
        self.onAddFunds = onAddFunds
    }

    private enum CardState: Equatable { case value, zero }

    private var resolvedState: CardState {
        if totalFiat <= 0 { return .zero }
        return .value
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: balanceDisclosureBinding) {
                balanceDisclosureContent
            } label: {
                balanceDisclosureLabel
            }
            .disclosureGroupStyle(BalanceCardDisclosureStyle())
            .padding(.vertical, UniSpacing.xs)
            .animation(reduceMotion ? nil : .default, value: isHidden)
        }
        .groupBoxStyle(BalanceCardGroupBoxStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private static func updatedCaption(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return String(format: String.apertureLocalized("Updated %@"), relative)
    }

    private var balanceDisclosureBinding: Binding<Bool> {
        Binding<Bool>(
            get: { !isHidden },
            set: { isExpanded in
                setHidden(!isExpanded)
            }
        )
    }

    @ViewBuilder
    private var balanceDisclosureContent: some View {
        if resolvedState == .zero {
            zeroBody
        }
    }

    private var balanceDisclosureLabel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text("Total balance")
                .font(UniTypography.BalanceCard.label)
                .foregroundStyle(UniColors.Text.secondary)
                .padding(.top, 24)
                .padding(.bottom, 8)

            tappableBalanceNumber
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 1) {
                Button(action: switchWallet) {
                    HStack(spacing: 3) {
                        Text(verbatim: walletName)
                            .font(UniTypography.BalanceCard.walletName)
                            .foregroundStyle(UniColors.Text.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Switch wallet, currently \(walletName)"))

                if let lastUpdated {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(verbatim: Self.updatedCaption(lastUpdated))
                            .font(UniTypography.caption2)
                            .foregroundStyle(UniColors.Text.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 44, alignment: .top)

            Spacer(minLength: UniSpacing.xs)

            Button(action: toggleHidden) {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(UniColors.BalanceCard.eyeGlyph(colorScheme))
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(UniColors.BalanceCard.eyeButtonFill(colorScheme))
                    }
                    .overlay {
                        Circle()
                            .stroke(UniColors.BalanceCard.avatarRing(colorScheme), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isHidden ? "Show balance" : "Hide balance"))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var tappableBalanceNumber: some View {
        balanceNumber
            .contentShape(Rectangle())
            .onTapGesture { toggleHidden() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(isHidden ? "Show balance" : "Hide balance"))
    }

    private var balanceNumber: some View {
        Group {
            if isHidden {
                maskedBalance()
            } else {
                composedBalance()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func maskedBalance() -> Text {
        let parts = WalletFormatting.fiatParts(totalFiat, currencyCode: currencyCode)
        let currency = Text(verbatim: parts.currency)
            .font(UniTypography.BalanceCard.currency)
            .foregroundStyle(UniColors.Text.secondary)
        let dots = Text(verbatim: "••••••")
            .font(UniTypography.BalanceCard.balance)
            .foregroundStyle(UniColors.Text.primary)
            .tracking(2)
        let gap = Text(verbatim: " ")
            .font(UniTypography.BalanceCard.currency)

        if parts.currency.isEmpty {
            return dots
        }
        return parts.currencyLeads
            ? Text("\(currency)\(gap)\(dots)")
            : Text("\(dots)\(gap)\(currency)")
    }

    private func composedBalance() -> Text {
        let parts = WalletFormatting.fiatParts(totalFiat, currencyCode: currencyCode)
        let currency = Text(verbatim: parts.currency)
            .font(UniTypography.BalanceCard.currency)
            .foregroundStyle(UniColors.Text.secondary)
        let integer = Text(verbatim: parts.integer)
            .font(UniTypography.BalanceCard.balance)
            .foregroundStyle(UniColors.Text.primary)
        let fraction = Text(verbatim: parts.fraction ?? "")
            .font(UniTypography.BalanceCard.balance)
            .foregroundStyle(UniColors.Text.tertiary)
        let gap = Text(verbatim: " ")
            .font(UniTypography.BalanceCard.currency)

        if parts.currency.isEmpty {
            return Text("\(integer)\(fraction)")
        }
        return parts.currencyLeads
            ? Text("\(currency)\(gap)\(integer)\(fraction)")
            : Text("\(integer)\(fraction)\(gap)\(currency)")
    }

    @ViewBuilder
    private var zeroBody: some View {
        Text("Add crypto to get started — receive or transfer it from another wallet.")
            .font(UniTypography.BalanceCard.zeroPrompt)
            .foregroundStyle(UniColors.Text.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
            .padding(.bottom, 16)

        UniButton(title: "Add funds", variant: .primary, systemImage: "plus") {
            onAddFunds()
        }
        .accessibilityLabel(Text("Add funds, opens Receive"))
    }

    private func switchWallet() {
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        onSwitchWallet()
    }

    private func toggleHidden() {
        balanceDisclosureBinding.wrappedValue.toggle()
        UniHapticEngine.shared.play(.toggle)
    }

    private func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        if reduceMotion {
            isHidden = hidden
        } else {
            withAnimation {
                isHidden = hidden
            }
        }
    }

    private var accessibilityLabel: Text {
        if isHidden {
            return Text("Total balance hidden, double tap the eye button to reveal")
        }
        let value = WalletFormatting.fiat(totalFiat, currencyCode: currencyCode)
        if resolvedState == .zero {
            return Text("Total balance \(value). Add crypto to get started.")
        }
        return Text("Total balance \(value)")
    }
}

private struct BalanceCardDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label
                .padding(.bottom, configuration.isExpanded ? 2 : 0)

            if configuration.isExpanded {
                configuration.content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BalanceCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(UniSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: UniRadius.hero, style: .continuous)
                    .fill(UniColors.Card.background)
            }
            .containerShape(RoundedRectangle(cornerRadius: UniRadius.hero, style: .continuous))
    }
}
