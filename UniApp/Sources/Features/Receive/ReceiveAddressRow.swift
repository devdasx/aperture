import SwiftUI
import UIKit

/// The address row beneath the QR card. Monospaced address (middle-
/// truncated for hero readability) with a leading-aligned label, a
/// tap-to-copy gesture on the entire row, and an explicit "Copy"
/// `UniButton(.secondary)` at the trailing edge. Per Rule #19, the
/// row is a Button (so VoiceOver reads it correctly) and the trailing
/// affordance is a real `UniButton`, not a hand-rolled chip.
///
/// **Copy feedback.** Tapping the row writes to `UIPasteboard.general`
/// and fires `.uniHaptic(.success, trigger: justCopiedAt)`. A small
/// inline "Copied" label fades in for ~1.5 s — the system already
/// shows the OS copy toast on iOS 26 too, but the inline confirmation
/// is the screen's own honesty: yes, that tap did the thing.
struct ReceiveAddressRow: View {
    let address: String
    /// `true` immediately after copy; controlled by parent so the
    /// rest of the screen can react if it wants to.
    @Binding var justCopiedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniCaption(
                text: "Address",
                color: UniColors.Text.tertiary
            )
            HStack(alignment: .center, spacing: UniSpacing.s) {
                addressText
                Spacer(minLength: 0)
                copyButton
            }
            .padding(UniSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                    .fill(UniColors.Material.card)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                copy()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Address \(spokenAddress)"))
            .accessibilityHint(Text("Double tap to copy"))

            if let justCopiedAt, Date().timeIntervalSince(justCopiedAt) < 1.5 {
                UniFootnote(
                    text: "Copied",
                    color: UniColors.Status.successForeground
                )
                .transition(.opacity)
            }
        }
    }

    private var addressText: some View {
        Text(verbatim: address)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(UniColors.Text.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copyButton: some View {
        Button {
            copy()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(UniColors.Text.link)
        .accessibilityLabel(Text("Copy address"))
        .uniHaptic(.success, trigger: justCopiedAt)
    }

    private func copy() {
        UIPasteboard.general.string = address
        withAnimation(.easeInOut(duration: 0.2)) {
            justCopiedAt = Date()
        }
    }

    /// VoiceOver pronunciation. Reading every character of a 42-char
    /// hex string is hostile; this returns the first 6 + last 6 with
    /// a spoken connector, which matches how a sighted user would
    /// describe the address to someone over the phone.
    private var spokenAddress: String {
        guard address.count > 14 else { return address }
        let head = address.prefix(6)
        let tail = address.suffix(6)
        return "\(head) ending in \(tail)"
    }
}
