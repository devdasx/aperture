import SwiftUI

/// Detail sheet for `eth_sendTransaction` (EVM). The user reads what the
/// dApp asked for — from, to, value, gas, contract data — then "Confirm &
/// send" signs it with the wallet key and broadcasts it on-chain (the
/// `EVMContractCallSigner` + `BroadcastService` pipeline, gated by
/// biometrics), returning the real tx hash to the page (2026-06-17).
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
    /// Drives the unified passcode gate (the ONE PinCodeView). Set when the
    /// user taps Confirm and an app passcode exists; on success we sign +
    /// broadcast. Never a raw OS Face ID prompt (2026-06-21 direction).
    @State private var isShowingPinGate: Bool = false

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
            .fullScreenCover(isPresented: $isShowingPinGate) {
                pinGateCover
            }
        }
    }

    /// The unified passcode screen, presented before signing. Auto-prompts
    /// Face ID when "Require Face ID for dApps" is on (`allowsBiometrics:
    /// requireForDApp`) and the in-app biometric toggle is enabled; otherwise
    /// it's passcode-only. On success → sign + broadcast.
    private var pinGateCover: some View {
        NavigationStack {
            PinCodeView(
                mode: .verify,
                onComplete: { _ in
                    isShowingPinGate = false
                    performSignAndBroadcast()
                },
                onCancel: { isShowingPinGate = false },
                allowsBiometrics: requireForDApp
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { isShowingPinGate = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
            }
        }
        .uniAppEnvironment()
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
                if let decoded = decodedContractCall {
                    dappDataRow(label: "Function", value: decoded.name)
                    ForEach(decoded.fields, id: \.label) { field in
                        dappDataRow(label: field.label, value: field.value)
                    }
                    dappDataRow(label: "Selector", value: decoded.selector)
                    if decoded.isApproval {
                        UniFootnote(
                            text: "This call can grant another address permission to move tokens or NFTs. Verify the spender before signing.",
                            color: UniColors.Status.warningForeground
                        )
                    }
                } else {
                    Text(verbatim: functionSelector)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(UniColors.Text.primary)
                        .textSelection(.enabled)
                }
                UniFootnote(
                    text: decodedContractCall == nil
                        ? "Aperture doesn't recognize this selector. Read it against the dApp's docs before signing."
                        : "Decoded from common token/NFT selectors. Amounts are raw contract units because token decimals are not in calldata.",
                    color: UniColors.Text.tertiary
                )
            }
        }
    }

    private func dappDataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            Text(verbatim: label)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(width: 96, alignment: .leading)
            Text(verbatim: value)
                .font(.system(.callout, design: value.hasPrefix("0x") ? .monospaced : .default))
                .foregroundStyle(UniColors.Text.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
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
    /// with the wallet's key and broadcast on-chain via
    /// `EVMDAppSigner.sendTransaction`, gated behind a
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
        sendError = nil
        // Unified auth: route through the ONE passcode screen when an app
        // passcode exists; with none set there's nothing in-app to verify
        // against, so sign directly (the iPhone's lock screen is the gate).
        if PinCodeStorage.hasPin {
            isShowingPinGate = true
        } else {
            performSignAndBroadcast()
        }
    }

    /// Sign the request with the wallet key and broadcast it on-chain, then
    /// hand the real tx hash back to the dApp. Called only after the auth
    /// gate (if any) has passed.
    private func performSignAndBroadcast() {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        Task { @MainActor in
            defer { isSending = false }
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

    private var decodedContractCall: DecodedContractCall? {
        DecodedContractCall.decode(request.dataHex)
    }
}

private struct DecodedContractCall {
    struct Field {
        let label: String
        let value: String
    }

    let selector: String
    let name: String
    let fields: [Field]
    let isApproval: Bool

    static func decode(_ dataHex: String) -> DecodedContractCall? {
        var clean = dataHex.lowercased()
        if clean.hasPrefix("0x") { clean.removeFirst(2) }
        guard clean.count >= 8 else { return nil }
        let selector = "0x" + clean.prefix(8)
        let words = abiWords(String(clean.dropFirst(8)))

        switch selector {
        case "0xa9059cbb":
            return DecodedContractCall(
                selector: selector,
                name: "ERC-20 transfer(address,uint256)",
                fields: [
                    Field(label: "Recipient", value: address(words[safe: 0])),
                    Field(label: "Amount raw", value: uint(words[safe: 1])),
                ],
                isApproval: false
            )
        case "0x095ea7b3":
            return DecodedContractCall(
                selector: selector,
                name: "ERC-20 approve(address,uint256)",
                fields: [
                    Field(label: "Spender", value: address(words[safe: 0])),
                    Field(label: "Allowance", value: uint(words[safe: 1])),
                ],
                isApproval: true
            )
        case "0x23b872dd":
            return DecodedContractCall(
                selector: selector,
                name: "transferFrom(address,address,uint256)",
                fields: [
                    Field(label: "From", value: address(words[safe: 0])),
                    Field(label: "To", value: address(words[safe: 1])),
                    Field(label: "Amount raw", value: uint(words[safe: 2])),
                ],
                isApproval: false
            )
        case "0x42842e0e", "0xb88d4fde":
            return DecodedContractCall(
                selector: selector,
                name: "ERC-721 safeTransferFrom(...)",
                fields: [
                    Field(label: "From", value: address(words[safe: 0])),
                    Field(label: "To", value: address(words[safe: 1])),
                    Field(label: "Token ID", value: uint(words[safe: 2])),
                ],
                isApproval: false
            )
        case "0xa22cb465":
            return DecodedContractCall(
                selector: selector,
                name: "ERC-721/1155 setApprovalForAll(address,bool)",
                fields: [
                    Field(label: "Operator", value: address(words[safe: 0])),
                    Field(label: "Approved", value: bool(words[safe: 1])),
                ],
                isApproval: true
            )
        case "0xd505accf", "0x8fcbaf0c":
            return DecodedContractCall(
                selector: selector,
                name: "permit(...)",
                fields: [
                    Field(label: "Owner", value: address(words[safe: 0])),
                    Field(label: "Spender", value: address(words[safe: 1])),
                    Field(label: "Amount raw", value: uint(words[safe: 2])),
                ],
                isApproval: true
            )
        case "0x3593564c", "0x24856bc3":
            return DecodedContractCall(
                selector: selector,
                name: "Universal Router execute(...)",
                fields: [],
                isApproval: false
            )
        default:
            return nil
        }
    }

    private static func abiWords(_ hex: String) -> [String] {
        stride(from: 0, to: hex.count, by: 64).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(64, hex.distance(from: start, to: hex.endIndex)))
            return String(hex[start..<end])
        }
    }

    private static func address(_ word: String?) -> String {
        guard let word, word.count == 64 else { return "Unavailable" }
        return "0x" + word.suffix(40)
    }

    private static func uint(_ word: String?) -> String {
        guard let word, !word.isEmpty else { return "Unavailable" }
        if word.allSatisfy({ $0 == "f" }) { return "Unlimited" }
        let trimmed = word.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : "0x" + trimmed
    }

    private static func bool(_ word: String?) -> String {
        guard let word, word.count == 64 else { return "Unavailable" }
        return word.suffix(1) == "1" ? "true" : "false"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
