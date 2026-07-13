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
/// a repeat send shows the real count. If the address already belongs to
/// any wallet on this iPhone, we name that wallet instead of "first time".
/// Validation accepts only what the chain's format rules accept; a name
/// resolves only if the on-chain registry returns an address. The address
/// is LTR-locked and rendered honestly in full inside the field (Rule #11).
struct SendRecipientView: View {
    let chain: SupportedChain
    let tokenSymbol: String?
    let fromAddress: String
    let recents: RecentRecipientsIndex
    @StateObject private var databaseSnapshot = DatabaseSnapshotObservation()
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
    /// Guards the one-time `initialRecipient` prefill so it doesn't re-run if
    /// the view re-appears.
    @State private var didConsumeInitial: Bool = false
    /// XRP/XLM recipient-service routing data entered beside the address.
    @State private var destinationTagText: String = ""
    @State private var stellarMemoText: String = ""

    private var maxRecipients: Int { ChainSendCapability.maxRecipients(for: chain) }
    private var isMulti: Bool { maxRecipients > 1 }
    private var recentList: [RecentRecipient] { recents.recents(for: chain) }

    /// Stable id for the end-of-list scroll anchor (below last Paste/Scan).
    private static let recipientsScrollEndID = "send-recipients-scroll-end"

    /// Addresses on this chain that already live in any local wallet
    /// (including the one we're sending from).
    private var localWalletAddresses: LocalWalletAddressIndex {
        LocalWalletAddressIndex(
            wallets: databaseSnapshot.wallets,
            chain: chain,
            fromAddress: fromAddress
        )
    }

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

    /// Space reserved under the scroll content so the last recipient row
    /// (field + Paste/Scan/Add) can sit fully above the floating Continue bar.
    private var bottomScrollClearance: CGFloat {
        // Continue button (~52) + bar padding + home indicator + utility row.
        120
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    recipientsBlock

                    // Scroll target below Paste/Scan so those controls land
                    // above the Continue overlay, not under it.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.recipientsScrollEndID)
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.m)
            }
            // Inset the scrollable viewport so `scrollTo(..., .bottom)` clears
            // the floating Continue bar (`uniBottomActionBar` is an overlay).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: bottomScrollClearance)
                    .accessibilityHidden(true)
            }
            // When focus moves between recipient fields, prune any earlier
            // field the user emptied and left. Keyed on focus-change (not
            // mid-keystroke) so it never deletes the field being edited.
            .onChange(of: focusedEntry) { _, _ in pruneEmptyUnfocused() }
            .onChange(of: entries.count) { _, newCount in
                // After "Add recipient", scroll until the new field + Paste/Scan
                // sit above Continue.
                guard newCount > 1 else { return }
                scrollToNewestRecipient(proxy: proxy)
            }
        }
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
            sectionHeader(
                entries.count > 1 ? "Recipients (\(entries.count))" : "Recipients"
            )

            // One connected inset group (Settings / Send amount multi-list).
            UniCard(padding: 0, fill: UniColors.List.rowBackground) {
                VStack(spacing: 0) {
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
                            localWalletMatch: { localWalletAddresses.match(for: $0) },
                            showsUtilityActions: offset == entries.count - 1,
                            showsAddRecipient: isMulti,
                            canAddRecipient: canAddMore,
                            onPaste: { pasteFromClipboard() },
                            onScan: { isScanning = true },
                            onAddRecipient: { addEntry() },
                            onRemove: { remove(entry.id) }
                        )
                        .id(entry.id)
                        if offset < entries.count - 1 || showsRecipientMemo {
                            UniDivider().padding(.leading, UniSpacing.m)
                        }
                    }

                    if showsRecipientMemo {
                        recipientMemoInputRow
                    }
                }
            }

            if showsRecipientMemo {
                recipientMemoGuidance
                    .padding(.top, UniSpacing.xxs)
            }
        }
    }

    @ViewBuilder
    private var recipientMemoInputRow: some View {
        switch chain {
        case .ripple:
            UniTextField(
                placeholder: "Destination tag (optional)",
                text: $destinationTagText,
                directionPolicy: .forceLTR,
                fill: Color.clear,
                verticalPadding: UniSpacing.s,
                showsChrome: false,
                keyboardType: .numberPad
            )
            .padding(.horizontal, UniSpacing.xs)
            .padding(.vertical, UniSpacing.xs)
        case .stellar:
            UniTextField(
                placeholder: "Memo, ID, or hash",
                text: $stellarMemoText,
                directionPolicy: stellarMemoInference.isTextLike ? .automatic : .forceLTR,
                axis: .vertical,
                lineLimit: stellarMemoInference.isTextLike ? 2 : 1,
                fill: Color.clear,
                verticalPadding: UniSpacing.s,
                showsChrome: false,
                keyboardType: .default
            )
            .padding(.horizontal, UniSpacing.xs)
            .padding(.vertical, UniSpacing.xs)
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
                    memoError(String.apertureLocalized("Destination tag must be a number from 0 to 4,294,967,295."))
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
                .font(.system(size: 12, weight: .regular))
            Text(verbatim: String(format: String.apertureLocalized("Detected: %@"), type))
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
        let newEntry = DraftEntry()
        withAnimation(.snappy(duration: 0.25)) {
            entries.append(newEntry)
        }
        // Land the user in the freshly-added field (scroll follows via
        // ScrollViewReader + `.onChange(of: entries.count)`).
        focusedEntry = newEntry.id
    }

    /// Scroll so the newest recipient field and its Paste/Scan row clear the
    /// floating Continue bar.
    private func scrollToNewestRecipient(proxy: ScrollViewProxy) {
        Task { @MainActor in
            // Wait for the new row (+ utility buttons) to lay out.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.snappy(duration: 0.35)) {
                // Prefer the end anchor under utilities; fall back to last row.
                proxy.scrollTo(Self.recipientsScrollEndID, anchor: .bottom)
            }
            // Second pass after focus/keyboard settles.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(Self.recipientsScrollEndID, anchor: .bottom)
            }
        }
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

    /// Place a pasted / scanned address into the **last empty** entry only.
    /// Never appends a new recipient — only **Add recipient** grows the list.
    /// A second Paste/Scan while the field already has text is a no-op.
    private func fill(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard let lastIndex = entries.indices.last else { return }
        let lastText = entries[lastIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lastText.isEmpty else { return }
        entries[lastIndex].text = clean
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

// MARK: - One recipient row (owns its resolution)

/// List-style address row inside the connected recipients `UniCard`.
/// Uses chrome-free `UniTextField` so rows share one grouped surface
/// (same pattern as the multi-recipient amount list).
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
    /// When non-nil, this address is already on a wallet in the app.
    let localWalletMatch: (String) -> LocalWalletAddressMatch?
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
                Text(verbatim: String(format: String.apertureLocalized("Recipient %lld"), Int64(index)))
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .padding(.horizontal, UniSpacing.m)
                    .padding(.top, UniSpacing.s)
            }

            HStack(alignment: .top, spacing: UniSpacing.xs) {
                UniTextField(
                    placeholder: prompt,
                    text: $entry.text,
                    directionPolicy: .forceLTR,
                    axis: .vertical,
                    lineLimit: 3,
                    fill: Color.clear,
                    verticalPadding: UniSpacing.s,
                    showsChrome: false,
                    focusBinding: focusBinding,
                    focusValue: entry.id
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)

                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(UniColors.Feedback.Error.foreground)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.uniTactile)
                    .accessibilityLabel(Text("Remove recipient"))
                    .padding(.trailing, UniSpacing.xs)
                    .padding(.top, UniSpacing.xxs)
                }
            }

            // Paste/Scan hide once the field has text; Add recipient stays.
            // After Add recipient, the new empty row shows Paste/Scan again.
            if showsUtilityActions, fieldIsEmpty || showsAddRecipient {
                fieldUtilities
                    .padding(.horizontal, UniSpacing.m)
                    .padding(.bottom, UniSpacing.s)
            }

            feedback
                .padding(.horizontal, UniSpacing.m)
                .padding(.bottom, UniSpacing.s)
        }
        .task(id: entry.text) { await resolve() }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prompt: String {
        nameHint == nil ? "Recipient address" : "Address or \(nameHint!)"
    }

    /// Paste/Scan only while this field is empty; Add recipient stays when multi-send.
    private var fieldIsEmpty: Bool {
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fieldUtilities: some View {
        HStack(spacing: 8) {
            if fieldIsEmpty {
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
            }
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
                .font(.system(size: 14, weight: .regular))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isEnabled ? UniColors.Text.primary : UniColors.Text.disabled)
                .padding(.horizontal, 12)
                .frame(height: 34)
        }
        .buttonStyle(.borderless)
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
                    recipientOwnershipOrSendNote(address)
                }
            }
            .transition(.opacity)
        case let .nameNotFound(name):
            Label {
                Text(verbatim: String(format: String.apertureLocalized("Couldn't find %@. Check the spelling, or paste the address."), name))
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
                Text(verbatim: String(format: String.apertureLocalized("That looks like a %@ address — but you're sending on %@. Funds sent to the wrong network can't be recovered."), other.displayName, chain.displayName))
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
                Text(verbatim: String(format: String.apertureLocalized("That's not a valid %@ address."), chain.displayName))
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

    /// Local wallet ownership first; otherwise first-send warning or prior-send count.
    @ViewBuilder
    private func recipientOwnershipOrSendNote(_ address: String) -> some View {
        if let match = localWalletMatch(address) {
            HStack(alignment: .top, spacing: UniSpacing.xs) {
                Image(systemName: match.isSendingWallet ? "wallet.bifold.fill" : "wallet.bifold")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Feedback.Success.foreground)
                Text(verbatim: match.displayMessage)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            firstSendNote(address)
        }
    }

    /// First send → short double-check note. Repeat send → real prior-send count.
    @ViewBuilder
    private func firstSendNote(_ address: String) -> some View {
        let count = sendCount(address)
        if count == 0 {
            HStack(alignment: .top, spacing: UniSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Feedback.Warning.foreground)
                Text("First time sending here — double-check it.")
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

// MARK: - Local wallet address ownership

/// Recipient address already stored on a wallet in this app.
struct LocalWalletAddressMatch: Sendable, Equatable {
    let walletName: String
    /// `true` when the address is on the wallet we're sending *from*
    /// (including other paths/addresses of that wallet).
    let isSendingWallet: Bool

    var displayMessage: String {
        if isSendingWallet {
            return String(
                format: String.apertureLocalized("Your address · %@"),
                walletName
            )
        }
        return String(
            format: String.apertureLocalized("Belongs to %@"),
            walletName
        )
    }
}

/// Lookup of every on-device wallet address for one chain.
struct LocalWalletAddressIndex: Sendable {
    private struct Owner: Sendable {
        let walletId: UUID
        let name: String
    }

    private let byNormalizedAddress: [String: Owner]
    private let sendingWalletId: UUID?
    private let chain: SupportedChain

    init(wallets: [WalletRecord], chain: SupportedChain, fromAddress: String) {
        self.chain = chain
        var map: [String: Owner] = [:]
        let fromKey = Self.normalize(fromAddress, chain: chain)
        var sendingId: UUID?

        for wallet in wallets {
            for address in wallet.addresses where address.chainRaw == chain.rawValue {
                let key = Self.normalize(address.address, chain: chain)
                guard !key.isEmpty else { continue }
                map[key] = Owner(walletId: wallet.id, name: wallet.name)
                if key == fromKey {
                    sendingId = wallet.id
                }
            }
        }

        // Ensure the live from-address is indexed even if observation is briefly stale.
        if sendingId == nil, !fromKey.isEmpty, let existing = map[fromKey] {
            sendingId = existing.walletId
        }

        self.byNormalizedAddress = map
        self.sendingWalletId = sendingId
    }

    func match(for address: String) -> LocalWalletAddressMatch? {
        let key = Self.normalize(address, chain: chain)
        guard let owner = byNormalizedAddress[key] else { return nil }
        let isFromWallet = sendingWalletId.map { $0 == owner.walletId } ?? false
        return LocalWalletAddressMatch(
            walletName: owner.name,
            isSendingWallet: isFromWallet
        )
    }

    private static func normalize(_ address: String, chain: SupportedChain) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return chain.family == .evm ? trimmed.lowercased() : trimmed
    }
}
