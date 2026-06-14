import SwiftUI

/// Send · Step 3 — the recipient. Real per-chain address validation
/// (wallet-core), real name resolution (ENS `.eth` on EVM, SNS `.sol` on
/// Solana), real recent-recipients from the wallet's outgoing history, and
/// a real first-send warning / send-count badge.
///
/// **Honesty (Rule #16).** A first send to an address is flagged plainly
/// ("double-check — can't be reversed"); a repeat send is reassured with
/// the real count. Nothing is faked: validation accepts only what the
/// chain's format rules accept, and a name only resolves if the on-chain
/// registry returns an address.
struct SendRecipientView: View {
    let chain: SupportedChain
    let tokenSymbol: String?
    let fromAddress: String
    let recents: RecentRecipientsIndex
    /// Proceed to the amount step with the resolved on-chain address and
    /// the name it was resolved from (nil when an address was typed).
    let onContinue: (_ address: String, _ name: String?) -> Void

    @State private var input: String = ""
    @State private var resolution: RecipientResolution = .empty
    @State private var isScanning: Bool = false

    private var assetLabel: String { tokenSymbol ?? chain.ticker }
    private var recentList: [RecentRecipient] { recents.recents(for: chain) }

    /// The supported-name hint for this chain (only EVM/Solana have one).
    private var nameHint: String? {
        if chain.family == .evm { return ".eth name" }
        if chain == .solana { return ".sol name" }
        return nil
    }

    private var resolvedAddress: String? {
        if case let .resolved(address, _) = resolution { return address }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                inputSection
                if let address = resolvedAddress {
                    firstSendSection(address)
                }
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
        .task(id: input) { await resolveInput() }
        .sheet(isPresented: $isScanning) {
            BrowserQRScanSheet(onScan: { scanned in
                input = cleanScanned(scanned)
                isScanning = false
            })
            .uniAppEnvironment()
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var inputSection: some View {
        Section {
            UniTextField(
                placeholder: nameHint == nil ? "Recipient address" : "Address or \(nameHint!)",
                text: $input,
                directionPolicy: .forceLTR,
                axis: .vertical,
                lineLimit: nil,
                cornerRadius: UniRadius.xxxl,
                autocapitalization: .never
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: UniSpacing.xs, leading: 0, bottom: UniSpacing.xs, trailing: 0))

            HStack(spacing: UniSpacing.s) {
                actionChip("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
                actionChip("Scan", systemImage: "qrcode.viewfinder") { isScanning = true }
                Spacer(minLength: 0)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: UniSpacing.xs, trailing: 0))
        } footer: {
            resolutionFeedback
        }
    }

    @ViewBuilder
    private var resolutionFeedback: some View {
        switch resolution {
        case .empty:
            if let hint = nameHint {
                Text("Enter a \(chain.displayName) address or a \(hint).")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            } else {
                Text("Enter a \(chain.displayName) address.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        case .resolving:
            HStack(spacing: UniSpacing.xs) {
                ProgressView().controlSize(.mini)
                Text("Resolving…")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            .padding(.top, UniSpacing.xxs)
        case let .resolved(address, name):
            if let name {
                HStack(spacing: UniSpacing.xxs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(UniColors.Status.successForeground)
                    Text(verbatim: "\(name) → \(SendRecipientView.shorten(address))")
                        .font(UniTypography.footnote.monospaced())
                        .foregroundStyle(UniColors.Text.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .padding(.top, UniSpacing.xxs)
            } else {
                EmptyView()
            }
        case let .nameNotFound(name):
            Text("Couldn't find \(name). Check the spelling, or paste the address directly.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Status.warningForeground)
                .padding(.top, UniSpacing.xxs)
        case .invalid:
            Text("That's not a valid \(chain.displayName) address.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Status.errorForeground)
                .padding(.top, UniSpacing.xxs)
        }
    }

    // MARK: - First-send / count

    @ViewBuilder
    private func firstSendSection(_ address: String) -> some View {
        let count = recents.sendCount(to: address, chain: chain)
        Section {
            if count == 0 {
                HStack(alignment: .top, spacing: UniSpacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(UniColors.Status.warningForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("First time sending here")
                            .font(UniTypography.subheadlineEmphasized)
                            .foregroundStyle(UniColors.Text.primary)
                        Text("You've never sent to this address before. Double-check every character — crypto transactions can't be reversed.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listRowBackground(UniColors.Background.secondary)
            } else {
                HStack(alignment: .top, spacing: UniSpacing.s) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(UniColors.Status.successForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count == 1 ? "Sent here once before" : "Sent here \(count) times before")
                            .font(UniTypography.subheadlineEmphasized)
                            .foregroundStyle(UniColors.Text.primary)
                        Text("This is an address you've used before.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.secondary)
                    }
                }
                .listRowBackground(UniColors.Background.secondary)
            }
        }
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsSection: some View {
        Section {
            ForEach(recentList) { recipient in
                Button {
                    input = recipient.address
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
            isEnabled: resolvedAddress != nil,
            action: {
                if case let .resolved(address, name) = resolution {
                    onContinue(address, name)
                }
            }
        )
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.s)
        .padding(.bottom, UniSpacing.xs)
    }

    // MARK: - Behavior

    private func resolveInput() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { resolution = .empty; return }

        // Debounce only the name path (it hits the network); a raw
        // address validates instantly.
        if RecipientResolver.looksLikeName(trimmed, for: chain) {
            resolution = .resolving
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }
        let result = await RecipientResolver.resolve(trimmed, chain: chain)
        if Task.isCancelled { return }
        resolution = result
    }

    private func pasteFromClipboard() {
        if let pasted = UIPasteboard.general.string {
            input = cleanScanned(pasted)
        }
    }

    /// Strip a URI scheme (`ethereum:`, `solana:`, …) and any query the
    /// QR / pasteboard may carry, leaving the bare address.
    private func cleanScanned(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = s.range(of: ":"), s.range(of: "://") == nil {
            // "ethereum:0x.." → drop "ethereum:" (but keep "https://..").
            let after = String(s[schemeRange.upperBound...])
            if !after.isEmpty { s = after }
        }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) } // "addr@chainId"
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
