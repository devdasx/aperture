import SwiftUI

/// Send · Step 5 — Review. Shows the complete, validated `SendDraft`
/// honestly: asset, network, from, each recipient + amount, total, the
/// chosen fee + fiat, and any memo / tag / comment / OP_RETURN / reserve
/// note that's set. Every figure is real — this is the draft the sign step
/// will consume verbatim.
///
/// **The honest boundary (Rule #16).** Signing + broadcast do not exist yet
/// (the next increment). This screen does NOT fake a send or a tx hash. The
/// primary action plainly states that signing is the next step being built
/// and closes the flow rather than pretending to send. Everything up to the
/// draft is 100% real; this one boundary is named, not hidden.
struct SendReviewView: View {
    let draft: SendDraft
    let currencyCode: String
    let assetUnitPrice: Decimal?
    let nativeUnitPrice: Decimal?
    /// Close the whole Send flow (the sheet) — the honest action while
    /// signing is unbuilt.
    let onClose: () -> Void

    private var chain: SupportedChain { draft.chain }
    private var assetSymbol: String { draft.tokenSymbol ?? chain.ticker }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                amountHero
                detailsCard
                if hasExtras { extrasCard }
                boundaryNote
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.xxxl + UniSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary)
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoinTitleBar(chain: chain, tokenSymbol: draft.tokenSymbol, verb: "Review")
            }
        }
    }

    // MARK: - Amount hero

    private var amountHero: some View {
        VStack(spacing: UniSpacing.xs) {
            Text(verbatim: "\(WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimals)) \(assetSymbol)")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let price = assetUnitPrice, price > 0 {
                Text(verbatim: WalletFormatting.fiat(draft.totalAmount * price, currencyCode: currencyCode))
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UniSpacing.m)
    }

    // MARK: - Details

    private var detailsCard: some View {
        UniCard(padding: 0) {
            VStack(spacing: 0) {
                detailRow("Network", value: chain.displayName)
                divider
                detailRow("From", value: WalletFormatting.shortAddress(draft.fromAddress, prefix: 8, suffix: 6), mono: true)
                divider
                recipientRows
                divider
                feeRow
            }
        }
    }

    @ViewBuilder
    private var recipientRows: some View {
        if draft.recipients.count == 1, let r = draft.recipients.first {
            detailRow("To", value: r.name ?? WalletFormatting.shortAddress(r.address, prefix: 8, suffix: 6), mono: r.name == nil)
        } else {
            ForEach(Array(draft.recipients.enumerated()), id: \.offset) { offset, r in
                multiRecipientRow(index: offset + 1, recipient: r)
                if offset < draft.recipients.count - 1 { divider }
            }
            divider
            detailRow("Total", value: "\(WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimals)) \(assetSymbol)", mono: true)
        }
    }

    private func multiRecipientRow(index: Int, recipient r: SendRecipientAmount) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Text(verbatim: "\(index)")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: r.name ?? WalletFormatting.shortAddress(r.address, prefix: 8, suffix: 6))
                    .font(UniTypography.body.monospaced())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: "\(WalletFormatting.native(r.amount, decimals: draft.effectiveDecimals)) \(assetSymbol)")
                .font(UniTypography.callout.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    private var feeRow: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Text("Network fee")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(WalletFormatting.native(draft.fee.estimatedTotalNative, decimals: 8)) \(chain.ticker)")
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                if let price = nativeUnitPrice, price > 0 {
                    Text(verbatim: WalletFormatting.fiat(draft.fee.estimatedTotalNative * price, currencyCode: currencyCode))
                        .font(UniTypography.caption1.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Text(verbatim: draft.fee.tier.label)
                    .font(UniTypography.caption2)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    // MARK: - Extras (memo / tag / comment / op_return / max)

    private var hasExtras: Bool { !extras.isEmpty }

    /// One extra row's content, resolved into a stable, order-preserving
    /// list so the card can interleave dividers without ViewBuilder
    /// statement gymnastics.
    private struct Extra: Identifiable {
        let id = UUID()
        let key: LocalizedStringKey
        let value: String
    }

    private var extras: [Extra] {
        var rows: [Extra] = []
        if let memo = memoSummary {
            rows.append(Extra(key: memoLabel, value: memo))
        }
        if let data = draft.opReturn, let text = String(data: data, encoding: .utf8), !text.isEmpty {
            rows.append(Extra(key: "OP_RETURN", value: text))
        }
        if let utxos = draft.selectedUTXOs, !utxos.isEmpty, chain.family == .bitcoin {
            rows.append(Extra(key: "Coins", value: String(localized: "\(utxos.count) selected")))
        }
        if draft.isMaxSend {
            rows.append(Extra(key: "Amount", value: String(localized: "Sending the maximum")))
        }
        return rows
    }

    private var extrasCard: some View {
        UniCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(extras.enumerated()), id: \.element.id) { offset, extra in
                    extraRow(extra.key, value: extra.value)
                    if offset < extras.count - 1 { divider }
                }
            }
        }
    }

    private var memoLabel: LocalizedStringKey {
        switch draft.chain.family {
        case .ripple: return "Destination tag"
        case .ton:    return "Comment"
        default:      return "Memo"
        }
    }

    private var memoSummary: String? {
        switch draft.memo {
        case .none: return nil
        case .destinationTag(let t): return String(t)
        case .tonComment(let s), .splMemo(let s), .text(let s):
            return s.isEmpty ? nil : s
        case .stellarMemo(let m):
            switch m {
            case .text(let s): return s.isEmpty ? nil : s
            case .id(let i): return String(i)
            case .hashHex(let h): return h.isEmpty ? nil : h
            }
        }
    }

    // MARK: - Honest boundary note

    private var boundaryNote: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "hammer")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text("Signing is the next step")
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text("Everything above is ready and real. Signing and broadcasting the transaction is the part we're building next — nothing has been sent.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(UniSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Fill.quaternary)
        )
    }

    // MARK: - Action bar (honest — closes, does not "send")

    private var actionBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(title: "Done", variant: .primary, action: onClose)
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.xs)
        }
    }

    // MARK: - Row primitives

    private var divider: some View {
        UniDivider().padding(.leading, UniSpacing.m)
    }

    private func detailRow(_ key: LocalizedStringKey, value: String, mono: Bool = false) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(mono ? UniTypography.body.monospaced() : UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    private func extraRow(_ key: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(UniTypography.callout)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.trailing)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(3)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }
}
