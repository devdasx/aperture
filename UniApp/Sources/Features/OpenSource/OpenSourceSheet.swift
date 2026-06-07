import SwiftUI

/// The open-source verification anchor — a reusable sheet that explains
/// what the user can audit in Aperture's source code and links to the
/// public GitHub repository.
///
/// **Intent (one sentence):** let the user verify, with one tap, that
/// Aperture's safety claims are not marketing — they are code they can
/// read.
///
/// **Rule #16 anchor.** Per `CLAUDE.md` Rule #16 §C, this sheet is the
/// shared anchor for the open-source link. It is presented from the
/// first security-touching surface a user sees per session (the welcome
/// slide today; future custody surfaces will reuse the same sheet).
///
/// **Sheet shape (Rule #15).** A `NavigationStack` wraps the content,
/// the title lives in `.navigationTitle("Open source")` with
/// `.navigationBarTitleDisplayMode(.inline)` for the `.large` detent —
/// the body is short enough that a `.large` title would compete with
/// the hero mark for vertical weight. A leading `lock.shield.fill`
/// glyph in `UniColors.Brand.mark` sits above the headline; below it,
/// a `UniCard` carries three plainly-named verification rows; at the
/// bottom, a primary `UniButton` opens the repository in Safari via
/// SwiftUI's native `openURL` environment action — no UIKit, no in-app
/// browser. A trailing `Done` toolbar item dismisses the sheet.
///
/// **Material.** Opaque white in light mode via
/// `.presentationBackground(UniColors.Background.primary)` at the call
/// site. iOS 26 owns the outer corner radius, drag indicator, and dim
/// layer; the sheet's chrome is system Liquid Glass and we don't
/// approximate it ourselves (Rule #3).
struct OpenSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The canonical repository URL. Force-unwrapped because the string
    /// is a compile-time constant — if this ever fails to parse, that's
    /// a bug worth crashing on at launch.
    private let repositoryURL: URL = URL(string: "https://github.com/devdasx/aperture")!

    var body: some View {
        UniSheet(title: "Open source") {
            VStack(spacing: UniSpacing.l) {
                hero
                copyBlock
                verifyCard
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                UniButton(
                    title: "View on GitHub",
                    variant: .primary,
                    systemImage: "arrow.up.right.square"
                ) {
                    openURL(repositoryURL)
                }
                .accessibilityLabel(Text("View source code on GitHub"))
            }
        }
    }

    // MARK: - Hero

    /// A single quiet mark — `lock.shield.fill` in
    /// `UniColors.Brand.mark` (graphite/soft-white) — sets the safety
    /// tone without alarm. Hierarchical rendering lets the secondary
    /// fill read at lower opacity, which keeps the symbol restrained at
    /// hero size.
    private var hero: some View {
        Image(systemName: "lock.shield.fill")
            .font(.system(size: 64, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Brand.mark)
            .accessibilityHidden(true)
    }

    // MARK: - Copy block

    private var copyBlock: some View {
        VStack(spacing: UniSpacing.m) {
            UniLargeTitle(
                text: "Aperture is open source.",
                alignment: .center
            )
            UniBody(
                text: "Every line of code is in this repository. Read it. Audit it. Verify what your wallet actually does — including how your keys are generated, how your seed is derived, and how Aperture has no way to see your funds.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
    }

    // MARK: - Verification list

    /// Three "what you can verify" rows inside a single `UniCard`. The
    /// rows are flat (not nested surfaces) so no concentric-radius math
    /// is needed beyond the card's own `UniRadius.card` (18 pt). The
    /// SF Symbols
    /// (`key.fill`, `lock.iphone`, `eye.slash.fill`) each correspond to
    /// a real protection mechanism in the codebase — per Rule #16 §E,
    /// no decorative shields without a verifiable mechanism behind
    /// them.
    private var verifyCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                verifyRow(
                    systemImage: "key.fill",
                    title: "Key generation",
                    detail: "BIP-39 entropy and checksum, in Swift, using Apple's CryptoKit."
                )
                UniDivider()
                verifyRow(
                    systemImage: "lock.iphone",
                    title: "Seed derivation",
                    detail: "PBKDF2-HMAC-SHA512, 2048 iterations — the BIP-39 standard."
                )
                UniDivider()
                verifyRow(
                    systemImage: "eye.slash.fill",
                    title: "Nothing leaves your phone",
                    detail: "No accounts. No servers. No analytics on your balances."
                )
            }
        }
    }

    @ViewBuilder
    private func verifyRow(
        systemImage: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniBody(text: title, emphasized: true)
                UniSubtitle(text: detail)
            }
        }
    }

}

// MARK: - Previews

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            OpenSourceSheet()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            OpenSourceSheet()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.dark)
}
