import SwiftUI

/// The address row beneath the QR card. Full centered address text with a
/// leading-aligned label. Copying is owned by the parent action row so a
/// casual address tap never writes to the pasteboard.
struct ReceiveAddressRow: View {
    let address: String

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
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Address \(spokenAddress)"))

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
        // **Manual visual line breaks.** Letting SwiftUI hyphenate one
        // continuous address can add a visual "-" at a wrap point. We
        // keep copy/paste tied to the original `address`, but display
        // predictable centered lines.
        Text(verbatim: displayAddress)
            .font(UniTypography.callout)
            .foregroundStyle(UniColors.Text.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .environment(\.layoutDirection, .leftToRight)
    }

    private var displayAddress: String {
        guard address.count > 24 else { return address }
        let lineLength = address.count <= 44
            ? max(1, (address.count + 1) / 2)
            : 22
        var lines: [String] = []
        var start = address.startIndex
        while start < address.endIndex {
            let end = address.index(start, offsetBy: lineLength, limitedBy: address.endIndex) ?? address.endIndex
            lines.append(String(address[start..<end]))
            start = end
        }
        return lines.joined(separator: "\n")
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
