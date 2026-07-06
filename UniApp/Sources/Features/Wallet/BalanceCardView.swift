import SwiftUI

/// Wallet-home balance summary card.
///
/// The card renders only the wallet identity, current total, visibility
/// toggle, and zero-state CTA. Chart UI, chart range tabs, chart scrubbing, and
/// history reconstruction are intentionally not part of this surface.
struct BalanceCardView: View {
    let walletId: UUID?
    let walletName: String
    let totalFiat: Decimal
    let currencyCode: String
    let lastUpdated: Date?
    let onSwitchWallet: () -> Void
    let onAddFunds: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    private enum CardState: Equatable { case value, zero, hidden }

    private var boostContrast: Bool { legibilityWeight == .bold }

    private var resolvedState: CardState {
        if isHidden { return .hidden }
        if totalFiat <= 0 { return .zero }
        return .value
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            watermark
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 2)

                Text("Total balance")
                    .font(UniTypography.BalanceCard.label)
                    .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                Group {
                    switch resolvedState {
                    case .zero:
                        zeroBody
                    case .hidden, .value:
                        valueBody
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.balanceCard, style: .continuous))
        .overlay(hairlineOverlay)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: resolvedState)
        .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: totalFiat)
    }

    private static func updatedCaption(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return String(format: String.apertureLocalized("Updated %@"), relative)
    }

    private var cardSurface: some View {
        UniColors.Background.secondary
    }

    @ViewBuilder
    private var hairlineOverlay: some View {
        if colorScheme == .light {
            RoundedRectangle(cornerRadius: UniRadius.balanceCard, style: .continuous)
                .stroke(UniColors.BalanceCard.hairline(colorScheme), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var watermark: some View {
        Image(colorScheme == .dark ? "IrisWatermarkWhite" : "IrisWatermarkInk")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 220, height: 220)
            .opacity(UniColors.BalanceCard.watermarkOpacity(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: -110, y: -30)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 1) {
                Button(action: switchWallet) {
                    HStack(spacing: 3) {
                        Text(verbatim: walletName)
                            .font(UniTypography.BalanceCard.walletName)
                            .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Switch wallet, currently \(walletName)"))

                if let lastUpdated {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(verbatim: Self.updatedCaption(lastUpdated))
                            .font(UniTypography.caption2)
                            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
                            .lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 44, alignment: .top)

            Spacer(minLength: UniSpacing.xs)

            Button(action: toggleHidden) {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(UniColors.BalanceCard.eyeGlyph(colorScheme))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(UniColors.BalanceCard.eyeButtonFill(colorScheme)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel(Text(isHidden ? "Show balance" : "Hide balance"))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var valueBody: some View {
        tappableBalanceNumber
            .padding(.bottom, UniSpacing.balanceCardBottom)
    }

    private var tappableBalanceNumber: some View {
        balanceNumber
            .contentShape(Rectangle())
            .onTapGesture { toggleHidden() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(isHidden ? "Show balance" : "Hide balance"))
    }

    private var balanceNumber: some View {
        let parts = WalletFormatting.fiatParts(totalFiat, currencyCode: currencyCode)
        let currencyRun = Text(verbatim: parts.currency + (parts.currency.isEmpty ? "" : " "))
            .font(UniTypography.BalanceCard.currency)
            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))

        return Group {
            if isHidden {
                let dots = Text(verbatim: "••••••")
                    .font(UniTypography.BalanceCard.balance)
                    .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme))
                Text("\(currencyRun)\(dots)")
                    .tracking(2)
            } else {
                composedBalance()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .contentTransition(reduceMotion ? .identity : .numericText())
        .environment(\.layoutDirection, .leftToRight)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: totalFiat)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: isHidden)
    }

    private func composedBalance() -> Text {
        let parts = WalletFormatting.fiatParts(totalFiat, currencyCode: currencyCode)
        let currency = Text(verbatim: parts.currency)
            .font(UniTypography.BalanceCard.currency)
            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
        let integer = Text(verbatim: parts.integer)
            .font(UniTypography.BalanceCard.balance)
            .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme))
        let fraction = Text(verbatim: parts.fraction ?? "")
            .font(UniTypography.BalanceCard.balance)
            .foregroundStyle(UniColors.BalanceCard.decimals(colorScheme, boostContrast: boostContrast))
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
        tappableBalanceNumber

        Text("Add crypto to get started — receive or transfer it from another wallet.")
            .font(UniTypography.BalanceCard.zeroPrompt)
            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
            .padding(.bottom, 16)

        UniButton(title: "Add funds", variant: .primary, systemImage: "plus") {
            onAddFunds()
        }
        .padding(.bottom, UniSpacing.l)
        .accessibilityLabel(Text("Add funds, opens Receive"))
    }

    private func switchWallet() {
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        onSwitchWallet()
    }

    private func toggleHidden() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
            isHidden.toggle()
        }
        UniHapticEngine.shared.play(.toggle)
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
