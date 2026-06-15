import SwiftUI

// MARK: - OP_RETURN

/// Send · advanced — OP_RETURN data anchoring (Bitcoin family). A typed
/// text payload, byte-counted against the chain's `opReturnMaxBytes`, with
/// honest copy that this is optional and unrelated to exchange deposits.
struct SendOpReturnSheet: View {
    @Bindable var model: SendComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var didSeed = false

    private var maxBytes: Int { model.capability.opReturnMaxBytes ?? 80 }
    private var byteCount: Int { draft.utf8.count }
    private var overLimit: Bool { byteCount > maxBytes }

    var body: some View {
        ComposeDataSheetShell(
            title: "OP_RETURN data",
            canSave: !overLimit,
            onCancel: { dismiss() },
            onSave: { model.opReturnText = draft; dismiss() }
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                UniBody(
                    text: "Attach a small data note to the transaction. This is optional and isn't needed to send — exchanges never require it.",
                    color: UniColors.Text.secondary
                )
                UniTextField(
                    placeholder: "Data note",
                    text: $draft,
                    directionPolicy: .ambient,
                    axis: .vertical,
                    lineLimit: 4
                )
                byteCounter(byteCount, max: maxBytes, over: overLimit)
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            draft = model.opReturnText
        }
    }
}

// MARK: - Memo (text / cosmos / SPL / stellar / near)

/// Send · advanced — a free-text memo for the chains whose protocol carries
/// one (TRON, Cosmos, Solana SPL Memo, Stellar text memo, NEAR FT memo).
/// Byte-counted against the chain's `memoMaxBytes`. Honest exchange note
/// for the kinds CEXes commonly require.
struct SendMemoSheet: View {
    @Bindable var model: SendComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var didSeed = false

    private var maxBytes: Int? { model.capability.memoMaxBytes }
    private var byteCount: Int { draft.utf8.count }
    private var overLimit: Bool { if let m = maxBytes { return byteCount > m } else { return false } }

    var body: some View {
        ComposeDataSheetShell(
            title: "Memo",
            canSave: !overLimit,
            onCancel: { dismiss() },
            onSave: { saveMemo(); dismiss() }
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                UniBody(text: memoBlurb, color: UniColors.Text.secondary)
                if model.capability.memoKind.exchangeOftenRequires {
                    ComposeExchangeNote(
                        text: "Many exchanges require a memo. Sending without the one they gave you can lose the deposit."
                    )
                }
                if model.chain == .tron {
                    // TRON burns an extra 1 TRX for a non-empty memo
                    // (getMemoFee = 1,000,000 SUN). State it plainly so the
                    // Review total is no surprise (Rule #16 honesty · FIX 9).
                    ComposeInfoNote(text: "Adding a memo on TRON costs an extra 1 TRX.")
                }
                UniTextField(
                    placeholder: "Memo",
                    text: $draft,
                    directionPolicy: .automatic,
                    axis: .vertical,
                    lineLimit: 3
                )
                if let m = maxBytes {
                    byteCounter(byteCount, max: m, over: overLimit)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            draft = currentMemoText
        }
    }

    private var memoBlurb: LocalizedStringKey {
        "Add an optional note that travels with the transaction."
    }

    private var currentMemoText: String {
        switch model.memo {
        case .text(let s), .splMemo(let s): return s
        case .stellarMemo(.text(let s)): return s
        default: return ""
        }
    }

    private func saveMemo() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { model.memo = .none; return }
        switch model.capability.memoKind {
        case .splMemo:    model.memo = .splMemo(trimmed)
        case .stellarMemo: model.memo = .stellarMemo(.text(trimmed))
        case .textMemo, .cosmosMemo, .nearFtMemo: model.memo = .text(trimmed)
        default:          model.memo = .text(trimmed)
        }
    }
}

// MARK: - Destination tag (XRP)

/// Send · advanced — XRP destination tag (uint32). Honest about being
/// REQUIRED by most exchanges (Rule #16).
struct SendDestinationTagSheet: View {
    @Bindable var model: SendComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var didSeed = false

    private var parsed: UInt32? { UInt32(draft.trimmingCharacters(in: .whitespaces)) }
    private var invalid: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && parsed == nil }

    var body: some View {
        ComposeDataSheetShell(
            title: "Destination tag",
            canSave: !invalid,
            onCancel: { dismiss() },
            onSave: { saveTag(); dismiss() }
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                ComposeExchangeNote(
                    text: "Most exchanges REQUIRE a destination tag for XRP deposits. A deposit sent without the right tag can be credited to the wrong account or lost."
                )
                UniBody(text: "Enter the numeric tag the recipient gave you.", color: UniColors.Text.secondary)
                UniTextField(
                    placeholder: "Tag (numbers only)",
                    text: $draft,
                    directionPolicy: .forceLTR,
                    keyboardType: .numberPad
                )
                if invalid {
                    Label {
                        Text("That isn't a valid tag — use numbers only (0 to 4,294,967,295).")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Status.errorForeground)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(UniColors.Status.errorForeground)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            if case .destinationTag(let t) = model.memo { draft = String(t) }
        }
    }

    private func saveTag() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { model.memo = .none; return }
        if let t = parsed { model.memo = .destinationTag(t) }
    }
}

// MARK: - Comment (TON)

/// Send · advanced — TON text comment. Honest about being exchange-required
/// (TON's destination-tag equivalent).
struct SendCommentSheet: View {
    @Bindable var model: SendComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var didSeed = false

    private var maxBytes: Int { model.capability.memoMaxBytes ?? 123 }
    private var byteCount: Int { draft.utf8.count }
    private var overLimit: Bool { byteCount > maxBytes }

    var body: some View {
        ComposeDataSheetShell(
            title: "Comment",
            canSave: !overLimit,
            onCancel: { dismiss() },
            onSave: { saveComment(); dismiss() }
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                ComposeExchangeNote(
                    text: "Exchanges require a comment for TON deposits. Send the exact comment they gave you, or the deposit can be lost."
                )
                UniBody(text: "Enter the comment the recipient gave you.", color: UniColors.Text.secondary)
                UniTextField(
                    placeholder: "Comment",
                    text: $draft,
                    directionPolicy: .automatic,
                    axis: .vertical,
                    lineLimit: 3
                )
                byteCounter(byteCount, max: maxBytes, over: overLimit)
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            if case .tonComment(let s) = model.memo { draft = s }
        }
    }

    private func saveComment() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.memo = trimmed.isEmpty ? .none : .tonComment(trimmed)
    }
}

// MARK: - EVM advanced gas

/// Send · advanced — EVM gas-limit override. Honest + minimal: the gas
/// limit is estimated automatically; this lets advanced users raise it.
struct SendGasSheet: View {
    @Bindable var model: SendComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var didSeed = false

    private var estimated: Decimal? { model.resolvedFee?.gasLimit }

    var body: some View {
        ComposeDataSheetShell(
            title: "Advanced gas",
            canSave: true,
            onCancel: { dismiss() },
            onSave: { saveGas(); dismiss() }
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                UniBody(
                    text: "Aperture estimates the gas limit automatically. Only change this if you know the transaction needs more.",
                    color: UniColors.Text.secondary
                )
                if let estimated {
                    HStack(spacing: UniSpacing.xxs) {
                        Text("Estimated")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                        Text(verbatim: WalletFormatting.native(estimated, decimals: 0))
                            .font(UniTypography.footnote.monospacedDigit())
                            .foregroundStyle(UniColors.Text.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                        Text(verbatim: "gas")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                }
                UniTextField(
                    placeholder: "Gas limit",
                    text: $draft,
                    directionPolicy: .forceLTR,
                    keyboardType: .numberPad
                )
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            if let override = model.gasLimitOverride {
                draft = SendComposeModel.plainString(override, decimals: 0)
            }
        }
    }

    private func saveGas() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let v = SendComposeModel.parseAmount(trimmed), v > 0 else {
            model.gasLimitOverride = nil
            return
        }
        model.gasLimitOverride = v
    }
}

// MARK: - Shared sheet shell + helpers

/// Common shell for the small data-input sheets (Rule #15): a native
/// `NavigationStack`, a `navigationTitle`, Cancel leading / Save trailing,
/// opaque background, intrinsic medium detent. No `ScrollView` (short
/// content). The body content is the caller's `VStack`.
private struct ComposeDataSheetShell<Content: View>: View {
    let title: LocalizedStringKey
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(UniColors.Background.primary)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save", action: onSave)
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(UniColors.Background.primary)
    }
}

/// The honest "exchanges require this" warning note used by the tag /
/// comment / required-memo sheets (Rule #16).
private struct ComposeExchangeNote: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(UniColors.Status.warningForeground)
            Text(text)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                .fill(UniColors.Status.warningBackground)
        )
    }
}

/// A calm, neutral information note (not a warning) — used for honest fee
/// disclosures like the TRON +1 TRX memo surcharge (Rule #16: state the
/// cost plainly without alarm; reserve the orange warning for genuine
/// risk). Matches the reserve banner's register.
private struct ComposeInfoNote: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.xs) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(UniColors.Icon.secondary)
            Text(text)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                .fill(UniColors.Fill.quaternary)
        )
    }
}

/// Shared byte counter line for the data sheets.
@ViewBuilder
private func byteCounter(_ count: Int, max: Int, over: Bool) -> some View {
    HStack {
        Spacer()
        Text(verbatim: "\(count) / \(max) bytes")
            .font(UniTypography.caption1.monospacedDigit())
            .foregroundStyle(over ? UniColors.Status.errorForeground : UniColors.Text.tertiary)
            .environment(\.layoutDirection, .leftToRight)
    }
}
