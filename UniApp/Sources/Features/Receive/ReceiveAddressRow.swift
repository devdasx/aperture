import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    /// Visibility of the inline "Copied" confirmation. Flipped true
    /// on copy and back false ~1.5s later by `copiedResetTask`, so
    /// the label actually expires instead of lingering until some
    /// unrelated re-render happens to re-evaluate a date check.
    @State private var isShowingCopied: Bool = false
    /// Pending auto-hide task — cancelled and recreated on re-copy,
    /// cancelled in `onDisappear`.
    @State private var copiedResetTask: Task<Void, Never>?

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
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Material.card)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                copy()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Address \(spokenAddress)"))
            .accessibilityHint(Text("Double tap to copy"))

            if isShowingCopied {
                UniFootnote(
                    text: "Copied",
                    color: UniColors.Status.successForeground
                )
                .transition(.opacity)
            }
        }
        .onDisappear {
            copiedResetTask?.cancel()
        }
    }

    private var addressText: some View {
        // 2026-06-09 — full address, multi-line wrap, LTR enforced.
        //
        // **Why drop `.truncationMode(.middle)`**: the user direction
        // was to *"make the address visible fully"* — a self-custody
        // wallet's receive surface must show every character so the
        // user can verify what they're handing out. Middle-truncation
        // hid 20+ characters; verification by eye was impossible.
        // The hero card already has the QR for one-tap copy; the
        // text row is the *audit* surface. It must be honest.
        //
        // **Why `.environment(\.layoutDirection, .leftToRight)`**:
        // per Rule #11 Part C, display-only English content
        // (addresses, recovery phrases, hashes) must render LTR in
        // every locale so the ordinal reading order matches what
        // the user will transcribe / verify. In an Arabic / Hebrew
        // / Persian / Urdu layout, the BiDi algorithm would
        // otherwise reorder address segments at line breaks and
        // the user would copy a corrupted address. Scoped to just
        // this text subtree so the surrounding chrome (label,
        // "Copied" status) keeps the ambient locale's direction.
        //
        // **`.fixedSize(horizontal: false, vertical: true)`** lets
        // the text grow vertically for long addresses while staying
        // within the row's horizontal width — the canonical
        // SwiftUI pattern for "wrap multi-line, don't truncate."
        Text(verbatim: address)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(UniColors.Text.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight)
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
        // 2-minute pasteboard expiry. A receive address is public
        // data, but an unbounded pasteboard entry lingers across
        // every app the user pastes into afterwards. The expiration
        // keeps the copy useful for the immediate share and gone
        // after that.
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: address]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            justCopiedAt = Date()
            isShowingCopied = true
        }
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingCopied = false
            }
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
