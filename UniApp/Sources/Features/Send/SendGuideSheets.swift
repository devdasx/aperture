import SwiftUI

/// Rule #18 guide sheets for the Send flow — calm, restrained answers to
/// the questions a first-timer actually asks at the moment they meet the
/// unfamiliar thing. Each follows the canonical shape: a question title,
/// a hero SF Symbol, a four-question body (what it is / what it looks
/// like / how you use it / what Aperture does), and a single
/// `UniButton(.primary)` "Got it".
///
/// Three sheets ship here:
/// - **Network fee** — every send shows a fee; first-timers ask what it is.
/// - **RBF** — Bitcoin-only; "Replace-By-Fee" is jargon.
/// - **UTXO** — Bitcoin-only; coin control surfaces the UTXO model.

// MARK: - Recipient address

struct SendRecipientGuideSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "Who can I send to?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero(symbol: "person.crop.circle.badge.checkmark")
                UniBody(
                    text: "A recipient is an address on a blockchain — a long string that identifies one account. You can paste it, scan its QR code, or type a name that resolves to one (like an ENS name).",
                    color: UniColors.Text.primary
                )
                UniBody(
                    text: "Double-check the address before you send. Blockchain transactions are final — there is no \u{201C}undo\u{201D} and no support line that can reverse a send to the wrong address.",
                    color: UniColors.Text.secondary
                )
                apertureRole
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary, action: onDismiss)
        }
    }
}

// MARK: - Network fee

struct SendNetworkFeeGuideSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "What's a network fee?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero(symbol: "fuelpump.fill")
                UniBody(
                    text: "A network fee is what you pay the blockchain — not Aperture — to process your transaction. It goes to the people running the network, never to us.",
                    color: UniColors.Text.primary
                )
                UniBody(
                    text: "Higher fees confirm faster; lower fees cost less but wait longer. Aperture picks a sensible default, and you can change it under \u{201C}Edit\u{201D} on the review screen.",
                    color: UniColors.Text.secondary
                )
                apertureRole
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary, action: onDismiss)
        }
    }
}

// MARK: - RBF

struct SendRBFGuideSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "What's Replace-By-Fee?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero(symbol: "arrow.triangle.2.circlepath")
                UniBody(
                    text: "Replace-By-Fee (RBF) is a Bitcoin feature that lets you raise the fee on a transaction after you've sent it — useful when the network is busy and your transaction is stuck waiting.",
                    color: UniColors.Text.primary
                )
                UniBody(
                    text: "With RBF on, a pending transaction can be bumped with a higher fee so it confirms sooner. It does not let anyone change where the funds go — only the fee.",
                    color: UniColors.Text.secondary
                )
                apertureRole
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary, action: onDismiss)
        }
    }
}

// MARK: - UTXO

struct SendUTXOGuideSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "What's a UTXO?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero(symbol: "square.stack.3d.up.fill")
                UniBody(
                    text: "Bitcoin doesn't store a single balance. Instead your wallet holds a set of unspent pieces of Bitcoin called UTXOs \u{2014} \u{201C}Unspent Transaction Outputs.\u{201D} Each one is a chunk you received at some point.",
                    color: UniColors.Text.primary
                )
                exampleBlock
                UniBody(
                    text: "Coin control lets you pick which UTXOs to spend. Most people never need to \u{2014} Aperture chooses for you. Power users pick specific inputs for privacy or fee reasons.",
                    color: UniColors.Text.secondary
                )
                apertureRole
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary, action: onDismiss)
        }
    }

    private var exampleBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniCaption(text: "Example only.", color: UniColors.Text.tertiary)
            Text(verbatim: "e3b0…c442 : 0  →  0.250 BTC")
                .font(UniTypography.subheadline.monospaced())
                .foregroundStyle(UniColors.Text.secondary)
                .environment(\.layoutDirection, .leftToRight)
                .padding(UniSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
        }
    }
}

// MARK: - Shared pieces

@MainActor
private func hero(symbol: String) -> some View {
    HStack {
        Spacer()
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Brand.mark)
            .symbolEffect(.bounce, options: .nonRepeating)
            .accessibilityHidden(true)
        Spacer()
    }
}

private var apertureRole: some View {
    UniBody(
        text: "Aperture builds and signs this on your iPhone. Nothing is uploaded — the fee goes to the network, not to us.",
        color: UniColors.Text.secondary
    )
}
