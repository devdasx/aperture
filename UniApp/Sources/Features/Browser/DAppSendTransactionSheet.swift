import SwiftUI

/// Detail sheet for `eth_sendTransaction` (EVM) and Solana
/// `signAndSendTransaction`. The user reads what the dApp asked for
/// — from, to, value, gas, contract data. Aperture has no broadcast
/// pipeline yet, so the only action is Dismiss, which returns an
/// honest JSON-RPC 4200 ("not supported yet") to the page.
///
/// **Sheet shape (Rule #15).** `NavigationStack` + `ScrollView`.
/// `.large` detent only.
///
/// **Address rendering.** The `to` address is shown in short form
/// (`0x1234…ABCD`) with a "Show full" affordance that swaps to the
/// EIP-55 checksummed form. Honest about truncation — the user can
/// always see the full thing.
///
/// **Honesty (Rule #16).** When the contract `data` is present we
/// surface the first four bytes (the function selector) as a
/// hex preview and caption that "Aperture doesn't decode ABI
/// without source." We never invent a "this is a Uniswap swap"
/// label without the source code; we name what we know.
struct DAppSendTransactionSheet: View {
    let request: DAppRequestRouter.SendTransactionRequest
    let router: DAppRequestRouter

    @Environment(\.dismiss) private var dismiss

    @State private var isShowingFullAddress: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    identityHero
                    summaryCard
                    addressCard
                    valueCard
                    if hasContractData {
                        contractDataCard
                    }
                    warningStatement
                    Spacer(minLength: UniSpacing.m)
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(UniColors.Background.primary)
            .navigationTitle("Send transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        router.rejectPending()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionRegion
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var identityHero: some View {
        HStack(spacing: UniSpacing.m) {
            BrowserFaviconView(
                url: request.origin.iconURL.flatMap(URL.init(string:)),
                fallbackLetter: request.origin.title,
                size: .hero
            )

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: request.origin.title)
                    .font(UniTypography.title2)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(2)
                Text(verbatim: request.origin.host)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                LabelRow(label: "Network") {
                    Text(verbatim: request.chain.displayName)
                }
                if let gas = request.gasHex, !gas.isEmpty {
                    LabelRow(label: "Gas estimate") {
                        Text(verbatim: gas)
                    }
                }
                LabelRow(label: "Network fee") {
                    Text("Estimated at sign time")
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var addressCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                addressRow(label: "From", address: request.from, toggleable: false)
                addressRow(label: "To", address: request.to, toggleable: true)
            }
        }
    }

    @ViewBuilder
    private func addressRow(label: LocalizedStringKey, address: String, toggleable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            Text(label)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: isShowingFullAddress
                    ? address
                    : WalletFormatting.shortAddress(address))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                    .textSelection(.enabled)
                    .lineLimit(isShowingFullAddress ? nil : 1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if toggleable {
                Button {
                    isShowingFullAddress.toggle()
                } label: {
                    Text(isShowingFullAddress ? "Hide full" : "Show full")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.link)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var valueCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniCaption(
                    text: "Amount",
                    color: UniColors.Text.tertiary
                )
                Text(verbatim: formattedValue)
                    .font(UniTypography.title2.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                UniFootnote(
                    text: "Raw value: \(rawValueDisplay)",
                    color: UniColors.Text.tertiary
                )
            }
        }
    }

    @ViewBuilder
    private var contractDataCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniCaption(
                    text: "Contract data",
                    color: UniColors.Text.tertiary
                )
                Text(verbatim: functionSelector)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                    .textSelection(.enabled)
                UniFootnote(
                    text: "Aperture doesn't decode contract calls without the source. Read the selector against the dApp's docs.",
                    color: UniColors.Text.tertiary
                )
            }
        }
    }

    @ViewBuilder
    private var warningStatement: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Status.warningForeground)
                .frame(width: 20)
            UniFootnote(
                text: "Sending a transaction is irreversible. Only confirm transactions you initiated and understand.",
                color: UniColors.Text.secondary
            )
        }
    }

    /// Aperture has no transaction-broadcast pipeline yet, so there
    /// is no "Send" button — pretending to send and returning a fake
    /// hash would be the most damaging lie this sheet could tell
    /// (Rule #16). The user sees the request details, an honest
    /// status line, and a single Dismiss that returns JSON-RPC 4200
    /// to the dApp.
    @ViewBuilder
    private var actionRegion: some View {
        VStack(spacing: UniSpacing.s) {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 20)
                UniFootnote(
                    text: "Sending transactions from the browser isn't available in Aperture yet. The request will be returned to the dApp unsigned.",
                    color: UniColors.Text.secondary
                )
            }
            GlassEffectContainer(spacing: UniSpacing.s) {
                UniButton(title: "Dismiss", variant: .primary) {
                    router.failPending(DAppRequestError(
                        code: 4200,
                        message: "Sending transactions from the browser isn't supported yet"
                    ))
                    dismiss()
                }
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.bottom, UniSpacing.xs)
        .background(
            UniColors.Background.primary
                .opacity(0.92)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Derived

    /// The decoded native amount, formatted by `WalletFormatting`.
    /// Today the dApp sends the value as a hex-encoded big number;
    /// we render it raw (the formatter pass arrives when the
    /// bridge wires real decimals + ticker resolution).
    private var formattedValue: String {
        let raw = request.valueHex
        if raw == "0x0" || raw == "0x00" || raw.isEmpty {
            return "0 \(request.chain.ticker)"
        }
        return "\(raw) \(request.chain.ticker)"
    }

    private var rawValueDisplay: String {
        request.valueHex
    }

    private var hasContractData: Bool {
        !request.dataHex.isEmpty && request.dataHex != "0x"
    }

    /// First 10 chars of the data hex are `0x` + 8 hex chars (the
    /// 4-byte function selector).
    private var functionSelector: String {
        let raw = request.dataHex
        if raw.count >= 10 {
            return String(raw.prefix(10))
        }
        return raw
    }
}

// MARK: - LabelRow

private struct LabelRow<TrailingValue: View>: View {
    let label: LocalizedStringKey
    let value: TrailingValue

    init(label: LocalizedStringKey, @ViewBuilder value: () -> TrailingValue) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            Text(label)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(width: 96, alignment: .leading)
            value
                .font(UniTypography.subheadlineEmphasized)
                .foregroundStyle(UniColors.Text.primary)
            Spacer(minLength: 0)
        }
    }
}
