import SwiftUI

/// Detail sheet for `eth_sendTransaction` (EVM). The user reads what the
/// dApp asked for — from, to, value, gas, contract data — then "Confirm &
/// send" signs it with the wallet key and broadcasts it on-chain (the same
/// `SwapEVMSigner` + `BroadcastService` pipeline the in-app Swap uses, gated
/// by biometrics), returning the real tx hash to the page (2026-06-17).
/// (Solana `signAndSendTransaction` is not wired yet and still returns an
/// honest JSON-RPC error rather than a fabricated signature — Rule #16.)
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

    /// Per-action Face ID gate (2026-06-20, Security settings). Default ON.
    @AppStorage("requireBiometricForDApp") private var requireForDApp: Bool = true

    @State private var isShowingFullAddress: Bool = false
    @State private var isSending: Bool = false
    @State private var sendError: String?

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
                        .tint(UniColors.Button.text)
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
                if let gas = formattedGas {
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

    /// Real send (2026-06-17). On "Confirm & send" the request is signed
    /// with the wallet's key and broadcast on-chain via the same pipeline
    /// the in-app Swap uses (`EVMDAppSigner.sendTransaction`), gated behind a
    /// biometric check when available. The real tx hash is returned to the
    /// dApp via `router.approveSend(txHash:)`; a node rejection surfaces its
    /// honest reason inline and the request stays open to retry or cancel.
    @ViewBuilder
    private var actionRegion: some View {
        VStack(spacing: UniSpacing.s) {
            if let sendError {
                HStack(alignment: .top, spacing: UniSpacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UniColors.Status.errorForeground)
                        .frame(width: 20)
                    Text(verbatim: sendError)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GlassEffectContainer(spacing: UniSpacing.s) {
                UniButton(
                    title: isSending ? "Sending…" : "Confirm & send",
                    variant: .primary,
                    isLoading: isSending
                ) {
                    confirmAndSend()
                }
                .disabled(isSending)
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.top, UniSpacing.s)
        .padding(.bottom, UniSpacing.s)
        // A fully OPAQUE pinned bar (was 0.92 — the translucency let the
        // scrolling cards bleed through and read as if the CTA were
        // hidden). The bar sits in the bottom safe-area inset so the
        // button is always reachable and clears the home indicator.
        .background(
            UniColors.Background.primary
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// Authenticate (biometric when available — this moves funds), then sign
    /// + broadcast the real transaction and hand the hash back to the dApp.
    private func confirmAndSend() {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        Task { @MainActor in
            defer { isSending = false }
            let biometrics = BiometricService()
            if biometrics.isAvailable && requireForDApp {
                let outcome = await biometrics.authenticate(reason: "Confirm sending this transaction")
                if case .failure = outcome {
                    sendError = String.apertureLocalized("Authentication failed — the transaction wasn’t sent.")
                    return
                }
            }
            switch await EVMDAppSigner.sendTransaction(request) {
            case .success(let txHash):
                router.approveSend(txHash: txHash)
                dismiss()
            case .failure(let error):
                sendError = EVMDAppSigner.requestError(for: error).message
            }
        }
    }

    // MARK: - Derived

    /// The native amount the dApp asked to send, decoded from the
    /// hex-wei `valueHex` into a human-readable decimal of the chain's
    /// native coin (e.g. `0x38d7ea4c68000` → `0.001 ETH`). When the hex
    /// can't be parsed we fall back to showing it verbatim rather than a
    /// wrong number (Rule #16 — never fabricate a value).
    ///
    /// A swap (like Sushi's) sends `0` native value and moves tokens
    /// through the router's `data`, so this honestly reads `0 ETH` for
    /// those — the token leg lives in the contract call, which Aperture
    /// does not decode without the source (see `contractDataCard`).
    private var formattedValue: String {
        let raw = request.valueHex
        let ticker = request.chain.ticker
        if raw.isEmpty || raw == "0x" || raw == "0x0" || raw == "0x00" {
            return "0 \(ticker)"
        }
        guard let wei = Self.decimalFromHex(raw) else {
            return "\(raw) \(ticker)"
        }
        let amount = wei / pow(Decimal(10), request.chain.nativeDecimals)
        return "\(WalletFormatting.native(amount, decimals: min(request.chain.nativeDecimals, 8))) \(ticker)"
    }

    private var rawValueDisplay: String {
        request.valueHex
    }

    /// Decoded gas limit (units) from the hex `gasHex`, formatted with
    /// grouping (e.g. `0x391d7` → `233,943`). The raw hex is opaque to a
    /// human; the unit count is the honest readout. `nil` when absent or
    /// unparseable, so the row is simply hidden.
    private var formattedGas: String? {
        guard let gas = request.gasHex, !gas.isEmpty,
              let units = Self.decimalFromHex(gas) else { return nil }
        return WalletFormatting.native(units, decimals: 0)
    }

    /// Parse a `0x`-prefixed hex quantity into a `Decimal`. Returns nil
    /// for malformed input so the caller shows the raw hex instead of a
    /// wrong value.
    private static func decimalFromHex(_ hex: String) -> Decimal? {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard !s.isEmpty else { return nil }
        var result = Decimal(0)
        for ch in s {
            guard let digit = ch.hexDigitValue else { return nil }
            result = result * 16 + Decimal(digit)
        }
        return result
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
