import SwiftUI

/// Send · Step 3 — the recipient(s). Real per-chain address validation
/// (wallet-core), real name resolution (ENS `.eth` / SNS `.sol`), real
/// recents from the wallet's outgoing history, and a real first-send
/// warning / send count per recipient.
///
/// **Multi-recipient (2026-06-15).** Chains whose protocol can pay many
/// recipients in one transaction (UTXO, Solana, Stellar, TON, Cosmos,
/// Sui, Polkadot, Aptos — see `ChainSendCapability`) get a native
/// add-more-addresses list, each row independently validated/resolved.
/// Single-recipient chains (EVM, TRON, XRPL, NEAR) keep one field.
///
/// **Honesty (Rule #16).** A first send to an address is flagged plainly;
/// a repeat send shows the real count. Validation accepts only what the
/// chain's format rules accept; a name resolves only if the on-chain
/// registry returns an address.
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
    @State private var isScanning: Bool = false

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

    private var canAddMore: Bool {
        isMulti && entries.count < maxRecipients
            && !(entries.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                recipientsSection
                if !recentList.isEmpty {
                    recentsSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)

            footer
        }
        .background(UniColors.Background.primary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoinTitleBar(chain: chain, tokenSymbol: tokenSymbol, verb: "Send", trailing: "to")
            }
        }
        .sheet(isPresented: $isScanning) {
            BrowserQRScanSheet(onScan: { scanned in
                fill(cleanScanned(scanned))
                isScanning = false
            })
            .uniAppEnvironment()
        }
    }

    // MARK: - Recipients

    @ViewBuilder
    private var recipientsSection: some View {
        Section {
            ForEach($entries) { $entry in
                RecipientFieldRow(
                    entry: $entry,
                    chain: chain,
                    nameHint: nameHint,
                    canRemove: entries.count > 1,
                    sendCount: { recents.sendCount(to: $0, chain: chain) },
                    onRemove: { remove(entry.id) }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: UniSpacing.xs, leading: 0, bottom: UniSpacing.xs, trailing: 0))
            }

            actionRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: UniSpacing.xs, trailing: 0))
        } header: {
            if isMulti {
                UniCaption(
                    text: entries.count > 1 ? "Recipients (\(entries.count))" : "Recipients",
                    color: UniColors.Text.tertiary
                )
            }
        } footer: {
            if isMulti {
                Text("\(chain.displayName) can pay up to \(maxRecipients) recipients in one transaction.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: UniSpacing.s) {
            actionChip("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
            actionChip("Scan", systemImage: "qrcode.viewfinder") { isScanning = true }
            if isMulti {
                actionChip("Add recipient", systemImage: "plus") { addEntry() }
                    .opacity(canAddMore ? 1 : 0.4)
                    .disabled(!canAddMore)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsSection: some View {
        Section {
            ForEach(recentList) { recipient in
                Button {
                    fill(recipient.address)
                } label: {
                    recentRow(recipient)
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
            }
        } header: {
            UniCaption(text: "Recent", color: UniColors.Text.tertiary)
        }
    }

    private func recentRow(_ recipient: RecentRecipient) -> some View {
        HStack(spacing: UniSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: SendRecipientView.shorten(recipient.address))
                    .font(UniTypography.body.monospaced())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                Text(recipient.sendCount == 1 ? "Sent once" : "Sent \(recipient.sendCount) times")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            Spacer(minLength: 0)
            Text(verbatim: Self.relativeDate.localizedString(for: recipient.lastSentAt, relativeTo: .now))
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Footer

    private var footer: some View {
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

    // MARK: - Mutations

    private func addEntry() {
        guard canAddMore else { return }
        entries.append(DraftEntry())
    }

    private func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty { entries = [DraftEntry()] }
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
            entries.append(DraftEntry(text: clean))
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

    private func actionChip(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: UniSpacing.xxs) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(UniTypography.footnote.weight(.semibold))
            }
            .foregroundStyle(UniColors.Tint.accent)
            .padding(.horizontal, UniSpacing.s)
            .padding(.vertical, UniSpacing.xs)
            .background(Capsule().fill(UniColors.Background.secondary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    static func shorten(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(10))…\(address.suffix(6))"
    }

    private static let relativeDate: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - One recipient row (owns its resolution)

private struct RecipientFieldRow: View {
    @Binding var entry: SendRecipientView.DraftEntry
    let chain: SupportedChain
    let nameHint: String?
    let canRemove: Bool
    let sendCount: (String) -> Int
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                UniTextField(
                    placeholder: nameHint == nil ? "Recipient address" : "Address or \(nameHint!)",
                    text: $entry.text,
                    directionPolicy: .forceLTR,
                    axis: .vertical,
                    lineLimit: nil,
                    cornerRadius: UniRadius.xxxl,
                    autocapitalization: .never
                )
                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(UniColors.Icon.tertiary)
                            .padding(.top, UniSpacing.xs)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove recipient"))
                }
            }
            feedback
        }
        .task(id: entry.text) { await resolve() }
    }

    @ViewBuilder
    private var feedback: some View {
        switch entry.resolution {
        case .empty:
            EmptyView()
        case .resolving:
            HStack(spacing: UniSpacing.xs) {
                ProgressView().controlSize(.mini)
                Text("Resolving…")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        case let .resolved(address, name):
            VStack(alignment: .leading, spacing: 2) {
                if let name {
                    Text(verbatim: "\(name) → \(SendRecipientView.shorten(address))")
                        .font(UniTypography.footnote.monospaced())
                        .foregroundStyle(UniColors.Text.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                firstSendBadge(address)
            }
        case let .nameNotFound(name):
            Text("Couldn't find \(name). Check the spelling, or paste the address.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Status.warningForeground)
        case .invalid:
            Text("That's not a valid \(chain.displayName) address.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Status.errorForeground)
        }
    }

    @ViewBuilder
    private func firstSendBadge(_ address: String) -> some View {
        let count = sendCount(address)
        if count == 0 {
            HStack(alignment: .top, spacing: UniSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UniColors.Status.warningForeground)
                Text("First time sending here — double-check it, transactions can't be reversed.")
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
        guard !trimmed.isEmpty else { entry.resolution = .empty; return }
        if RecipientResolver.looksLikeName(trimmed, for: chain) {
            entry.resolution = .resolving
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }
        let result = await RecipientResolver.resolve(trimmed, chain: chain)
        if Task.isCancelled { return }
        entry.resolution = result
    }
}
