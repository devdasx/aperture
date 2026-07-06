import SwiftUI

/// **Address-poisoning interstitial** (`design_handoff_send_v2` Flow A3).
///
/// A full-attention moment — NOT a sheet — shown when a freshly pasted or
/// scanned address imitates an address the wallet already knows (matching
/// first + last characters, differing middle). The user cannot proceed to
/// the pasted address silently: the default, prominent action is to use the
/// SAVED address; choosing the pasted one is a deliberate, separately-tinted
/// second choice.
///
/// Two monospace compare cards make the deception legible — the matching
/// ends are bold ink, and the **differing middle** is highlighted (dimmed on
/// the saved card, washed red on the pasted card) so the eye lands exactly
/// where the two addresses diverge.
struct SendPoisoningGuardView: View {
    let lookalike: SendSafety.Lookalike
    /// A human label for the known address (contact / recent name) when we
    /// have one; the buttons and headers adapt to "the saved address" when
    /// nil.
    let knownName: String?
    let chain: SupportedChain
    let onUseSaved: () -> Void
    let onContinuePasted: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var savedLabel: String { knownName ?? String.apertureLocalized("the saved address") }

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()
            // The danger bloom at the top — a red wash that says "stop"
            // without flooding the whole screen.
            VStack {
                if !reduceTransparency {
                    RadialGradient(
                        colors: [UniColors.Send.bloomDanger, .clear],
                        center: .top, startRadius: 0, endRadius: 360
                    )
                    .frame(height: 360)
                    .ignoresSafeArea()
                }
                Spacer()
            }

            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    hero
                    compareCards
                    actions
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.xl)
                .padding(.bottom, UniSpacing.xl)
            }
            .scrollIndicators(.hidden)

            // A quiet way out that fills neither address — backing out is
            // honest (the user may want to abandon the paste entirely).
            VStack {
                HStack {
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(UniColors.Text.secondary)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close"))
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.xs)
                Spacer()
            }
        }
        .uniHaptic(.warning, trigger: 1)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Send.negative)
                .frame(width: 72, height: 72)
                .background(UniColors.Send.negativeWash, in: Circle())

            Text("This address imitates a saved one")
                .font(UniTypography.title2)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.center)

            Text("Someone may have created a near-identical address to trick you. The start and end match, but the middle is different. Sending here would send to a stranger — and it can't be reversed.")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Compare cards

    private var compareCards: some View {
        VStack(spacing: UniSpacing.s) {
            compareCard(
                header: savedHeader,
                headerColor: UniColors.Send.positive,
                address: lookalike.knownAddress,
                isPasted: false
            )
            compareCard(
                header: String.apertureLocalized("Pasted just now"),
                headerColor: UniColors.Send.negative,
                address: lookalike.pastedAddress,
                isPasted: true
            )
        }
    }

    /// The saved card's header — "Saved · {name}" when we have a contact /
    /// recent label, else a plain "Your saved address". The "·" separator is
    /// punctuation, not localizable copy, so only the words are catalog keys.
    private var savedHeader: String {
        if let knownName { return "\(String.apertureLocalized("Saved")) · \(knownName)" }
        return String.apertureLocalized("Your saved address")
    }

    private func compareCard(
        header: String,
        headerColor: Color,
        address: String,
        isPasted: Bool
    ) -> some View {
        SendGlassCard(cornerRadius: UniRadius.l, padding: UniSpacing.m) {
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                HStack(spacing: UniSpacing.xxs) {
                    Image(systemName: isPasted ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(headerColor)
                    Text(verbatim: header)
                        .font(UniTypography.caption1.weight(.semibold))
                        .foregroundStyle(headerColor)
                        .textCase(.uppercase)
                }
                Text(highlightedAddress(address, isPasted: isPasted))
                    .environment(\.layoutDirection, .leftToRight)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Render the address with its matching ends bold-ink and its differing
    /// middle highlighted. AttributedString concatenation wraps naturally
    /// and supports a per-run background, so the red "middle" pill on the
    /// pasted card and the dimmed middle on the saved card both read.
    private func highlightedAddress(_ address: String, isPasted: Bool) -> AttributedString {
        let chars = Array(address)
        let prefixLen = min(lookalike.sharedPrefix, chars.count)
        let suffixLen = min(lookalike.sharedSuffix, max(0, chars.count - prefixLen))
        let prefix = String(chars[0..<prefixLen])
        let suffix = suffixLen > 0 ? String(chars[(chars.count - suffixLen)...]) : ""
        let middle = String(chars[prefixLen..<(chars.count - suffixLen)])

        var result = segment(prefix, weight: .semibold, color: UniColors.Text.primary)
        result += segment(
            middle,
            weight: isPasted ? .semibold : .regular,
            color: isPasted ? UniColors.Send.negative : UniColors.Text.tertiary,
            background: isPasted ? UniColors.Send.bloomDanger : nil
        )
        result += segment(suffix, weight: .semibold, color: UniColors.Text.primary)
        return result
    }

    private func segment(
        _ text: String,
        weight: Font.Weight,
        color: Color,
        background: Color? = nil
    ) -> AttributedString {
        var attr = AttributedString(text)
        attr.font = .system(size: 13, weight: weight, design: .monospaced)
        attr.foregroundColor = color
        if let background { attr.backgroundColor = background }
        return attr
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: UniSpacing.xs) {
            SendV2PrimaryButton(
                knownName != nil
                    ? "Use \(savedLabel)'s saved address"
                    : "Use the saved address",
                systemImage: "checkmark.shield.fill",
                action: onUseSaved
            )
            SendV2GhostButton("Continue with the pasted address", isDanger: true, action: onContinuePasted)
        }
        .padding(.top, UniSpacing.xs)
    }
}
