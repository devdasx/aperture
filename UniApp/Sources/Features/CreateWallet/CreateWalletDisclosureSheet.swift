import SwiftUI

/// Risk disclosure used as the first beat of the "Create new wallet" flow
/// (`T-002`). Before the user sees a single word of their recovery phrase, we
/// frame what they are about to take responsibility for.
///
/// **Intent (one sentence):** prepare the user for self-custody honestly,
/// so the moment they see their words they understand the weight of the
/// gesture.
///
/// `CreateWalletDisclosureScreen` is used from onboarding so tapping "Create
/// new wallet" pushes a real screen. This sheet variant remains available for
/// contexts that deliberately need sheet presentation.
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
            CreateWalletDisclosureContent(didAcknowledge: $didAcknowledge)
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
}

struct CreateWalletDisclosureScreen: View {
    let onAccept: () -> Void
    let onCancel: () -> Void

    @State private var didAcknowledge: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                CreateWalletDisclosureContent(didAcknowledge: $didAcknowledge)
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.s)
                    .padding(.bottom, UniSpacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

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
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.l)
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Your recovery phrase")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct CreateWalletDisclosureContent: View {
    @Binding var didAcknowledge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.l) {
            protectionRules
            acknowledgementRow
        }
    }

    // MARK: - Protection rules

    /// Four rules sit inside one `UniCard`. Concentric radius is now
    /// system-driven: the card declares its surface radius via
    /// `.containerShape(.rect(cornerRadius: UniRadius.card))` (18 pt)
    /// in `UniCard`'s body, so any descendant `ConcentricRectangle()`
    /// would auto-resolve. The rows here are flat rows, not nested
    /// surfaces, so no inner shape is needed.
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
    ///
    /// **Horizontal indent.** The `UniCard` above this row has
    /// `UniSpacing.m` (16pt) internal padding, so its content sits at
    /// `sheetPadding + cardPadding` = 32pt from each sheet edge. The
    /// toggle row is outside the card, so without compensating padding
    /// it would sit at just `sheetPadding` (16pt) — visually 16pt
    /// further left and right than the card content above it, breaking
    /// the vertical rhythm and pushing the `Toggle`'s switch pill so
    /// close to the sheet's right edge that on small iPhones it reads
    /// as clipped. The explicit `.padding(.horizontal, UniSpacing.m)`
    /// here adopts the card's internal indent for this row so the
    /// label aligns under "Write it down." and the switch's right
    /// pill ends at the same X as the card's right edge.
    private var acknowledgementRow: some View {
        UniToggle(isOn: $didAcknowledge) {
            Text("I understand if I lose my recovery phrase, I lose my crypto.")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(UniColors.Button.primaryTint)
        .uniHaptic(.selection, trigger: didAcknowledge)
        .padding(.vertical, UniSpacing.xxs)
        .padding(.horizontal, UniSpacing.m)
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
