import SwiftUI

// MARK: - Send v2 nav chrome
//
// The v2 screens render on the bloom with their own glass nav chrome (the
// flow hides the wallet-home nav bar so the bloom reads full-bleed). These
// pieces are the handoff's *"glass back button + 'Send USDT'"* header and
// the small glass nav icon buttons (info, share). Native glass via
// `.glassEffect` (Rule #3); SF Symbols only (Rule #7); `UniColors` roles
// (Rule #4); the back chevron mirrors in RTL automatically (Rule #11).

/// A glass nav bar: leading glass back button, centered title, optional
/// trailing slot. Sits at the top of a v2 screen on the bloom.
struct SendV2NavBar<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, onBack: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.onBack = onBack
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            Text(verbatim: title)
                .font(UniTypography.headline)
                .foregroundStyle(UniColors.Text.primary)
                .accessibilityAddTraits(.isHeader)

            HStack {
                SendV2NavIconButton(systemName: "chevron.backward", accessibility: "Back", action: onBack)
                Spacer()
                trailing()
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.xs)
    }
}

extension SendV2NavBar where Trailing == EmptyView {
    init(title: String, onBack: @escaping () -> Void) {
        self.init(title: title, onBack: onBack, trailing: { EmptyView() })
    }
}

/// A small circular glass icon button for the nav bar (back / info /
/// share / close). 38×38 glass capsule with an SF Symbol, with the
/// `.contentShape(Circle())` hit-test invariant (Rule #19).
struct SendV2NavIconButton: View {
    let systemName: String
    let accessibility: LocalizedStringKey
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var tapTick: Int = 0

    var body: some View {
        Button {
            tapTick &+= 1
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(UniColors.Text.primary)
                .frame(width: 38, height: 38)
                .modifier(IconSurface(reduceTransparency: reduceTransparency))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: tapTick)
        .accessibilityLabel(Text(accessibility))
    }

    private struct IconSurface: ViewModifier {
        let reduceTransparency: Bool
        func body(content: Content) -> some View {
            if reduceTransparency {
                content
                    .background(Circle().fill(UniColors.Send.cardSolidFallback))
                    .overlay(Circle().stroke(UniColors.Send.cardHairline, lineWidth: 0.5))
            } else {
                content.glassEffect(.regular, in: .circle)
            }
        }
    }
}

// MARK: - Paste validation card (Flow D1 / D2)

/// The card shown after a Paste — the handoff's validated-paste card
/// (D1: green Valid chip + "Not in your address book"), the wrong-network
/// error state (D2: red ring + "Did you mean … on Solana"), or invalid.
struct SendV2PasteCard: View {
    let validation: SendV2Model.PasteValidation
    let address: String
    let onSwitchNetwork: (SendV2MockData.CrossNetworkSuggestion) -> Void
    let onClear: () -> Void

    var body: some View {
        switch validation {
        case let .valid(network, inAddressBook):
            validCard(network: network, inAddressBook: inAddressBook)
        case let .wrongNetwork(suggested):
            wrongNetworkCard(suggested: suggested)
        case let .invalid(network):
            invalidCard(network: network)
        }
    }

    @ViewBuilder
    private func validCard(network: SupportedChain, inAddressBook: Bool) -> some View {
        SendGlassCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                HStack(spacing: UniSpacing.xs) {
                    chainBadge(network)
                    Text("From clipboard")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                    Spacer(minLength: 0)
                    UniBadge(text: "Valid · \(network.displayName)", kind: .success, systemImage: "checkmark")
                }
                if !inAddressBook {
                    UniDivider()
                    HStack(spacing: UniSpacing.xs) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 14))
                            .foregroundStyle(UniColors.Icon.secondary)
                        Text("Not in your address book — save as a contact after sending.")
                            .font(UniTypography.caption1)
                            .foregroundStyle(UniColors.Text.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .uniHaptic(.contextualImpact(.tap), trigger: address)
    }

    @ViewBuilder
    private func wrongNetworkCard(suggested: SendV2MockData.CrossNetworkSuggestion) -> some View {
        SendGlassCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                HStack(spacing: UniSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(UniColors.Send.negative)
                    Text("Wrong network")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Send.negative)
                    Spacer(minLength: 0)
                }
                Text("This address is for a different network. Sending here would lose the funds.")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                UniDivider()

                // "Did you mean" fix.
                HStack(spacing: UniSpacing.s) {
                    chainBadge(suggested.network)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Send \(suggested.symbol) on \(suggested.network.displayName)")
                            .font(UniTypography.subheadlineEmphasized)
                            .foregroundStyle(UniColors.Text.primary)
                        Text(verbatim: "\(suggested.balanceLabel) · \(suggested.feeLabel)")
                            .font(UniTypography.caption2)
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: UniSpacing.s) {
                    UniButton(title: "Switch to \(suggested.network.displayName)", variant: .primary) {
                        onSwitchNetwork(suggested)
                    }
                    UniButton(title: "Clear", variant: .secondary, action: onClear)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.xl, style: .continuous)
                .stroke(UniColors.Send.negative.opacity(0.65), lineWidth: 1.5)
        )
        .uniHaptic(.error, trigger: address)
    }

    @ViewBuilder
    private func invalidCard(network: SupportedChain) -> some View {
        SendGlassCard {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(UniColors.Send.negative)
                Text("Not a valid address for \(network.displayName).")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Send.negative)
                Spacer(minLength: 0)
                Button("Clear", action: onClear)
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.link)
            }
        }
        .uniHaptic(.error, trigger: address)
    }

    @ViewBuilder
    private func chainBadge(_ network: SupportedChain) -> some View {
        if let asset = network.logoAssetName {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(Circle())
                .accessibilityHidden(true)
        }
    }
}
