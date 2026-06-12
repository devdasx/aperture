import SwiftUI

/// **Send · Screen 3 — Review.**
///
/// The token tile with its network badge, the amount + fiat, a detail
/// card (To, Network, Network fee [editable → the asset-shaped Advanced
/// sheet], Total), a first-send warning, and the swipe-to-send track as
/// the footer (the commit, not a button).
///
/// **Layers (Rule #2 §B.3):** content layer — the tile + detail card on
/// `Background.primary`. Functional layer — the nav bar + the bespoke
/// swipe track (the track is its own brand surface, not a glass control).
///
/// **Honesty (Rule #2 §A.7 / Rule #16).** The total names that the fee is
/// approximate for token sends (paid in the network's native asset); the
/// first-send warning is plain. All money is tabular.
struct SendReviewView: View {
    @Bindable var draft: SendDraft
    let onEditFee: () -> Void
    let onCommit: () -> Void
    let onOpenFeeGuide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.m) {
                    amountHero
                    detailCard
                    if draft.isFirstSend {
                        firstSendNote
                    }
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.s)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Amount hero

    private var amountHero: some View {
        VStack(spacing: UniSpacing.xs) {
            if let asset = draft.asset {
                SendTokenTile(asset: asset, size: 58, ringColor: UniColors.Background.primary)
                    .padding(.bottom, UniSpacing.xxs)
            }
            Text(verbatim: "\(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)")
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
            Text(verbatim: "≈ \(WalletFormatting.fiat(draft.fiatAmount, currencyCode: activeCurrencyCode))")
                .font(UniTypography.footnote)
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UniSpacing.s)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Detail card

    private var detailCard: some View {
        VStack(spacing: 0) {
            detailRow(key: "To") {
                Text(verbatim: draft.recipientDisplay)
                    .font(UniTypography.subheadlineEmphasized.monospaced())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            UniDivider()
            detailRow(key: "Network") {
                HStack(spacing: UniSpacing.xs) {
                    networkBadge
                    Text(verbatim: draft.network?.displayName ?? "")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                }
            }
            UniDivider()
            feeRow
            UniDivider()
            detailRow(key: "Total") {
                Text(verbatim: WalletFormatting.fiat(draft.totalFiat, currencyCode: activeCurrencyCode))
                    .font(UniTypography.subheadlineEmphasized)
                    .monospacedDigit()
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }

    @ViewBuilder
    private func detailRow<Trailing: View>(
        key: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            trailing()
        }
        .padding(.vertical, UniSpacing.s)
    }

    /// The fee row carries an info button (guide) on the key, the fee
    /// chip, and — when the network has an Advanced sheet — an Edit
    /// affordance that opens it.
    private var feeRow: some View {
        HStack(spacing: UniSpacing.s) {
            Button(action: onOpenFeeGuide) {
                HStack(spacing: UniSpacing.xxs) {
                    Text("Network fee")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("What's a network fee?"))

            Spacer(minLength: UniSpacing.s)

            HStack(spacing: UniSpacing.xs) {
                feeChip
                if SendAdvancedParams.hasAdvancedSheet(for: draft.network) {
                    Button(action: onEditFee) {
                        Text("Edit")
                            .font(UniTypography.caption1.weight(.bold))
                            .foregroundStyle(UniColors.Text.primary)
                            .padding(.horizontal, UniSpacing.xs)
                            .padding(.vertical, UniSpacing.xxs)
                            .background(Capsule().fill(UniColors.Fill.tertiary))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Edit network fee"))
                }
            }
        }
        .padding(.vertical, UniSpacing.s)
    }

    private var feeChip: some View {
        HStack(spacing: UniSpacing.xxs) {
            Image(systemName: feeIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(feeSpeedColor)
            Text(feeSpeedLabel)
                .font(UniTypography.caption1.weight(.bold))
                .foregroundStyle(feeSpeedColor)
            Text(verbatim: "· \(WalletFormatting.fiat(draft.networkFeeFiat, currencyCode: activeCurrencyCode))")
                .font(UniTypography.caption1.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.primary)
        }
        .padding(.horizontal, UniSpacing.s)
        .padding(.vertical, UniSpacing.xxs)
        .background(Capsule().fill(UniColors.Fill.tertiary))
    }

    // MARK: - First-send note

    private var firstSendNote: some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(UniColors.Status.warningForeground)
            Text("First time sending to this address. Double-check it's correct.")
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.xs)
    }

    // MARK: - Footer (swipe to send)

    private var footer: some View {
        VStack(spacing: 0) {
            SendSwipeToCommit(onCommit: onCommit)
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.xs)
                .padding(.bottom, UniSpacing.s)
        }
        .background(UniColors.Background.primary)
    }

    // MARK: - Derived

    @ViewBuilder
    private var networkBadge: some View {
        if let chain = draft.network, let assetName = chain.logoAssetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .clipShape(Circle())
                .accessibilityHidden(true)
        }
    }

    private var feeSpeedLabel: LocalizedStringKey {
        switch draft.feeSelection {
        case .economy:     return "Economy"
        case .recommended: return "Fast"
        case .custom:      return "Custom"
        }
    }

    private var feeIcon: String {
        switch draft.feeSelection {
        case .economy:     return "tortoise.fill"
        case .recommended: return "bolt.fill"
        case .custom:      return "slider.horizontal.3"
        }
    }

    private var feeSpeedColor: Color {
        draft.feeSelection == .recommended ? UniColors.Send.positive : UniColors.Text.secondary
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey)
            ?? CurrencyPreference.defaultCode
    }
}
