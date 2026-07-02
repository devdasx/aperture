import SwiftUI

/// Send · Step 3 — the recipient(s). Real per-chain address validation
/// (wallet-core), real name resolution (ENS `.eth` / SNS `.sol`), real
/// recents from the wallet's outgoing history, and a real first-send
/// warning / send count per recipient.
///
/// **Redesign (2026-06-15 — Apple iOS 26 / Jony Ive).** The recipient
/// fields are CONNECTED the Apple-native way: one inset-grouped container
/// (a single rounded `UniCard` surface) holds every recipient as a ROW,
/// rows separated by inset hairline dividers — the way iOS Contacts "new
/// contact" fields and Settings grouped forms read. It is one continuous
/// control, not separate floating pills. Because the container owns the
/// surface, each row's address field is PLAIN (no per-field fill / radius).
/// The address — the load-bearing artifact of this step — still expands
/// vertically as the user types or pastes, never truncated. Restraint:
/// every element is content the user reads/acts on or chrome they touch;
/// nothing decorative survives.
///
/// **Layers (Rule #2 §B.3).** Content layer: unified input fields, custom
/// action chips, the recents card, and all copy. This recipient screen avoids
/// drop shadows and glass chips; the Send sheet chrome itself owns any system
/// presentation material.
///
/// **Multi-recipient.** Chains whose protocol can pay many recipients in
/// one transaction (UTXO, Solana, Stellar, TON, Cosmos, Sui, Polkadot,
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
    /// each `RecipientRow`'s `UniTextField` via its external focus
    /// passthrough. Drives `pruneEmptyUnfocused()` on focus change so an
    /// earlier field the user empties (and then leaves) is removed.
    @FocusState private var focusedEntry: UUID?
    @State private var isScanning: Bool = false
    /// A freshly pasted / scanned address that imitates a known recipient —
    /// presents the full-screen address-poisoning guard (Flow A3). Nil when
    /// no lookalike is pending.
    @State private var poisonLookalike: SendSafety.Lookalike?
    /// Tap counter for the ambient affordances' selection haptic — the
    /// action chips (Paste / Scan / Add) and the recents rows aren't
    /// `UniButton`s, so they fire `.uniHaptic(_:trigger:)` keyed to this
    /// on each tap (Rule #10 §B authoring pattern). One counter, one
    /// polite `.selection` beat for every "address landed / sheet opened"
    /// gesture on this screen.
    @State private var selectionTapCount: Int = 0
    /// Guards the one-time `initialRecipient` prefill so it doesn't re-run if
    /// the view re-appears.
    @State private var didConsumeInitial: Bool = false

    private var maxRecipients: Int { ChainSendCapability.maxRecipients(for: chain) }
    private var isMulti: Bool { maxRecipients > 1 }
    private var recentList: [RecentRecipient] { recents.recents(for: chain) }

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
    }

    private var resolvedRecipients: [SendRecipientEntry] {
        entries.compactMap { entry in
            if case let .resolved(address, name) = entry.resolution {
                return SendRecipientEntry(address: address, name: name)
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
                if !recentList.isEmpty {
                    recentsBlock
                }
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
        .background(SendBloomBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        // One polite `.selection` beat for every ambient affordance on the
        // screen (chips + recents) — these aren't `UniButton`s, so the
        // haptic is wired here, keyed to the shared tap counter.
        .uniHaptic(.selection, trigger: selectionTapCount)
        .safeAreaInset(edge: .bottom) { continueBar }
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
                onRawDeliver: { scanned in
                    handleIncoming(scanned)
                    isScanning = false
                }
            )
            .uniAppEnvironment()
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
                        onRemove: { remove(entry.id) }
                    )
                }
            }

            actionChips
                .padding(.top, UniSpacing.xxs)
        }
    }

    /// Custom flat action chips (Paste / Scan / Add). They intentionally avoid
    /// liquid-glass button styling and shadows on this recipient screen.
    private var actionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UniSpacing.s) {
                actionChip("Paste") { pasteFromClipboard() }
                actionChip("Scan") { isScanning = true }
                if isMulti {
                    actionChip("Add recipient", systemImage: "plus", isEnabled: canAddMore) { addEntry() }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func actionChip(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            selectionTapCount &+= 1
            action()
        } label: {
            HStack(spacing: UniSpacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isEnabled ? UniColors.Icon.primary : UniColors.Icon.disabled)
                }
                Text(title)
                    .font(UniTypography.footnote.weight(.semibold))
                    .foregroundStyle(isEnabled ? UniColors.Text.primary : UniColors.Text.disabled)
            }
            .padding(.horizontal, UniSpacing.s)
            .frame(height: 36)
            .background(
                Capsule(style: .continuous)
                    .fill(isEnabled ? UniColors.Card.background : UniColors.Button.disabledFill)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(UniColors.Stroke.regular.opacity(isEnabled ? 0.22 : 0.12), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Recents (content layer)

    @ViewBuilder
    private var recentsBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            sectionHeader("Recent")
            UniCard(padding: 0, cornerRadius: UniRadius.xl) {
                VStack(spacing: 0) {
                    ForEach(Array(recentList.enumerated()), id: \.element.id) { offset, recipient in
                        Button {
                            selectionTapCount &+= 1
                            fill(recipient.address)
                        } label: {
                            RecentRecipientRow(recipient: recipient)
                        }
                        .buttonStyle(.uniListRow)
                        if offset < recentList.count - 1 {
                            UniDivider()
                                .padding(.leading, UniSpacing.m + 36 + UniSpacing.s)
                        }
                    }
                }
            }
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
        .padding(.bottom, UniSpacing.xs)
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

    /// Place a pasted / scanned / recent address into the last empty entry,
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
    /// raise the full-screen guard instead of silently filling. Recents the
    /// user taps are known-safe and bypass this (they go straight to `fill`).
    private func handleIncoming(_ raw: String) {
        let clean = cleanScanned(raw)
        guard !clean.isEmpty else { return }
        let known = recentList.map(\.address)
        if let look = SendSafety.lookalike(for: clean, among: known, chain: chain) {
            poisonLookalike = look
            return
        }
        fill(clean)
    }

    /// Strip a URI scheme (`ethereum:`, `solana:`, …) and any query the QR
    /// / pasteboard may carry, leaving the bare address.
    private func cleanScanned(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = s.range(of: ":"), s.range(of: "://") == nil {
            let after = String(s[schemeRange.upperBound...])
            if !after.isEmpty { s = after }
        }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shorten(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(10))…\(address.suffix(6))"
    }

    static let relativeDate: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - One recipient row (owns its resolution)

/// A single recipient ROW inside the connected, inset-grouped container.
/// The address itself is a normal `UniTextField` so the screen uses the
/// app-wide input design rather than a bespoke transparent row.
///
/// Row anatomy (top to bottom): an optional index label (when more than one
/// recipient), the full address field (expanding, LTR-locked) on a line with
/// the trailing red remove control, and inline resolution feedback beneath.
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
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            if showsIndex {
                Text("Recipient \(index)")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                    // Align with the field's internal leading text inset
                    // (`UniTextField` pads `UniSpacing.m` horizontally).
                    .padding(.leading, UniSpacing.m)
                    .padding(.top, UniSpacing.s)
            }

            HStack(alignment: .top, spacing: 0) {
                UniTextField(
                    placeholder: nameHint == nil ? "Recipient address" : "Address or \(nameHint!)",
                    text: $entry.text,
                    directionPolicy: .forceLTR,
                    axis: .vertical,
                    lineLimit: nil,
                    autocapitalization: .never,
                    focusBinding: focusBinding,
                    focusValue: entry.id
                )

                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(UniColors.Feedback.Error.foreground)
                            .padding(.trailing, UniSpacing.m)
                            .padding(.top, UniSpacing.s)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove recipient"))
                }
            }

            feedback
                // Align feedback with the field's internal leading text inset.
                .padding(.leading, UniSpacing.m)
                .padding(.trailing, UniSpacing.m)
                .padding(.bottom, UniSpacing.s)
        }
        .task(id: entry.text) { await resolve() }
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Recent recipient row

/// One tappable recent-recipient row inside the recents card. Identity-
/// first: the shortened address (LTR-locked) leads, the send count + how
/// long ago sit beneath / trailing, a faint chevron signals it's tappable.
private struct RecentRecipientRow: View {
    let recipient: RecentRecipient

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: SendRecipientView.shorten(recipient.address))
                    .font(UniTypography.body.monospaced())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                Text(recipient.sendCount == 1 ? "Sent once" : "Sent \(recipient.sendCount) times")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            Spacer(minLength: UniSpacing.s)

            Text(verbatim: SendRecipientView.relativeDate.localizedString(for: recipient.lastSentAt, relativeTo: .now))
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
        .uniListRowHitTarget()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: SendRecipientView.shorten(recipient.address)))
        .accessibilityHint(Text("Use this recipient"))
    }
}
