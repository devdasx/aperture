import SwiftUI

/// **Send v2 · A3 — Address-poisoning guard (interstitial).** Triggered
/// when a pasted address matches a known address's first ≥4 and last ≥4
/// chars but differs in the middle (the dust-attack pattern). Full-screen,
/// red-tinted bloom, a warning hero, and two monospace compare cards:
/// **Saved** (green header, matching prefix/suffix bold, middle dimmed) and
/// **Pasted just now** (red header, same prefix/suffix bold, the differing
/// middle highlighted red).
///
/// **Cannot be skipped silently** (handoff). The default is the saved
/// address; *"Continue with pasted address"* is a ghost red button that
/// requires a **deliberate second tap** to confirm.
///
/// **Rule #16 (security surface).** This is the wallet's most consequential
/// honesty moment. The hero, the side-by-side comparison, and the
/// two-tap confirmation make the poisoning legible and the override
/// deliberate.
struct SendV2PoisoningView: View {
    let match: SendV2Model.PoisonMatch
    let onUseSaved: () -> Void
    let onContinueAnyway: () -> Void
    let onBack: () -> Void

    /// The ghost "continue anyway" requires a second tap. First tap arms
    /// it; second tap confirms (handoff: *"a deliberate second tap"*).
    @State private var continueArmed: Bool = false
    @State private var appearTick: Int = 0

    var body: some View {
        ZStack {
            SendBloomBackground(danger: true)

            VStack(spacing: 0) {
                SendV2NavBar(title: "Check this address", onBack: onBack)

                ScrollView {
                    VStack(spacing: UniSpacing.m) {
                        hero
                        headline
                        compareCard(
                            title: "Saved · \(match.savedName)",
                            header: .saved,
                            address: match.savedAddress,
                            differingAgainst: match.pastedAddress
                        )
                        compareCard(
                            title: "Pasted just now",
                            header: .pasted,
                            address: match.pastedAddress,
                            differingAgainst: match.savedAddress
                        )
                    }
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.s)
                    .padding(.bottom, UniSpacing.xl)
                }
                .scrollIndicators(.hidden)

                footer
            }
        }
        .navigationBarBackButtonHidden(true)
        // `.warning` once, as the screen slides in (handoff).
        .uniHaptic(.warning, trigger: appearTick)
        .onAppear { appearTick += 1 }
    }

    // MARK: - Hero + headline

    private var hero: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 34, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Send.negative)
            .frame(width: 72, height: 72)
            .background(Circle().fill(UniColors.Send.negativeWash))
            .symbolEffect(.bounce, options: .nonRepeating)
            .padding(.top, UniSpacing.s)
            .accessibilityHidden(true)
    }

    private var headline: some View {
        VStack(spacing: UniSpacing.xs) {
            Text("This address imitates a saved one")
                .font(UniTypography.title2)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.center)
            Text("It starts and ends like \(match.savedName)'s saved address but the middle is different. This is how scammers trick you into sending to the wrong place.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Compare card

    private enum CompareHeader { case saved, pasted }

    @ViewBuilder
    private func compareCard(title: String, header: CompareHeader, address: String, differingAgainst other: String) -> some View {
        SendGlassCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                HStack(spacing: UniSpacing.xs) {
                    Image(systemName: header == .saved ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(header == .saved ? UniColors.Send.positive : UniColors.Send.negative)
                    Text(verbatim: title)
                        .font(UniTypography.caption1.weight(.bold))
                        .foregroundStyle(header == .saved ? UniColors.Send.positive : UniColors.Send.negative)
                    Spacer(minLength: 0)
                }
                Text(comparedAddress(address, against: other, highlightDiffer: header == .pasted))
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
                    .accessibilityLabel(Text(verbatim: address))
            }
        }
    }

    /// Builds the address with the matching prefix/suffix in bold ink and
    /// the middle either dimmed (saved card) or highlighted red (pasted
    /// card), per the handoff.
    private func comparedAddress(_ address: String, against other: String, highlightDiffer: Bool) -> AttributedString {
        let prefixLen = commonPrefix(address, other)
        let suffixLen = commonSuffix(address, other, excluding: prefixLen)
        let chars = Array(address)
        var result = AttributedString()

        func appendRange(_ range: Range<Int>, bold: Bool, dimmed: Bool, highlight: Bool) {
            guard !range.isEmpty else { return }
            var piece = AttributedString(String(chars[range]))
            piece.font = .system(size: 15, weight: bold ? .bold : .regular, design: .monospaced)
            piece.foregroundColor = dimmed ? UniColors.Text.tertiary
                : (highlight ? UniColors.Send.negative : UniColors.Text.primary)
            if highlight {
                piece.backgroundColor = UniColors.Send.negative.opacity(0.16)
            }
            result.append(piece)
        }

        let endStart = max(prefixLen, chars.count - suffixLen)
        appendRange(0..<min(prefixLen, chars.count), bold: true, dimmed: false, highlight: false)
        appendRange(min(prefixLen, chars.count)..<endStart, bold: false, dimmed: !highlightDiffer, highlight: highlightDiffer)
        appendRange(endStart..<chars.count, bold: true, dimmed: false, highlight: false)
        return result
    }

    private func commonPrefix(_ a: String, _ b: String) -> Int {
        let aa = Array(a), bb = Array(b)
        var i = 0
        while i < aa.count && i < bb.count && aa[i].lowercased() == bb[i].lowercased() { i += 1 }
        return i
    }

    private func commonSuffix(_ a: String, _ b: String, excluding prefix: Int) -> Int {
        let aa = Array(a), bb = Array(b)
        var i = 0
        while i < aa.count - prefix && i < bb.count - prefix
            && aa[aa.count - 1 - i].lowercased() == bb[bb.count - 1 - i].lowercased() { i += 1 }
        return i
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: UniSpacing.s) {
            UniButton(title: "Use \(match.savedName)'s saved address", variant: .primary, action: onUseSaved)

            Button {
                if continueArmed {
                    onContinueAnyway()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { continueArmed = true }
                }
            } label: {
                Text(continueArmed ? "Tap again to confirm — send to the pasted address" : "Continue with pasted address")
                    .font(UniTypography.buttonLabel)
                    .foregroundStyle(UniColors.Send.negative)
                    .frame(maxWidth: .infinity)
                    .frame(height: 47)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // `.impactMedium` on the confirming (second) tap (handoff).
            .uniHaptic(.contextualImpact(.commit), trigger: continueArmed)
            .accessibilityHint(Text("Requires two taps to confirm"))
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.s)
        .padding(.bottom, UniSpacing.xs)
    }
}
