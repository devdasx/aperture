import SwiftUI

/// Settings → About → Acknowledgments. Surfaces the per-asset
/// provenance ledger from `Assets.xcassets/README.md` — every bundled
/// visual asset's source URL and license. Per Rule #7 §D, every
/// shipped pixel has auditable provenance; this is where the user
/// reads it without leaving the app.
///
/// Also lists the spec sources behind the cryptographic code (BIP-39
/// wordlist + spec, PBKDF2 spec, system frameworks) so a reader who
/// wants to audit the implementation knows exactly which spec each
/// piece implements.
struct AcknowledgmentsView: View {
    var body: some View {
        List {
            Section {
                acknowledgmentRow(
                    title: "SF Symbols",
                    detail: "Apple's official symbol library — all UI iconography.",
                    license: "Apple Symbols License"
                )
                acknowledgmentRow(
                    title: "Trust Wallet Assets",
                    detail: "Token and chain logos via github.com/trustwallet/assets.",
                    license: "MIT"
                )
            } header: {
                Text("Visual assets").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            } footer: {
                Text("Per-asset URLs and licenses live in the project at Assets.xcassets/README.md — every shipped image has audit provenance recorded there.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                acknowledgmentRow(
                    title: "BIP-39 Wordlist",
                    detail: "The canonical 2048-word English wordlist from bitcoin/bips. Verified SHA-256 in source.",
                    license: "BSD-2 (Bitcoin)"
                )
                acknowledgmentRow(
                    title: "BIP-39 Spec",
                    detail: "Mnemonic + seed derivation per BIP-39. Implemented in BIP39.swift / BIP39Seed.swift using only CryptoKit and Security framework.",
                    license: "BSD-2"
                )
            } header: {
                Text("Cryptography").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            } footer: {
                Text("Aperture ships zero third-party Swift packages. Every cryptographic primitive is an Apple-shipped framework (CryptoKit, Security, LocalAuthentication).")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Link(destination: URL(string: "https://github.com/devdasx/aperture")!) {
                    HStack {
                        Text("Source code")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(UniColors.Icon.tertiary)
                    }
                    .padding(.vertical, UniSpacing.xxs)
                }
                .listRowBackground(UniColors.Background.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Acknowledgments"))
        .navigationBarTitleDisplayMode(.large)
    }

    private func acknowledgmentRow(title: LocalizedStringKey, detail: LocalizedStringKey, license: String) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            HStack {
                Text(title)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                Text(verbatim: license)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .padding(.horizontal, UniSpacing.xs)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(UniColors.Fill.secondary))
            }
            Text(detail)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, UniSpacing.xs)
        .listRowBackground(UniColors.Background.secondary)
    }
}

// MARK: - Terms / Privacy placeholder sheets

struct TermsPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        UniSheet(title: "Terms of Service") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                Image(systemName: "doc.text")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)
                UniBody(
                    text: "The Terms of Service haven't been written yet. Aperture is open source — the only thing governing your use of the app today is the MIT license in the repository.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                UniBody(
                    text: "When written, the Terms will state plainly: Aperture provides software, not custody. You are responsible for your keys.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) { dismiss() }
        }
    }
}

struct PrivacyPolicyPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        UniSheet(title: "Privacy Policy") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)
                UniBody(
                    text: "Aperture's privacy policy is short because Aperture collects no data: no account, no email, no analytics, no telemetry, no server-side logs of your wallet activity.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                UniBody(
                    text: "Network traffic from this app goes only to public chain RPC providers (for balances and history) and to Coinbase's public price endpoint (for fiat display). Those providers may log the requests on their side — Aperture itself records nothing.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) { dismiss() }
        }
    }
}
