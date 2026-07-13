import Foundation
import SwiftUI

// MARK: - OP_RETURN

/// Send · advanced — OP_RETURN data anchoring (Bitcoin family). A typed
/// text payload, byte-counted against the chain's `opReturnMaxBytes`, with
/// honest copy that this is optional and unrelated to normal sends.
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
                    text: "Attach a small data note to the transaction. This is optional and is not needed for normal sends.",
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

// MARK: - Memo (text / SPL / stellar / near)

/// Send · advanced — a free-text memo for the chains whose protocol carries
/// one (TRON, Solana SPL Memo, Stellar text memo, NEAR FT memo).
/// Byte-counted against the chain's `memoMaxBytes`. Honest service-note
/// copy for recipients that require a memo.
struct SendMemoSheet: View {
    @Bindable var model: SendComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var didSeed = false

    private var maxBytes: Int? { model.capability.memoMaxBytes }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var byteCount: Int { trimmedDraft.utf8.count }
    private var isStellarMemo: Bool { model.capability.memoKind == .stellarMemo }
    private var stellarMemoInference: StellarMemoInference {
        StellarMemoInference.infer(draft)
    }
    private var countsMemoBytes: Bool { !isStellarMemo || stellarMemoInference.isTextLike }
    private var overLimit: Bool {
        guard countsMemoBytes, let m = maxBytes else { return false }
        return byteCount > m
    }
    private var stellarMemoError: String? {
        guard isStellarMemo else { return nil }
        return stellarMemoInference.validationError
    }
    private var canSave: Bool { !overLimit && stellarMemoError == nil }

    var body: some View {
        ComposeDataSheetShell(
            title: "Memo",
            canSave: canSave,
            onCancel: { dismiss() },
            onSave: { saveMemo(); dismiss() }
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                UniBody(text: memoBlurb, color: UniColors.Text.secondary)
                if model.capability.memoKind.recipientServiceOftenRequires {
                    ComposeRecipientServiceNote(
                        text: "Some recipient services require a memo. Sending without the one they gave you can lose the deposit."
                    )
                }
                if model.chain == .tron {
                    // TRON burns an extra 1 TRX for a non-empty memo
                    // (getMemoFee = 1,000,000 SUN). State it plainly so the
                    // Review total is no surprise (Rule #16 honesty · FIX 9).
                    ComposeInfoNote(text: "Adding a memo on TRON costs an extra 1 TRX.")
                }
                UniTextField(
                    placeholder: memoPlaceholder,
                    text: $draft,
                    directionPolicy: isStellarMemo && !stellarMemoInference.isTextLike ? .forceLTR : .automatic,
                    axis: .vertical,
                    lineLimit: isStellarMemo && !stellarMemoInference.isTextLike ? 1 : 3,
                    keyboardType: .default
                )
                if isStellarMemo, let displayName = stellarMemoInference.displayName {
                    memoTypeBadge(displayName)
                }
                if countsMemoBytes, let m = maxBytes {
                    byteCounter(byteCount, max: m, over: overLimit)
                }
                if let stellarMemoError {
                    memoInputError(stellarMemoError)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            seedCurrentMemo()
        }
    }

    private var memoBlurb: LocalizedStringKey {
        if isStellarMemo {
            return "Add the exact memo value the recipient gave you."
        }
        return "Add an optional note that travels with the transaction."
    }

    private var memoPlaceholder: String {
        guard isStellarMemo else { return "Memo" }
        return "Memo, ID, or hash"
    }

    private var currentMemoText: String {
        switch model.memo {
        case .text(let s), .splMemo(let s): return s
        case .stellarMemo(.text(let s)): return s
        case .stellarMemo(.id(let id)): return String(id)
        case .stellarMemo(.hashHex(let hash)): return hash
        default: return ""
        }
    }

    private func seedCurrentMemo() {
        switch model.memo {
        case .stellarMemo(.text(let text)):
            draft = text
        case .stellarMemo(.id(let id)):
            draft = String(id)
        case .stellarMemo(.hashHex(let hash)):
            draft = hash
        default:
            draft = currentMemoText
        }
    }

    private func saveMemo() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { model.memo = .none; return }
        switch model.capability.memoKind {
        case .splMemo:    model.memo = .splMemo(trimmed)
        case .stellarMemo:
            guard stellarMemoError == nil, let memo = stellarMemoInference.memo else { return }
            model.memo = .stellarMemo(memo)
        case .textMemo, .nearFtMemo: model.memo = .text(trimmed)
        default:          model.memo = .text(trimmed)
        }
    }

    private func memoTypeBadge(_ type: String) -> some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 12, weight: .regular))
            Text(verbatim: String(format: String.apertureLocalized("Detected: %@"), type))
                .font(UniTypography.caption1.weight(.semibold))
        }
        .foregroundStyle(UniColors.Text.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Destination tag (XRP)

/// Send · advanced — XRP destination tag (uint32). Honest about being
/// required by many recipient services (Rule #16).
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
                ComposeRecipientServiceNote(
                    text: "Some recipient services REQUIRE a destination tag for XRP deposits. A deposit sent without the right tag can be credited to the wrong account or lost."
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
                            .foregroundStyle(UniColors.Feedback.Error.foreground)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(UniColors.Feedback.Error.foreground)
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

/// Send · advanced — TON text comment. Honest about being required by some
/// recipients (TON's destination-tag equivalent).
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
                ComposeRecipientServiceNote(
                    text: "Some recipient services require a comment for TON deposits. Send the exact comment they gave you, or the deposit can be lost."
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
                        Button("Cancel", action: onCancel).tint(UniColors.Button.text)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save", action: onSave).tint(UniColors.Button.text)
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
        }
        .uniSheetDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(UniColors.Background.primary)
    }
}

/// The honest "some recipients require this" warning note used by the tag /
/// comment / required-memo sheets (Rule #16).
private struct ComposeRecipientServiceNote: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(UniColors.Feedback.Warning.foreground)
            Text(text)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                .fill(UniColors.Feedback.Warning.background)
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
            .foregroundStyle(over ? UniColors.Feedback.Error.foreground : UniColors.Text.tertiary)
            .environment(\.layoutDirection, .leftToRight)
    }
}

private func memoInputError(_ text: String) -> some View {
    Label {
        Text(verbatim: text)
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Feedback.Error.foreground)
            .fixedSize(horizontal: false, vertical: true)
    } icon: {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(UniColors.Feedback.Error.foreground)
    }
}
