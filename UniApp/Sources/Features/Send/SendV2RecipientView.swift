import SwiftUI

/// **Send v2 · A1 — Recipient.** Glass search field (*"Address, name, or
/// omar.eth"*), two glass chips (Paste / Scan), then Recents + Address
/// book (ENS-named entries show a green ENS ✓ chip). Tapping a row resolves
/// and routes. Pasting/typing validates per chain.
///
/// The screen renders on the bloom with its own glass back button + title
/// (the flow hides the wallet-home nav bar for v2 screens so they read
/// full-bleed on the bloom).
///
/// **Layers (Rule #2 §B.3):** content layer — recents / address-book rows
/// inside one glass card. Functional layer — the glass back button, the
/// glass search field, the bottom Continue. Two glass max in any region.
///
/// **Rule #11:** addresses render LTR (technical content the user reads);
/// chrome follows ambient.
struct SendV2RecipientView: View {
    @Bindable var model: SendV2Model
    let onResolved: () -> Void
    let onScan: () -> Void
    let onPaste: (String) -> Void
    let onOpenGuide: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    private var draft: SendDraft { model.draft }

    /// Explicit binding into the composed draft's recipient text (`draft`
    /// is a computed accessor, so `$draft` isn't available; the draft is a
    /// reference type so a manual `Binding` is the correct bridge).
    private var recipientBinding: Binding<String> {
        Binding(get: { model.draft.recipientInput }, set: { model.draft.recipientInput = $0 })
    }

    var body: some View {
        ZStack {
            SendBloomBackground()

            VStack(spacing: 0) {
                SendV2NavBar(
                    title: "Send \(draft.unitTicker)",
                    onBack: { dismiss() },
                    trailing: {
                        SendV2NavIconButton(systemName: "info.circle", accessibility: "What's a recipient address?", action: onOpenGuide)
                    }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: UniSpacing.m) {
                        searchField
                        chipRow

                        if let validation = model.pasteValidation {
                            SendV2PasteCard(validation: validation, address: draft.recipientInput, onSwitchNetwork: switchNetwork, onClear: clearPaste)
                        }

                        switch model.recipientState {
                        case .resolving:
                            resolvingRow
                        case .invalid where !draft.recipientInput.isEmpty:
                            invalidRow
                        default:
                            EmptyView()
                        }

                        recentsSection
                        addressBookSection
                    }
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.s)
                    .padding(.bottom, UniSpacing.xl)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)

                footer
            }
        }
        .navigationBarBackButtonHidden(true)
        // Resolve on input change (debounced by the seam's own latency).
        .task(id: draft.recipientInput) {
            // Skip resolving while the user is mid-type of a short string.
            let trimmed = draft.recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { model.recipientState = .empty; return }
            await model.resolveRecipient(draft.recipientInput)
            // Auto-route the high-stakes outcome immediately; resolved
            // recipients route on the Continue tap so the user can review.
            if case .poisoned = model.recipientState { onResolved() }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)

            TextField("Address, name, or omar.eth", text: recipientBinding, axis: .vertical)
                .font(UniTypography.body.monospaced())
                .lineLimit(1...3)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .foregroundStyle(UniColors.Text.primary)
                .focused($fieldFocused)
                .environment(\.layoutDirection, .leftToRight)

            if !draft.recipientInput.isEmpty {
                Button {
                    draft.recipientInput = ""
                    model.recipientState = .empty
                    model.pasteValidation = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .frame(minHeight: 52)
        .modifier(SendGlassSurface(cornerRadius: UniRadius.xl, reduceTransparency: reduceTransparency))
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: - Chips

    private var chipRow: some View {
        HStack(spacing: UniSpacing.s) {
            SendChip(title: "Paste", systemImage: "doc.on.clipboard") {
                if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                    onPaste(pasted)
                }
            }
            SendChip(title: "Scan", systemImage: "qrcode.viewfinder", action: onScan)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Resolution rows

    private var resolvingRow: some View {
        HStack(spacing: UniSpacing.xs) {
            ProgressView().controlSize(.small)
            Text("Checking address…")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
        }
        .padding(.leading, UniSpacing.xs)
    }

    private var invalidRow: some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(UniColors.Send.negative)
            Text("That doesn't look like a valid address or name.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Send.negative)
            Spacer(minLength: 0)
        }
        .padding(.leading, UniSpacing.xs)
        .uniHaptic(.error, trigger: draft.recipientInput)
    }

    // MARK: - Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            SendSectionLabel(text: "Recent")
            SendGlassCard(padding: UniSpacing.xs) {
                VStack(spacing: 0) {
                    ForEach(Array(SendV2MockData.recents.enumerated()), id: \.element.id) { index, recent in
                        Button { selectRecent(recent) } label: {
                            recentRow(recent)
                        }
                        .buttonStyle(.plain)
                        .uniHaptic(.selection, trigger: recent.id)
                        if index < SendV2MockData.recents.count - 1 {
                            UniDivider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentRow(_ recent: SendV2MockData.Recent) -> some View {
        HStack(spacing: UniSpacing.s) {
            avatar(monogram: recent.monogram, network: recent.network)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: recent.name)
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: SendDraft.shorten(recent.address))
                    .font(UniTypography.caption1.monospaced())
                    .foregroundStyle(UniColors.Text.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer(minLength: 0)
            Text(verbatim: recent.relativeWhen)
                .font(UniTypography.caption2)
                .foregroundStyle(UniColors.Text.tertiary)
        }
        .padding(.vertical, UniSpacing.xs)
        .padding(.horizontal, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(recent.name), \(recent.network.displayName), \(recent.relativeWhen)"))
    }

    // MARK: - Address book

    private var addressBookSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            SendSectionLabel(text: "Address book")
            SendGlassCard(padding: UniSpacing.xs) {
                VStack(spacing: 0) {
                    ForEach(Array(SendV2MockData.contacts.enumerated()), id: \.element.id) { index, contact in
                        Button { selectContact(contact) } label: {
                            contactRow(contact)
                        }
                        .buttonStyle(.plain)
                        .uniHaptic(.selection, trigger: contact.id)
                        if index < SendV2MockData.contacts.count - 1 {
                            UniDivider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contactRow(_ contact: SendV2MockData.Contact) -> some View {
        HStack(spacing: UniSpacing.s) {
            avatar(monogram: contact.monogram, network: contact.network)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: UniSpacing.xxs) {
                    Text(verbatim: contact.name)
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    if contact.ensVerified {
                        ensChip
                    }
                }
                Text(verbatim: SendDraft.shorten(contact.address))
                    .font(UniTypography.caption1.monospaced())
                    .foregroundStyle(UniColors.Text.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, UniSpacing.xs)
        .padding(.horizontal, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(contact.name), \(contact.network.displayName)\(contact.ensVerified ? ", ENS verified" : "")"))
    }

    private var ensChip: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text("ENS")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(UniColors.Send.positive)
        .padding(.horizontal, UniSpacing.xs)
        .padding(.vertical, 2)
        .background(Capsule().fill(UniColors.Send.positiveWash))
    }

    // MARK: - Avatar

    @ViewBuilder
    private func avatar(monogram: String, network: SupportedChain) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(UniColors.Fill.tertiary)
                .frame(width: 40, height: 40)
                .overlay {
                    Text(verbatim: monogram)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(UniColors.Text.secondary)
                }
            if let badge = network.logoAssetName {
                Image(badge)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .clipShape(Circle())
                    .background(Circle().fill(UniColors.Send.bloomBaseTop).frame(width: 20, height: 20))
                    .offset(x: 2, y: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if model.recipientState.canContinue {
                UniButton(title: "Continue", variant: .primary, action: onResolved)
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.s)
                    .padding(.bottom, UniSpacing.xs)
            }
        }
    }

    // MARK: - Actions

    private func selectRecent(_ recent: SendV2MockData.Recent) {
        draft.recipientInput = recent.address
        Task { await model.resolveRecipient(recent.address); onResolved() }
    }

    private func selectContact(_ contact: SendV2MockData.Contact) {
        draft.recipientInput = contact.address
        Task { await model.resolveRecipient(contact.address); onResolved() }
    }

    private func switchNetwork(_ suggestion: SendV2MockData.CrossNetworkSuggestion) {
        // Switch the asset to the suggested network (Flow D2). The picker
        // would normally do this; for the design we re-point the asset and
        // clear the validation.
        if let asset = draft.asset, case let .token(symbol, name, _, contract) = asset {
            draft.asset = .token(symbol: symbol, name: name, network: suggestion.network, contract: contract)
        }
        model.pasteValidation = nil
    }

    private func clearPaste() {
        draft.recipientInput = ""
        model.recipientState = .empty
        model.pasteValidation = nil
    }
}
