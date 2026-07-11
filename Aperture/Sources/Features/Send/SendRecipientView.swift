import Foundation
import SwiftUI
import UIKit

/// Send · Step 3 — the recipient(s). Real per-chain address validation
/// (wallet-core), real name resolution (ENS `.eth` / SNS `.sol`), real
/// recent-recipient safety data from the wallet's outgoing history, and a real first-send
/// warning / send count per recipient.
///
/// **Redesign (2026-06-15 — Apple iOS 26).** The recipient fields use
/// native SwiftUI `TextField` controls with the current platform style. The
/// address — the load-bearing artifact of this step — still expands vertically
/// as the user types or pastes, never truncated.
///
/// **Layers (Rule #2 §B.3).** Content layer: native input fields, inline field
/// utilities, and all copy. This recipient screen avoids drop shadows and glass
/// chips; the Send sheet chrome itself owns any system presentation material.
///
/// **Multi-recipient.** Chains whose protocol can pay many recipients in
/// one transaction (UTXO, Solana, Stellar, TON, Sui, Polkadot,
/// Aptos — see `ChainSendCapability`) get the add-more-addresses list,
/// each card independently validated/resolved. Single-recipient chains
/// (EVM, TRON, XRPL, NEAR) keep one card.
///
/// **Honesty (Rule #16).** A first send to an address is flagged plainly;
/// a repeat send shows the real count. Validation accepts only what the
/// chain's format rules accept; a name resolves only if the on-chain
/// registry returns an address. The address is LTR-locked and rendered
/// honestly in full inside the field (Rule #11).
struct SendRecipientView: View {
    let chain: SupportedChain
    let tokenSymbol: String?
    let fromAddress: String
    let recents: RecentRecipientsIndex
    /// Seeds the first recipient field when this step is entered from a scan
    /// (the app-bar Aperture Scanner hands back the validated address). `nil` in
    /// the manual flow. Applied once on appear via `handleIncoming` so it runs
    /// the same validation / address-poisoning / resolution path as an in-view
    /// scan.
    var initialRecipient: String? = nil
    /// Proceed to the amount step with the resolved recipient list.
    let onContinue: (_ recipients: [SendRecipientEntry]) -> Void

    struct DraftEntry: Identifiable {
        let id = UUID()
        var text: String = ""
        var resolution: RecipientResolution = .empty
    }

    @State private var entries: [DraftEntry] = [DraftEntry()]
    /// Identity of the currently-focused recipient field, reported up from
    /// each `RecipientRow`'s native `TextField` via its external focus
    /// passthrough. Drives `pruneEmptyUnfocused()` on focus change so an
    /// earlier field the user empties (and then leaves) is removed.
    @FocusState private var focusedEntry: UUID?
    @State private var isScanning: Bool = false
    /// A freshly pasted / scanned address that imitates a known recipient —
    /// presents the full-screen address-poisoning guard (Flow A3). Nil when
    /// no lookalike is pending.
    @State private var poisonLookalike: SendSafety.Lookalike?
    /// Tap counter for the ambient affordances' selection haptic — the
    /// action chips (Paste / Scan / Add) aren't
    /// `UniButton`s, so they fire `.uniHaptic(_:trigger:)` keyed to this
    /// on each tap (Rule #10 §B authoring pattern). One counter, one
    /// polite `.selection` beat for every "address landed / sheet opened"
    /// gesture on this screen.
    @State private var selectionTapCount: Int = 0
    /// Guards the one-time `initialRecipient` prefill so it doesn't re-run if
    /// the view re-appears.
    @State private var didConsumeInitial: Bool = false
    /// XRP/XLM recipient-service routing data entered beside the address.
    @State private var destinationTagText: String = ""
    @State private var stellarMemoText: String = ""

    private var maxRecipients: Int { ChainSendCapability.maxRecipients(for: chain) }
    private var isMulti: Bool { maxRecipients > 1 }
    private var recentList: [RecentRecipient] { recents.recents(for: chain) }

    private var showsRecipientMemo: Bool {
        chain == .ripple || chain == .stellar
    }

    private var destinationTagTrimmed: String {
        destinationTagText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedDestinationTag: UInt32? {
        UInt32(destinationTagTrimmed)
    }

    private var destinationTagIsInvalid: Bool {
        !destinationTagTrimmed.isEmpty && parsedDestinationTag == nil
    }

    private var stellarMemoTrimmed: String {
        stellarMemoText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var stellarMemoByteCount: Int {
        stellarMemoTrimmed.utf8.count
    }

    private var stellarMemoInference: StellarMemoInference {
        StellarMemoInference.infer(stellarMemoText)
    }

    private var stellarMemoError: String? {
        guard chain == .stellar else { return nil }
        return stellarMemoInference.validationError
    }

    private var recipientMemoIsValid: Bool {
        switch chain {
        case .ripple:
            return !destinationTagIsInvalid
        case .stellar:
            return stellarMemoError == nil
        default:
            return true
        }
    }

    private var recipientMemoValue: SendMemoValue? {
        switch chain {
        case .ripple:
            guard !destinationTagTrimmed.isEmpty, let tag = parsedDestinationTag else { return nil }
            return .destinationTag(tag)
        case .stellar:
            guard stellarMemoError == nil, let memo = stellarMemoInference.memo else { return nil }
            return .stellarMemo(memo)
        default:
            return nil
        }
    }

    private var nameHint: String? {
        if chain.family == .evm { return ".eth name" }
        if chain == .solana { return ".sol name" }
        return nil
    }

    /// Every non-empty entry must be resolved, and there must be ≥1.
    private var canContinue: Bool {
        let nonEmpty = entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        return nonEmpty.allSatisfy { if case .resolved = $0.resolution { return true } else { return false } }
            && recipientMemoIsValid
    }

    private var resolvedRecipients: [SendRecipientEntry] {
        let memo = recipientMemoValue
        var didAttachMemo = false
        return entries.compactMap { entry in
            if case let .resolved(address, name) = entry.resolution {
                defer { didAttachMemo = true }
                return SendRecipientEntry(address: address, name: name, memo: didAttachMemo ? nil : memo)
            }
            return nil
        }
    }

    /// "Add recipient" is enabled only when the LAST field holds a fully
    /// RESOLVED address — so it stays disabled while that field is empty,
    /// `.resolving`, `.invalid`, or `.nameNotFound`. Mirrors `canContinue`'s
    /// `if case .resolved` gate so the user can't stack empty / broken rows.
    private var canAddMore: Bool {
        guard isMulti, entries.count < maxRecipients, let last = entries.last else { return false }
        if case .resolved = last.resolution { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                recipientsBlock
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            // Clear the floating Continue CTA so the last card never hides
            // under the glass.
            .padding(.bottom, UniSpacing.xxxl + UniSpacing.xl)
        }
        // When focus moves between recipient fields, prune any earlier
        // field the user emptied and left. Keyed on focus-change (not
        // mid-keystroke) so it never deletes the field being edited.
        .onChange(of: focusedEntry) { _, _ in pruneEmptyUnfocused() }
        // Seed the recipient from a scan (app-bar Aperture Scanner) exactly once,
        // through the same path an in-view scan takes (validation + poisoning +
        // resolution).
        .onAppear {
            guard !didConsumeInitial,
                  let seed = initialRecipient?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !seed.isEmpty else { return }
            didConsumeInitial = true
            handleIncoming(seed)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(UniColors.Background.primary)
        .toolbarBackground(.hidden, for: .navigationBar)
        // One polite `.selection` beat for every ambient affordance on the
        // screen chips — these aren't `UniButton`s, so the
        // haptic is wired here, keyed to the shared tap counter.
        .uniHaptic(.selection, trigger: selectionTapCount)
        .uniBottomActionBar { continueBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoinTitleBar(chain: chain, tokenSymbol: tokenSymbol, verb: "Send", trailing: "to")
            }
        }
        .fullScreenCover(isPresented: $isScanning) {
            // Raw-deliver mode: this scan is already scoped to `chain`, so the
            // scanner hands back the payload and the field validates it.
            UniQRScannerSheet(
                title: "Scan address",
                prompt: "Point your camera at a \(chain.displayName) address QR code.",
                expectedContent: .walletAddress,
                onRawDeliver: { scanned in
                    handleIncoming(scanned)
                    isScanning = false
                },
                rawPayloadValidator: { scanned in
                    let incoming = parseIncoming(scanned)
                    guard !incoming.address.isEmpty else { return false }
                    return WalletCoreKeyImportService().validateAddress(incoming.address, on: chain)
                }
            )
            .apertureEnvironment()
        }
        // Address-poisoning guard (Flow A3) — a freshly pasted / scanned
        // address that imitates a known recipient raises a full-screen,
        // can't-skip-silently interstitial before it can fill a field.
        .fullScreenCover(item: $poisonLookalike) { look in
            SendPoisoningGuardView(
                lookalike: look,
                knownName: nil,
                chain: chain,
                onUseSaved: {
                    fill(look.knownAddress)
                    poisonLookalike = nil
                },
                onContinuePasted: {
                    fill(look.pastedAddress)
                    poisonLookalike = nil
                },
                onCancel: { poisonLookalike = nil }
            )
        }
    }

    // MARK: - Recipients (content layer)

    @ViewBuilder
    private var recipientsBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            if isMulti {
                sectionHeader(
                    entries.count > 1 ? "Recipients (\(entries.count))" : "Recipients"
                )
            }

            if showsRecipientMemo {
                recipientMemoForm
                recipientMemoGuidance
                    .padding(.top, UniSpacing.xxs)
            } else {
                VStack(spacing: UniSpacing.s) {
                    ForEach(Array($entries.enumerated()), id: \.element.id) { offset, $entry in
                        RecipientRow(
                            entry: $entry,
                            chain: chain,
                            index: offset + 1,
                            showsIndex: isMulti && entries.count > 1,
                            nameHint: nameHint,
                            canRemove: entries.count > 1,
                            isDuplicate: isDuplicateAddress(entry),
                            focusBinding: $focusedEntry,
                            sendCount: { recents.sendCount(to: $0, chain: chain) },
                            showsUtilityActions: offset == entries.count - 1,
                            showsAddRecipient: isMulti,
                            canAddRecipient: canAddMore,
                            onPaste: {
                                selectionTapCount &+= 1
                                pasteFromClipboard()
                            },
                            onScan: {
                                selectionTapCount &+= 1
                                isScanning = true
                            },
                            onAddRecipient: {
                                selectionTapCount &+= 1
                                addEntry()
                            },
                            onRemove: { remove(entry.id) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recipientMemoForm: some View {
        VStack(spacing: UniSpacing.s) {
            ForEach(Array($entries.enumerated()), id: \.element.id) { offset, $entry in
                RecipientRow(
                    entry: $entry,
                    chain: chain,
                    index: offset + 1,
                    showsIndex: isMulti && entries.count > 1,
                    nameHint: nameHint,
                    canRemove: entries.count > 1,
                    isDuplicate: isDuplicateAddress(entry),
                    focusBinding: $focusedEntry,
                    sendCount: { recents.sendCount(to: $0, chain: chain) },
                    showsUtilityActions: offset == entries.count - 1,
                    showsAddRecipient: isMulti,
                    canAddRecipient: canAddMore,
                    onPaste: {
                        selectionTapCount &+= 1
                        pasteFromClipboard()
                    },
                    onScan: {
                        selectionTapCount &+= 1
                        isScanning = true
                    },
                    onAddRecipient: {
                        selectionTapCount &+= 1
                        addEntry()
                    },
                    onRemove: { remove(entry.id) }
                )
            }

            recipientMemoInputRow
        }
    }

    @ViewBuilder
    private var recipientMemoInputRow: some View {
        switch chain {
        case .ripple:
            RecipientFieldBox(minHeight: 72) {
                NativeRecipientTextField(
                    text: $destinationTagText,
                    prompt: "Destination tag (optional)",
                    label: "Destination tag",
                    axis: .horizontal,
                    lineLimit: 1,
                    keyboardType: .numberPad,
                    forceLTR: true
                )
            }
        case .stellar:
            RecipientFieldBox(minHeight: 84) {
                NativeRecipientTextField(
                    text: $stellarMemoText,
                    prompt: "Memo, ID, or hash",
                    label: "Stellar memo",
                    axis: .vertical,
                    lineLimit: stellarMemoInference.isTextLike ? 2 : 1,
                    keyboardType: .default,
                    forceLTR: !stellarMemoInference.isTextLike
                )
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var recipientMemoGuidance: some View {
        switch chain {
        case .ripple:
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                RecipientRoutingNote(
                    text: "Use the exact tag the exchange or recipient gave you. XRP sent to a shared address without the required tag can be lost."
                )
                .padding(.horizontal, UniSpacing.m)

                if destinationTagIsInvalid {
                    memoError("Destination tag must be a number from 0 to 4,294,967,295.")
                        .padding(.horizontal, UniSpacing.m)
                }
            }
        case .stellar:
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                if let displayName = stellarMemoInference.displayName {
                    memoTypeBadge(displayName)
                        .padding(.horizontal, UniSpacing.m)
                }

                RecipientRoutingNote(
                    text: "Use the exact memo value the exchange or recipient gave you. Many Stellar deposits require this."
                )
                .padding(.horizontal, UniSpacing.m)

                if stellarMemoInference.isTextLike {
                    HStack {
                        Spacer()
                        Text(verbatim: "\(stellarMemoByteCount) / 28 bytes")
                            .font(UniTypography.caption1.monospacedDigit())
                            .foregroundStyle(stellarMemoByteCount > 28 ? UniColors.Feedback.Error.foreground : UniColors.Text.tertiary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .padding(.horizontal, UniSpacing.m)
                }

                if let stellarMemoError {
                    memoError(stellarMemoError)
                        .padding(.horizontal, UniSpacing.m)
                }
            }
        default:
            EmptyView()
        }
    }

    private func memoTypeBadge(_ type: String) -> some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
            Text("Detected: \(type)")
                .font(UniTypography.caption1.weight(.semibold))
        }
        .foregroundStyle(UniColors.Text.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memoError(_ text: String) -> some View {
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

    // MARK: - Continue (functional layer — floats above content)

    private var continueBar: some View {
        SendV2PrimaryButton(
            "Continue",
            isEnabled: canContinue,
            action: { onContinue(resolvedRecipients) }
        )
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.s)
    }

    // MARK: - Section header

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(UniTypography.footnote.weight(.semibold))
            .foregroundStyle(UniColors.Text.secondary)
            .textCase(.uppercase)
            .padding(.leading, UniSpacing.xs)
    }

    // MARK: - Mutations

    private func entryIndex(_ id: UUID) -> Int {
        (entries.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func normalizedAddress(_ address: String) -> String {
        chain.family == .evm ? address.lowercased() : address
    }

    /// Whether this entry's resolved address already appears in an EARLIER
    /// entry — so the first-send warning fires once per distinct address,
    /// not once per duplicate field. The first occurrence "owns" the
    /// warning; later duplicates show a quiet "same address" note instead.
    private func isDuplicateAddress(_ entry: DraftEntry) -> Bool {
        guard case let .resolved(address, _) = entry.resolution else { return false }
        let norm = normalizedAddress(address)
        let firstOwner = entries.first { candidate in
            if case let .resolved(candidateAddress, _) = candidate.resolution {
                return normalizedAddress(candidateAddress) == norm
            }
            return false
        }
        return firstOwner?.id != entry.id
    }

    private func addEntry() {
        guard canAddMore else { return }
        withAnimation(.snappy(duration: 0.25)) {
            entries.append(DraftEntry())
        }
        // Land the user in the freshly-added field.
        focusedEntry = entries.last?.id
    }

    /// Remove any field the user emptied and then left — but NEVER the
    /// field currently focused, NEVER the last/trailing field, and only
    /// when there's more than one field. Fired on focus change (not
    /// mid-keystroke), so it never deletes the field being edited.
    private func pruneEmptyUnfocused() {
        guard isMulti, entries.count > 1 else { return }
        let lastId = entries.last?.id
        withAnimation(.snappy(duration: 0.25)) {
            entries.removeAll { e in
                e.id != focusedEntry && e.id != lastId
                    && e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if entries.isEmpty { entries = [DraftEntry()] }
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(.snappy(duration: 0.25)) {
            entries.removeAll { $0.id == id }
            if entries.isEmpty { entries = [DraftEntry()] }
        }
    }

    /// Place a pasted / scanned address into the last empty entry,
    /// else append a new entry (when the chain allows more).
    private func fill(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let lastIndex = entries.indices.last,
           entries[lastIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries[lastIndex].text = clean
        } else if isMulti, entries.count < maxRecipients {
            withAnimation(.snappy(duration: 0.25)) {
                entries.append(DraftEntry(text: clean))
            }
        } else if let lastIndex = entries.indices.last {
            entries[lastIndex].text = clean
        }
    }

    private func pasteFromClipboard() {
        if let pasted = SafePasteboard.string {
            handleIncoming(pasted)
        }
    }

    /// Place a pasted / scanned address into the recipient list — but first
    /// run the address-poisoning check (Flow A3). If the cleaned value
    /// imitates a known recent recipient (matching ends, differing middle),
    /// raise the full-screen guard instead of silently filling.
    private func handleIncoming(_ raw: String) {
        let incoming = parseIncoming(raw)
        guard !incoming.address.isEmpty else { return }
        let known = recentList.map(\.address)
        if let look = SendSafety.lookalike(for: incoming.address, among: known, chain: chain) {
            poisonLookalike = look
            return
        }
        applyIncomingMemo(incoming.memo)
        fill(incoming.address)
    }

    /// Strip a URI scheme (`ethereum:`, `solana:`, …) and any query the QR
    /// / pasteboard may carry, leaving the bare address.
    private func parseIncoming(_ raw: String) -> IncomingRecipientPayload {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var query: String?
        var scheme: String?
        if let schemeRange = s.range(of: ":"), s.range(of: "://") == nil {
            scheme = String(s[..<schemeRange.lowerBound]).lowercased()
            let after = String(s[schemeRange.upperBound...])
            if !after.isEmpty { s = after }
        }
        if let q = s.firstIndex(of: "?") {
            query = String(s[s.index(after: q)...])
            s = String(s[..<q])
        }
        let queryItems = queryItems(from: query)
        if chain == .stellar, scheme == "web+stellar", s.lowercased() == "pay",
           let destination = queryItems["destination"], !destination.isEmpty {
            s = destination
        }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        let address = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return IncomingRecipientPayload(address: address, memo: memo(from: queryItems))
    }

    /// Parse a payment-URI query fragment without `URLComponents`.
    ///
    /// **Why not `percentEncodedQuery`:** Foundation's setter *asserts* (debug
    /// trap / production crash) when the string isn't valid percent-encoding
    /// (raw spaces, lone `%`, clipboard noise). Paste/scan payloads are
    /// untrusted and often unencoded — never feed them into that API.
    private func queryItems(from query: String?) -> [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        var result: [String: String] = [:]
        result.reserveCapacity(4)
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let namePart = parts.first else { continue }
            let name = Self.decodeQueryComponent(String(namePart)).lowercased()
            guard !name.isEmpty else { continue }
            let valuePart = parts.count > 1 ? String(parts[1]) : ""
            result[name] = Self.decodeQueryComponent(valuePart)
        }
        return result
    }

    /// Percent-decode a single name/value component; on invalid encoding keep
    /// the raw text (honest — Rule #16) rather than trapping.
    private static func decodeQueryComponent(_ raw: String) -> String {
        // `+` is form-encoding for space in many payment URIs.
        let plusAsSpace = raw.replacingOccurrences(of: "+", with: " ")
        return plusAsSpace.removingPercentEncoding ?? plusAsSpace
    }

    private func memo(from queryItems: [String: String]) -> SendMemoValue? {
        switch chain {
        case .ripple:
            let raw = queryItems["dt"]
                ?? queryItems["destinationtag"]
                ?? queryItems["destination_tag"]
                ?? queryItems["tag"]
                ?? queryItems["memo"]
            guard let raw, let tag = UInt32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return .destinationTag(tag)
        case .stellar:
            let rawMemo = queryItems["memo"]
                ?? queryItems["memo_text"]
                ?? queryItems["memo_id"]
                ?? queryItems["memo_hash"]
            guard let rawMemo, !rawMemo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let type = (queryItems["memo_type"] ?? queryItems["memotype"] ?? "")
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            if type.contains("id") || queryItems["memo_id"] != nil {
                guard let id = UInt64(rawMemo.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
                return .stellarMemo(.id(id))
            }
            if type.contains("hash") || queryItems["memo_hash"] != nil {
                return .stellarMemo(.hashHex(rawMemo.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return StellarMemoInference.infer(rawMemo).memo.map { .stellarMemo($0) }
        default:
            return nil
        }
    }

    private func applyIncomingMemo(_ memo: SendMemoValue?) {
        guard let memo else { return }
        switch memo {
        case .destinationTag(let tag) where chain == .ripple:
            destinationTagText = String(tag)
        case .stellarMemo(let stellarMemo) where chain == .stellar:
            switch stellarMemo {
            case .text(let text):
                stellarMemoText = text
            case .id(let id):
                stellarMemoText = String(id)
            case .hashHex(let hash):
                stellarMemoText = hash
            }
        case .text(let text) where chain == .stellar:
            stellarMemoText = text
        default:
            break
        }
    }

    static func shorten(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(10))…\(address.suffix(6))"
    }
}

private struct IncomingRecipientPayload {
    let address: String
    let memo: SendMemoValue?
}

private struct RecipientRoutingNote: View {
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

private struct NativeRecipientTextField: View {
    @Binding var text: String
    let prompt: String
    let label: String
    let axis: Axis
    let lineLimit: Int
    let keyboardType: UIKeyboardType
    let forceLTR: Bool
    var autocapitalization: TextInputAutocapitalization = .never
    var focusBinding: FocusState<UUID?>.Binding?
    var focusValue: UUID?

    var body: some View {
        Group {
            if let focusBinding, let focusValue {
                field
                    .focused(focusBinding, equals: focusValue)
            } else {
                field
            }
        }
        .modifier(NativeRecipientDirectionModifier(forceLTR: forceLTR))
    }

    private var field: some View {
        TextField(
            text: $text,
            prompt: Text(verbatim: prompt),
            axis: axis
        ) {
            Text(verbatim: label)
        }
        .keyboardType(keyboardType)
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled(true)
        .textFieldStyle(.automatic)
        .lineLimit(lineLimit)
    }
}

private struct NativeRecipientDirectionModifier: ViewModifier {
    let forceLTR: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if forceLTR {
            content.environment(\.layoutDirection, .leftToRight)
        } else {
            content
        }
    }
}

private struct RecipientFieldBox<Content: View>: View {
    let minHeight: CGFloat
    let content: Content

    init(minHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        content
            .font(UniTypography.body)
            .foregroundStyle(UniColors.Input.text)
            .tint(UniColors.Tint.accent)
            .padding(.horizontal, UniSpacing.mPlus)
            .padding(.vertical, UniSpacing.m)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(inputBackground)
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
            .fill(UniColors.Input.background)
    }
}

// MARK: - One recipient row (owns its resolution)

/// A single recipient row. The address itself is a native SwiftUI `TextField`
/// in the same field layout used by the import wallet phrase field.
///
/// Row anatomy (top to bottom): an optional index label (when more than one
/// recipient), the full address field (expanding, LTR-locked) with inline
/// Paste / Scan / Add-recipient utilities, and resolution feedback beneath.
/// No leading disc — the person is identified by their address, which the
/// field shows in full (Rule #7). Standard grouped-cell padding gives each
/// row its own breathing room within the shared container.
private struct RecipientRow: View {
    @Binding var entry: SendRecipientView.DraftEntry
    let chain: SupportedChain
    /// 1-based position, shown only when more than one recipient exists.
    let index: Int
    let showsIndex: Bool
    let nameHint: String?
    let canRemove: Bool
    /// True when this entry's resolved address already appears in an
    /// earlier row — suppresses the first-send warning so it fires once
    /// per distinct address, not once per duplicate field.
    let isDuplicate: Bool
    /// External focus passthrough from the parent — the field reports its
    /// identity (`entry.id`) so the parent can prune an emptied, unfocused
    /// earlier field on focus change.
    let focusBinding: FocusState<UUID?>.Binding
    let sendCount: (String) -> Int
    let showsUtilityActions: Bool
    let showsAddRecipient: Bool
    let canAddRecipient: Bool
    let onPaste: () -> Void
    let onScan: () -> Void
    let onAddRecipient: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            if showsIndex {
                Text("Recipient \(index)")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .padding(.top, UniSpacing.s)
            }

            addressField

            feedback
                .padding(.trailing, UniSpacing.m)
                .padding(.bottom, UniSpacing.s)
        }
        .task(id: entry.text) { await resolve() }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prompt: String {
        nameHint == nil ? "Recipient address" : "Address or \(nameHint!)"
    }

    private var addressField: some View {
        ZStack(alignment: .bottomTrailing) {
            TextField(
                text: $entry.text,
                prompt: Text(verbatim: prompt),
                axis: .vertical
            ) {
                Text(verbatim: "Recipient address")
            }
            .focused(focusBinding, equals: entry.id)
            .textFieldStyle(.automatic)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.default)
            .submitLabel(.done)
            .font(UniTypography.body)
            .foregroundStyle(UniColors.Input.text)
            .tint(UniColors.Tint.accent)
            .lineLimit(4...8)
            .padding(.leading, UniSpacing.mPlus)
            .padding(.trailing, canRemove ? 56 : UniSpacing.mPlus)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, showsUtilityActions ? 62 : UniSpacing.m)
            .frame(maxWidth: .infinity, minHeight: 166, alignment: .topLeading)
            .background(inputBackground)
            .environment(\.layoutDirection, .leftToRight)

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(UniColors.Feedback.Error.foreground)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove recipient"))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 6)
                .padding(.trailing, UniSpacing.xs)
            }

            if showsUtilityActions {
                fieldUtilities
                    .padding(.trailing, UniSpacing.s)
                    .padding(.bottom, UniSpacing.s)
            }
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
            .fill(UniColors.Input.background)
    }

    private var fieldUtilities: some View {
        HStack(spacing: 8) {
            fieldUtilityButton(
                title: "Paste",
                systemImage: "doc.on.clipboard",
                accessibilityLabel: "Paste recipient address",
                action: onPaste
            )
            fieldUtilityButton(
                title: "Scan",
                systemImage: "qrcode.viewfinder",
                accessibilityLabel: "Scan recipient address",
                action: onScan
            )
            if showsAddRecipient {
                fieldUtilityButton(
                    title: "Add recipient",
                    systemImage: "plus",
                    accessibilityLabel: "Add recipient",
                    isEnabled: canAddRecipient,
                    action: onAddRecipient
                )
            }
        }
    }

    private func fieldUtilityButton(
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isEnabled ? UniColors.Text.primary : UniColors.Text.disabled)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(UniColors.Input.border.opacity(0.7), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    @ViewBuilder
    private var feedback: some View {
        switch entry.resolution {
        case .empty:
            EmptyView()
        case .resolving:
            Label {
                Text("Resolving…")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            } icon: {
                ProgressView().controlSize(.mini)
            }
            .transition(.opacity)
        case let .resolved(address, name):
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                if let name {
                    HStack(spacing: UniSpacing.xxs) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(UniColors.Feedback.Success.foreground)
                        Text(verbatim: "\(name)  →  \(SendRecipientView.shorten(address))")
                            .font(UniTypography.footnote.monospaced())
                            .foregroundStyle(UniColors.Text.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if isDuplicate {
                    // Same address as an earlier row — quiet, non-warning
                    // note (the warning already fired on the first row).
                    HStack(spacing: UniSpacing.xs) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 13))
                            .foregroundStyle(UniColors.Text.tertiary)
                        Text("Same as an earlier recipient")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                } else {
                    firstSendNote(address)
                }
            }
            .transition(.opacity)
        case let .nameNotFound(name):
            Label {
                Text("Couldn't find \(name). Check the spelling, or paste the address.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Feedback.Warning.foreground)
            } icon: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Feedback.Warning.foreground)
            }
            .transition(.opacity)
        case .invalid:
            invalidFeedback
        }
    }

    /// The invalid-address feedback, with the **wrong-network** money-safety
    /// enhancement (Flow D2): when the typed value is invalid for this chain
    /// but is a valid address on a DIFFERENT network, name that network
    /// plainly — a cross-network send is unrecoverable, so it's worth more
    /// than a bare "not valid".
    @ViewBuilder
    private var invalidFeedback: some View {
        if let other = SendSafety.wrongNetwork(for: entry.text, intendedChain: chain) {
            Label {
                Text("That looks like a \(other.displayName) address — but you're sending on \(chain.displayName). Funds sent to the wrong network can't be recovered.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Feedback.Error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Feedback.Error.foreground)
            }
            .transition(.opacity)
        } else {
            Label {
                Text("That's not a valid \(chain.displayName) address.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Feedback.Error.foreground)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Feedback.Error.foreground)
            }
            .transition(.opacity)
        }
    }

    /// The honesty beat (Rule #16). First send → a plain, weighted warning
    /// that transactions can't be reversed. Repeat send → a calm, verified
    /// note with the real count.
    @ViewBuilder
    private func firstSendNote(_ address: String) -> some View {
        let count = sendCount(address)
        if count == 0 {
            HStack(alignment: .top, spacing: UniSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Feedback.Warning.foreground)
                Text("First time sending here — double-check it. Transactions can't be reversed.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Feedback.Success.foreground)
                Text(count == 1 ? "Sent here once before" : "Sent here \(count) times before")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
        }
    }

    private func resolve() async {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation(.easeOut(duration: 0.2)) { entry.resolution = .empty }
            return
        }
        if RecipientResolver.looksLikeName(trimmed, for: chain) {
            withAnimation(.easeOut(duration: 0.2)) { entry.resolution = .resolving }
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }
        let result = await RecipientResolver.resolve(trimmed, chain: chain)
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.2)) { entry.resolution = result }
    }
}
