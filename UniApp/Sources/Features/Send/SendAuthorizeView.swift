import SwiftUI

/// **Send · Screen 4 — Authorize (Face ID / passcode).**
///
/// A confirm surface with the Face ID glyph, the "Sending X to Y" line,
/// and a compact summary (Amount / Network fee / Total). The primary CTA
/// runs the biometric prompt. For the design the auth result is MOCKED —
/// tapping "Confirm with Face ID" advances to Sending. `// TODO: (T-064)`
/// wires the real `BiometricService` + PIN fallback.
///
/// **Rule #16 (security surface).** This is a custody moment — it carries
/// the protection mechanism (Face ID / passcode), the user's role (you
/// authorize), and an honest limit (the amount is restated so the user
/// confirms the exact figure leaving). Restrained monochrome; no alarming
/// red.
///
/// **Rule #17.** Biometrics go through `BiometricService` (not raw
/// `LAContext`) when wired; the design references the same visual surface.
struct SendAuthorizeView: View {
    @Bindable var draft: SendDraft
    let onAuthorized: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.m) {
                    faceIDHero
                        .padding(.top, UniSpacing.l)
                    headline
                    summaryCard
                        .padding(.top, UniSpacing.s)
                }
                .padding(.horizontal, UniSpacing.m)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: onCancel)
            }
        }
    }

    // MARK: - Hero

    private var faceIDHero: some View {
        RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
            .fill(UniColors.Brand.mark)
            .frame(width: 72, height: 72)
            .overlay {
                Image(systemName: "faceid")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(UniColors.Icon.onTint)
            }
            .symbolEffect(.bounce, options: .nonRepeating)
            .accessibilityHidden(true)
    }

    private var headline: some View {
        VStack(spacing: UniSpacing.xs) {
            UniTitle2(text: "Confirm with Face ID", alignment: .center)
            Text(verbatim: confirmSubtitle)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(spacing: 0) {
            summaryRow(key: "Amount", value: "\(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)")
            UniDivider()
            summaryRow(key: "Network fee", value: "≈ \(WalletFormatting.fiat(draft.networkFeeFiat, currencyCode: activeCurrencyCode))")
            UniDivider()
            summaryRow(key: "Total", value: WalletFormatting.fiat(draft.totalFiat, currencyCode: activeCurrencyCode))
        }
        .padding(.horizontal, UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }

    @ViewBuilder
    private func summaryRow(key: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(UniTypography.subheadlineEmphasized)
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, UniSpacing.s)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            // `// TODO: (T-064)` — replace the immediate advance with a
            // real `BiometricService.authenticate(...)` call + PIN
            // fallback. For the design, this advances to Sending.
            UniButton(
                title: "Confirm with Face ID",
                variant: .primary,
                systemImage: "faceid",
                action: onAuthorized
            )
            .padding(.horizontal, UniSpacing.m)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
        .background(UniColors.Background.primary)
    }

    // MARK: - Derived

    private var confirmSubtitle: String {
        "Sending \(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker) to \(draft.recipientDisplay)"
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey)
            ?? CurrencyPreference.defaultCode
    }
}
