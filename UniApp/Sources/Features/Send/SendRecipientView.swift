import SwiftUI

/// **Send · Screen 1 — Recipient ("Send to").**
///
/// A monospace address field with an inline Scan affordance, quick
/// Paste / Scan / Contacts chips, a live mock name-resolution row, a
/// Recent list, and address-safety affordances (first-send, network-match
/// — designed, mock data). The Continue CTA is gated on the draft's
/// placeholder validity flag.
///
/// **Layers (Rule #2 §B.3):** content layer — the opaque field, chips,
/// and recents on `Background.primary`. Functional layer — the parent's
/// nav bar + the bottom `UniButton(.primary)` Continue. Two glass max.
///
/// **Rule #11.** The address field forces LTR (it's English-shaped
/// technical content the user reads / transcribes); the recents addresses
/// render LTR too. Chrome (chip labels, section headers) follows ambient.
struct SendRecipientView: View {
    @Bindable var draft: SendDraft
    let onContinue: () -> Void
    let onScan: () -> Void
    let onOpenGuide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.m) {
                    addressField
                    if draft.resolvedName != nil {
                        resolvedRow
                    }
                    quickRow
                    recentsSection
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.s)
            }
            .scrollDismissesKeyboard(.interactively)

            footer
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Send to")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenGuide) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .regular))
                        .accessibilityLabel(Text("What's a recipient address?"))
                }
            }
        }
    }

    // MARK: - Address field

    private var addressField: some View {
        HStack(spacing: UniSpacing.s) {
            TextField(
                "Address or ENS name",
                text: $draft.recipientInput,
                axis: .vertical
            )
            .font(UniTypography.body.monospaced())
            .lineLimit(1...3)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .foregroundStyle(UniColors.Text.primary)
            // Rule #11 — addresses are LTR technical content.
            .environment(\.layoutDirection, .leftToRight)

            Button(action: onScan) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: UniRadius.s, style: .continuous)
                            .fill(UniColors.Fill.tertiary)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: UniRadius.s, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Scan QR code"))
        }
        .padding(UniSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }

    // MARK: - Resolution / validity rows

    private var resolvedRow: some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Send.positive)
            Text("Resolves to \(SendDraft.shorten(draft.resolvedAddress ?? "")) · \(networkName)")
                .font(UniTypography.footnote.weight(.semibold))
                .foregroundStyle(UniColors.Send.positive)
                .environment(\.layoutDirection, .leftToRight)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.xxs)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Quick row (Paste / Scan / Contacts)

    private var quickRow: some View {
        HStack(spacing: UniSpacing.xs) {
            quickChip(icon: "doc.on.clipboard", label: "Paste", action: paste)
            quickChip(icon: "qrcode.viewfinder", label: "Scan", action: onScan)
            quickChip(icon: "person.crop.circle", label: "Contacts", action: {})
        }
        .padding(.top, UniSpacing.xxs)
    }

    @ViewBuilder
    private func quickChip(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(UniColors.Icon.secondary)
                Text(label)
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                    .fill(UniColors.Background.secondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniCaption(text: "Recent", color: UniColors.Text.tertiary)
                .padding(.leading, UniSpacing.xxs)
                .padding(.top, UniSpacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(SendMockData.recents.enumerated()), id: \.element.id) { index, recent in
                    Button {
                        draft.recipientInput = recent.address
                    } label: {
                        recentRow(recent)
                    }
                    .buttonStyle(.plain)
                    if index < SendMockData.recents.count - 1 {
                        UniDivider()
                            .padding(.leading, 52)
                    }
                }
            }
            .padding(.horizontal, UniSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Background.secondary)
            )
        }
    }

    @ViewBuilder
    private func recentRow(_ recent: SendMockData.Recent) -> some View {
        HStack(spacing: UniSpacing.s) {
            Circle()
                .fill(UniColors.Fill.tertiary)
                .frame(width: 40, height: 40)
                .overlay {
                    Text(verbatim: recent.monogram)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(UniColors.Text.secondary)
                }
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
            if let badge = recent.network.logoAssetName {
                Image(badge)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(recent.name), \(recent.network.displayName)"))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            UniDivider()
            UniButton(
                title: "Continue",
                variant: .primary,
                isEnabled: draft.isRecipientValid,
                action: onContinue
            )
            .padding(.horizontal, UniSpacing.m)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
        .background(UniColors.Background.primary)
    }

    // MARK: - Helpers

    private var networkName: String {
        draft.network?.displayName ?? "Ethereum"
    }

    private func paste() {
        // Design-time paste from the system pasteboard — no malicious-swap
        // guard yet. `// TODO: (T-062)` add the paste-from-clipboard
        // address-safety guard (handoff "address safety").
        if let pasted = UIPasteboard.general.string {
            draft.recipientInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
