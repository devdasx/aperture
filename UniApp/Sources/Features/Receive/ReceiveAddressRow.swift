import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The address row beneath the QR card. Monospaced address with a
/// leading-aligned label and a tap-to-copy gesture on the entire row.
/// The visible copy affordance lives in the parent action row.
///
/// **Copy feedback.** Tapping the row writes to `UIPasteboard.general`
/// and notifies the parent through `justCopiedAt`; the visible feedback
/// lives in the action button so the screen has one clear confirmation.
struct ReceiveAddressRow: View {
    let address: String
    /// Non-nil immediately after copy; controlled by the parent so the
    /// rest of the screen can react with a single shared copy state.
    @Binding var justCopiedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniCaption(
                text: "Address",
                color: UniColors.Text.tertiary
            )
            HStack(alignment: .center, spacing: UniSpacing.s) {
                addressText
            }
            .padding(UniSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Card.background)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                copy()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Address \(spokenAddress)"))
            .accessibilityHint(Text("Double tap to copy"))

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
        // this text subtree so the surrounding chrome keeps the
        // ambient locale's direction.
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

    private func copy() {
        // 2-minute pasteboard expiry. A receive address is public
        // data, but an unbounded pasteboard entry lingers across
        // every app the user pastes into afterwards. The expiration
        // keeps the copy useful for the immediate share and gone
        // after that.
        SafePasteboard.setItems(
            [[UTType.plainText.identifier: address]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        justCopiedAt = Date()
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
