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
/// **Layers (Rule #2 §B.3).** Content layer: the recipient container + the
/// recents card + all copy — opaque `UniCard` on `Background.primary`.
/// Functional layer (Liquid Glass via system APIs only): the parent
/// nav bar, the Paste / Scan / Add chips (`.buttonStyle(.glass)` inside a
/// `GlassEffectContainer` so they morph together), and the bottom
/// Continue CTA (`UniButton(.primary)` → `.glassProminent`) in its own
/// `GlassEffectContainer`. Two glass layers max in any region; content
/// scrolls under the CTA.
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
    /// Tap counter for the ambient affordances' selection haptic — the
    /// action chips (Paste / Scan / Add) and the recents rows aren't
    /// `UniButton`s, so they fire `.uniHaptic(_:trigger:)` keyed to this
    /// on each tap (Rule #10 §B authoring pattern). One counter, one
    /// polite `.selection` beat for every "address landed / sheet opened"
    /// gesture on this screen.
    @State private var selectionTapCount: Int = 0

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
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(UniColors.Background.primary)
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
        .sheet(isPresented: $isScanning) {
            UniQRScannerSheet(
                title: "Scan address",
                prompt: "Point your camera at a \(chain.displayName) address QR code.",
                onScan: { scanned in
                    fill(cleanScanned(scanned))
                    isScanning = false
                }
            )
            .uniAppEnvironment()
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

            // CONNECTED, the Apple-native way: one inset-grouped container
            // (a single rounded `UniCard` surface) holding every recipient
            // as a ROW, rows separated by inset hairline dividers — the way
            // iOS Contacts "new contact" fields and Settings grouped forms
            // read. One continuous control, not separate floating pills.
            // The card owns the radius + the surface, so each row's field is
            // PLAIN (no per-field fill / radius).
            UniCard(padding: 0) {
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
                            onRemove: { remove(entry.id) }
                        )
                        if offset < entries.count - 1 {
                            // Inset hairline aligned under the field's text,
                            // not full-bleed — the native grouped-form look.
                            UniDivider()
                                .padding(.leading, UniSpacing.m)
                        }
                    }
                }
            }

            actionChips
                .padding(.top, UniSpacing.xxs)
        }
    }

    /// The Liquid Glass ambient-action chips (Paste / Scan / Add). Grouped
    /// in a `GlassEffectContainer` so the system can morph them as a set —
    /// the canonical place for `.buttonStyle(.glass)` (chrome, not content).
    private var actionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: UniSpacing.s) {
                HStack(spacing: UniSpacing.s) {
                    glassChip("Paste") { pasteFromClipboard() }
                    glassChip("Scan") { isScanning = true }
                    if isMulti {
                        glassChip("Add recipient", systemImage: "plus", isEnabled: canAddMore) { addEntry() }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
    }

    private func glassChip(
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
            // Hit-test the painted glass capsule, not the label's intrinsic
            // bounds (Rule #19 §D / UniButton hit-test contract).
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        // Disabled goes through the named disabled roles (Rule #4) — the
        // glass tint quiets to `Button.disabledFill` and the label / icon
        // to the disabled tone, replacing the prior `.opacity(0.4)` magic
        // literal.
        .tint(isEnabled ? UniColors.Button.secondaryTint : UniColors.Button.disabledFill)
        .disabled(!isEnabled)
    }

    // MARK: - Recents (content layer)

    @ViewBuilder
    private var recentsBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            sectionHeader("Recent")
            UniCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(recentList.enumerated()), id: \.element.id) { offset, recipient in
                        Button {
                            selectionTapCount &+= 1
                            fill(recipient.address)
                        } label: {
                            RecentRecipientRow(recipient: recipient)
                        }
                        .buttonStyle(.plain)
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
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(
                title: "Continue",
                variant: .primary,
                isEnabled: canContinue,
                action: { onContinue(resolvedRecipients) }
            )
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
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
        if let pasted = UIPasteboard.general.string {
            fill(cleanScanned(pasted))
        }
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
/// The parent `UniCard` owns the surface + radius; this row is PLAIN — a
/// transparent (`Color.clear`-filled) address field, so the rows read as
/// one continuous control separated by inset hairlines (the iOS Contacts /
/// Settings grouped-form pattern), not as separate floating pills.
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
                // PLAIN field: the container (`UniCard`) owns the surface,
                // so the field's own fill is cleared. It keeps the
                // Enter-dismiss contract, LTR lock, `axis: .vertical`
                // growth, and the external focus passthrough — only its
                // pill is removed so the rows read as one connected set.
                UniTextField(
                    placeholder: nameHint == nil ? "Recipient address" : "Address or \(nameHint!)",
                    text: $entry.text,
                    directionPolicy: .forceLTR,
                    axis: .vertical,
                    lineLimit: nil,
                    fill: Color.clear,
                    // Standard input vertical padding now that the row's
                    // own padding sets the grouped-cell height; the field
                    // still grows vertically to show a full pasted address.
                    verticalPadding: UniSpacing.s,
                    autocapitalization: .never,
                    focusBinding: focusBinding,
                    focusValue: entry.id
                )

                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(UniColors.Status.errorForeground)
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
                            .foregroundStyle(UniColors.Status.successForeground)
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
                    .foregroundStyle(UniColors.Status.warningForeground)
            } icon: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Status.warningForeground)
            }
            .transition(.opacity)
        case .invalid:
            Label {
                Text("That's not a valid \(chain.displayName) address.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Status.errorForeground)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Status.errorForeground)
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
                    .foregroundStyle(UniColors.Status.warningForeground)
                Text("First time sending here — double-check it. Transactions can't be reversed.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Status.successForeground)
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: SendRecipientView.shorten(recipient.address)))
        .accessibilityHint(Text("Use this recipient"))
    }
}
