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
            .accessibilityLabel(Text(verbatim: String(format: String.apertureLocalized("Address %@"), spokenAddress)))

        }
    }

    private var addressText: some View {
        // Full address, multi-line wrap, LTR enforced.
        //
        // **Why drop `.truncationMode(.middle)`**: receive must show
        // every character so the user can verify what they're handing
        // out. The text row is the audit surface.
        //
        // **Why LTR**: display-only address content must not reverse
        // under RTL locales (BiDi would scramble line-break order).
        //
        // **Why natural wrap (not fixed 22-char lines)**: forced short
        // chunks left large empty padding on a wide card (e.g. Taproot
        // bc1p as three ~22-char centered lines). Let the callout fill
        // the row width and wrap only when the layout needs it. No soft
        // hyphens — `Text(verbatim:)` does not insert "-" into Latin
        // monospaced-style address strings.
        Text(verbatim: address)
            .font(UniTypography.callout)
            .foregroundStyle(UniColors.Text.primary)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .environment(\.layoutDirection, .leftToRight)
            .textSelection(.enabled)
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
