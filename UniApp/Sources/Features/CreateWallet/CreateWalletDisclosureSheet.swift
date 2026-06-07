import SwiftUI

/// Risk disclosure presented as the first beat of the "Create new wallet"
/// flow (`T-002`). Before the user sees a single word of their recovery
/// phrase, we frame what they are about to take responsibility for.
///
/// **Intent (one sentence):** prepare the user for self-custody honestly,
/// so the moment they see their words they understand the weight of the
/// gesture.
///
/// **Sheet shape (Rule #15).** A `NavigationStack` wraps the content;
/// the title lives in `.navigationTitle("Your recovery phrase is the
/// only way back.")` with `.navigationBarTitleDisplayMode(.large)` so
/// the title compresses into the nav bar on scroll. The thesis IS the
/// title — the framing "Before you continue" was removed 2026-06-04
/// because it added a beat the user had to read before reaching the
/// substance, and the substance is short enough to carry the screen
/// itself. The body paragraph (kept) names the consequence honestly
/// directly below the hero mark.
///
/// **Layout.** Large detent only — the four protection rules need vertical
/// room; medium is too tight and would force scrolling, which dilutes the
/// gravity of the message. A `lock.shield` hero in `UniColors.Brand.mark`
/// sits above the headline (Ive restraint — a single quiet mark instead
/// of a red alarm triangle, because the message is responsibility, not
/// danger).
///
/// **The ack toggle.** Per `CLAUDE.md` Rule #2 §A.7, we respect the user's
/// intelligence — we do not show an "Are you sure?" modal for reversible
/// actions. But creating a wallet is genuinely irreversible: if the user
/// loses their phrase, the funds are gone. The smallest affordance that
/// captures "I read this" is a single toggle. The primary CTA is disabled
/// until the toggle is on. This is the minimum honest gate, not a
/// gratuitous one.
struct CreateWalletDisclosureSheet: View {
    /// Fires after the user has acknowledged the risks and tapped the
    /// primary CTA. The caller is responsible for dismissing this sheet
    /// and presenting the recovery-phrase flow.
    let onAccept: () -> Void
    /// Fires when the user taps Cancel. The caller dismisses the sheet.
    let onCancel: () -> Void

    @State private var didAcknowledge: Bool = false

    var body: some View {
        UniSheet(title: "Your recovery phrase") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                protectionRules
                acknowledgementRow
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(
                        title: "Show recovery phrase",
                        variant: .primary,
                        isEnabled: didAcknowledge
                    ) {
                        onAccept()
                    }
                    UniButton(title: "Cancel", variant: .secondary) {
                        onCancel()
                    }
                }
            }
        }
    }

    // MARK: - Protection rules

    /// Four rules sit inside one `UniCard`. Concentric radius: card uses
    /// `UniRadius.xl` (24) with `UniSpacing.m` (16) inner padding, so any
    /// hypothetical inner shape would be `nested(parent: 24, padding: 16)`
    /// = 8 — but the rows here are flat rows, not nested surfaces, so
    /// no further radii are needed.
    private var protectionRules: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                UniFeatureRow(
                    systemImage: "pencil.line",
                    title: "Write it down.",
                    detail: "On paper. Not a screenshot. Not a note app."
                )
                UniDivider()
                UniFeatureRow(
                    systemImage: "wifi.slash",
                    title: "Keep it offline.",
                    detail: "Anything connected to the internet can be reached."
                )
                UniDivider()
                UniFeatureRow(
                    systemImage: "person.2.slash",
                    title: "Never share it.",
                    detail: "Aperture, Apple, your bank — no one needs your recovery phrase. Ever."
                )
                UniDivider()
                UniFeatureRow(
                    systemImage: "xmark.octagon",
                    title: "If you lose it, the funds are gone.",
                    detail: "There is no support team, no password reset, no recovery."
                )
            }
        }
    }

    // MARK: - Acknowledgement toggle

    /// The single ack the user must make before continuing. Toggle copy
    /// is verbatim from `TODO.md` T-002 §A.1 — the honesty check explicitly
    /// requires this wording, not a softened paraphrase.
    private var acknowledgementRow: some View {
        Toggle(isOn: $didAcknowledge) {
            Text("I understand if I lose my recovery phrase, I lose my crypto.")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(UniColors.Button.primaryTint)
        .uniHaptic(.selection, trigger: didAcknowledge)
        .padding(.vertical, UniSpacing.xxs)
    }

}

// MARK: - Previews

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CreateWalletDisclosureSheet(onAccept: {}, onCancel: {})
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CreateWalletDisclosureSheet(onAccept: {}, onCancel: {})
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}
