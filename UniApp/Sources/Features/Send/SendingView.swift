import SwiftUI

/// **Send · Screens 5 & 6 — Sending / Sent / Failed (the dark terminal
/// surfaces).**
///
/// Per the handoff these go full-bleed dark (`UniColors.Send.darkScreen*`,
/// brand-fixed regardless of appearance) to make the commit feel like a
/// held breath. Three terminal states share one dark scaffold:
///
/// - **Sending** — the spinning Aperture iris + "Broadcasting to
///   \<network\>".
/// - **Sent** — a green check hero, "1.5 ETH sent", a confirming-on-chain
///   note, and Done / View on explorer.
/// - **Failed** — a red cross hero, an honest failure line, and Try again
///   / Done. (Per the handoff: "failures never show the success state.")
///
/// **Rule #16.** The Sent screen restates the recipient and anchors to
/// the on-device, no-server truth ("confirming on-chain — we'll notify
/// you"). The Failed screen is honest and never implies the funds left.
///
/// **Haptics.** `.success` on the Sent appearance, `.error` on Failed —
/// fired via `.uniHaptic` keyed to the screen's appearance.
struct SendingDarkScaffold<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // Brand-fixed dark radial-lift surface (handoff
            // `#0E1015 → #08090C` with a soft top lift).
            RadialGradient(
                colors: [UniColors.Send.darkScreenLift, UniColors.Send.darkScreenTop],
                center: UnitPoint(x: 0.5, y: -0.04),
                startRadius: 0,
                endRadius: 520
            )
            .overlay(
                LinearGradient(
                    colors: [UniColors.Send.darkScreenTop, UniColors.Send.darkScreenBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(0.6)
            )
            .ignoresSafeArea()

            content()
                .padding(.horizontal, UniSpacing.l)
        }
        // Force the dark surface to read with light status-bar content.
        .preferredColorScheme(.dark)
    }
}

// MARK: - Sending

/// The in-flight broadcast surface. `// TODO: (T-066)` the real broadcast
/// drives the transition to Sent/Failed; for the design the parent flow
/// advances on a timer.
struct SendingView: View {
    let networkName: String

    @State private var spin: Double = 0

    var body: some View {
        SendingDarkScaffold {
            VStack(spacing: UniSpacing.l) {
                ApertureIrisView(ringColor: UniColors.Send.onDark)
                    .frame(width: 78, height: 78)
                    .rotationEffect(.degrees(spin))
                    .onAppear {
                        withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                            spin = 360
                        }
                    }
                    .accessibilityHidden(true)

                VStack(spacing: UniSpacing.xs) {
                    Text("Sending…")
                        .font(UniTypography.title2)
                        .foregroundStyle(UniColors.Send.onDark)
                    Text(verbatim: broadcastLine)
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Send.onDarkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Sending"))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var broadcastLine: String {
        // English-source, catalog-localized via the LocalizedStringKey
        // path is not available for interpolated runtime values, so the
        // sentence is assembled from a localized template + the network
        // name. For the design, a verbatim assembly is acceptable; the
        // real path threads a `String(localized:)` format.
        "Broadcasting your transaction to \(networkName)."
    }
}

// MARK: - Sent

struct SentView: View {
    let amountText: String          // "1.5 ETH"
    let recipientDisplay: String
    let onDone: () -> Void
    let onViewExplorer: () -> Void

    var body: some View {
        SendingDarkScaffold {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                heroCheck
                    .padding(.bottom, UniSpacing.l)
                Text(verbatim: "\(amountText) sent")
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(UniColors.Send.onDark)
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(.bottom, UniSpacing.xs)
                Text(verbatim: confirmingLine)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Send.onDarkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                footer
            }
        }
        // `.success` on appear (Rule #10).
        .uniHaptic(.success, trigger: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(amountText) sent"))
    }

    private var heroCheck: some View {
        Circle()
            .fill(UniColors.Send.positive)
            .frame(width: 92, height: 92)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(UniColors.Send.onAccentDisc)
            }
            .shadow(color: UniColors.Send.positive.opacity(0.55), radius: 28, y: 12)
            .symbolEffect(.bounce, options: .nonRepeating)
            .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(spacing: UniSpacing.s) {
            UniButton(title: "Done", variant: .primary, action: onDone)
            Button(action: onViewExplorer) {
                Text("View on explorer")
                    .font(UniTypography.buttonLabel)
                    .foregroundStyle(UniColors.Send.onDark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 47)
                    .background(
                        Capsule().fill(UniColors.Send.onDark.opacity(0.12))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("View on explorer"))
        }
        .padding(.bottom, UniSpacing.m)
    }

    private var confirmingLine: String {
        "To \(recipientDisplay) · confirming on-chain now. We'll notify you when it's final."
    }
}

// MARK: - Failed

struct SendFailedView: View {
    let onRetry: () -> Void
    let onDone: () -> Void

    var body: some View {
        SendingDarkScaffold {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                heroCross
                    .padding(.bottom, UniSpacing.l)
                Text("Send didn't go through")
                    .font(UniTypography.title2)
                    .foregroundStyle(UniColors.Send.onDark)
                    .padding(.bottom, UniSpacing.xs)
                Text("Nothing left your wallet. You can try again — your funds are safe.")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Send.onDarkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                footer
            }
        }
        // `.error` on appear (Rule #10; frustration-silenced by the engine).
        .uniHaptic(.error, trigger: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Send failed"))
    }

    private var heroCross: some View {
        Circle()
            .fill(UniColors.Send.negative)
            .frame(width: 92, height: 92)
            .overlay {
                Image(systemName: "xmark")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(UniColors.Send.onAccentDisc)
            }
            .shadow(color: UniColors.Send.negative.opacity(0.5), radius: 26, y: 12)
            .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(spacing: UniSpacing.s) {
            UniButton(title: "Try again", variant: .primary, action: onRetry)
            Button(action: onDone) {
                Text("Done")
                    .font(UniTypography.buttonLabel)
                    .foregroundStyle(UniColors.Send.onDark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 47)
                    .background(Capsule().fill(UniColors.Send.onDark.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, UniSpacing.m)
    }
}
