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
    let pnlSummary: WalletPnLSummaryDTO?
    let showsFirstRefreshBalanceSkeleton: Bool
    let onSwitchWallet: () -> Void
    let onAddFunds: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @GRDBStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var isHidden: Bool = false

    init(
        walletId: UUID?,
        walletName: String,
        totalFiat: Decimal,
        currencyCode: String,
        lastUpdated: Date?,
        pnlSummary: WalletPnLSummaryDTO? = nil,
        showsFirstRefreshBalanceSkeleton: Bool = false,
        onSwitchWallet: @escaping () -> Void,
        onAddFunds: @escaping () -> Void
    ) {
        self.walletId = walletId
        self.walletName = walletName
        self.totalFiat = totalFiat
        self.currencyCode = currencyCode
        self.lastUpdated = lastUpdated
        self.pnlSummary = pnlSummary
        self.showsFirstRefreshBalanceSkeleton = showsFirstRefreshBalanceSkeleton
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
            VStack(alignment: .leading, spacing: 0) {
                balanceSummary

                if resolvedState == .zero {
                    zeroBody
                }
            }
            .padding(.vertical, UniSpacing.xs)
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

    private var balanceSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text("Total balance")
                .font(UniTypography.BalanceCard.label)
                .foregroundStyle(UniColors.Text.secondary)
                .padding(.top, 24)
                .padding(.bottom, 8)

            tappableBalanceNumber

            if resolvedState == .value || showsFirstRefreshBalanceSkeleton {
                pnlRow
            }
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

    @ViewBuilder
    private var balanceNumber: some View {
        if showsFirstRefreshBalanceSkeleton {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(UniColors.Skeleton.base)
                .frame(width: 184, height: 44)
                .unredacted()
        } else {
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
    private var pnlRow: some View {
        if showsFirstRefreshBalanceSkeleton {
            HStack(spacing: UniSpacing.s) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(UniColors.Skeleton.base)
                    .frame(width: 56, height: 12)
                Spacer(minLength: UniSpacing.s)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(UniColors.Skeleton.base)
                    .frame(width: 112, height: 12)
            }
            .padding(.top, 14)
            .unredacted()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
                Text("24h PnL")
                    .font(UniTypography.caption2)
                    .foregroundStyle(UniColors.Text.secondary)

                Spacer(minLength: UniSpacing.s)

                Text(verbatim: pnlText)
                    .font(UniTypography.caption2.weight(.semibold))
                    .foregroundStyle(pnlColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .padding(.top, 14)
        }
    }

    private var pnlText: String {
        let state = pnlSummary?.state ?? .collecting
        switch state {
        case .collecting:
            return String.apertureLocalized("Collecting history")
        case .unavailable:
            return String.apertureLocalized("Unavailable")
        case .complete, .partial:
            guard !isHidden else { return "••••  ••••" }
            guard let amount = pnlSummary?.displayChange else {
                return String.apertureLocalized("Unavailable")
            }
            let amountText = signedFiat(amount)
            let percentageText = pnlSummary?.returnPercent.map(signedPercentage)
            let value = percentageText.map { "\(amountText) (\($0))" } ?? amountText
            return state == .partial ? "\(value) · \(String.apertureLocalized("Partial"))" : value
        }
    }

    private var pnlColor: Color {
        guard let summary = pnlSummary,
              summary.state == .complete || summary.state == .partial,
              let change = summary.displayChange
        else { return UniColors.Text.secondary }
        if change > 0 { return UniColors.Text.success }
        if change < 0 { return UniColors.Send.negative }
        return UniColors.Text.secondary
    }

    private func signedFiat(_ amount: Decimal) -> String {
        let formatted = WalletFormatting.fiat(abs(amount), currencyCode: currencyCode)
        if amount > 0 { return "+\(formatted)" }
        if amount < 0 { return "-\(formatted)" }
        return formatted
    }

    private func signedPercentage(_ percentage: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = .current
        let value = formatter.string(from: NSDecimalNumber(decimal: abs(percentage))) ?? "0"
        if percentage > 0 { return "+\(value)%" }
        if percentage < 0 { return "-\(value)%" }
        return "\(value)%"
    }

    @ViewBuilder
    private var zeroBody: some View {
        ZStack(alignment: .topLeading) {
            zeroVisibleBody
                .opacity(isHidden ? 0 : 1)
                .allowsHitTesting(!isHidden)
                .accessibilityHidden(isHidden)

            zeroSkeletonBody
                .opacity(isHidden ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var zeroVisibleBody: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var zeroSkeletonBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                skeletonBar(widthFraction: 0.94, height: 13)
                skeletonBar(widthFraction: 0.68, height: 13)
            }
            .padding(.top, 18)
            .padding(.bottom, 16)

            Capsule(style: .continuous)
                .fill(UniColors.Skeleton.base)
                .frame(height: 47)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func skeletonBar(widthFraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(UniColors.Skeleton.base)
                .frame(width: max(0, proxy.size.width * widthFraction), height: height)
        }
        .frame(height: height)
    }

    private func switchWallet() {
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        onSwitchWallet()
    }

    private func toggleHidden() {
        setHidden(!isHidden)
        UniHapticEngine.shared.play(.toggle)
    }

    private func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
    }

    private var accessibilityLabel: Text {
        if isHidden {
            return Text("Total balance hidden, double tap the eye button to reveal")
        }
        let value = WalletFormatting.fiat(totalFiat, currencyCode: currencyCode)
        if resolvedState == .zero {
            return Text("Total balance \(value). Add crypto to get started.")
        }
        return Text("Total balance \(value). \(pnlAccessibilityDescription)")
    }

    private var pnlAccessibilityDescription: String {
        guard !isHidden else { return String.apertureLocalized("24-hour profit and loss hidden") }
        let state = pnlSummary?.state ?? .collecting
        switch state {
        case .collecting:
            return String.apertureLocalized("24-hour profit and loss is collecting history")
        case .unavailable:
            return String.apertureLocalized("24-hour profit and loss is unavailable")
        case .complete, .partial:
            guard let amount = pnlSummary?.displayChange else {
                return String.apertureLocalized("24-hour profit and loss is unavailable")
            }
            let amountText = signedFiat(amount)
            let percentage = pnlSummary?.returnPercent.map(signedPercentage)
            let coverage = state == .partial ? String.apertureLocalized("Partial coverage") : String.apertureLocalized("Complete coverage")
            if let percentage {
                return "24-hour profit and loss \(amountText), \(percentage). \(coverage)"
            }
            return "24-hour profit and loss \(amountText). \(coverage)"
        }
    }
}

private struct BalanceCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(UniSpacing.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: UniRadius.hero, style: .continuous)
                    .fill(UniColors.Card.background)
            }
            .containerShape(RoundedRectangle(cornerRadius: UniRadius.hero, style: .continuous))
    }
}
