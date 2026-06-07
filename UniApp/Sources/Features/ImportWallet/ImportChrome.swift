import SwiftUI
import UIKit

/// Shared chrome primitives used by the three Import Wallet entry
/// screens (`MnemonicEntryView`, `PrivateKeyEntryView`,
/// `WatchOnlyEntryView`). Per the jony-ive 2026-06-05 import-entry
/// redesign, these three live in the same visual family: a leading-
/// aligned title + subtitle header in the body, a chain-anchored
/// principal in the nav bar (logo + name), and a dimmed inline
/// example caption below the input.
///
/// All three are pure layout — no business logic, no state.

// MARK: - Header block (title + subtitle)

/// Leading-aligned title + subtitle pair used at the top of every
/// import-entry screen. Mirrors the create-wallet
/// `RecoveryPhraseView` header register.
struct ImportHeaderBlock: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniHeadline(text: title, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            UniSubtitle(text: subtitle, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Chain-anchored nav-bar principal

/// Custom `.principal` toolbar item that renders the chain logo
/// (Trust Wallet bundled, per M-001) next to the chain's display
/// name. Used by PK + Watch-only entry + review screens. Used with
/// `.navigationBarTitleDisplayMode(.inline)` — the system's `.large`
/// title doesn't play with a custom principal.
struct ChainNavTitle: View {
    let chain: SupportedChain

    var body: some View {
        HStack(spacing: UniSpacing.xs) {
            if let assetName = chain.logoAssetName,
               UIImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
            Text(verbatim: chain.displayName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(UniColors.Text.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: chain.displayName))
    }
}

// MARK: - Inline example caption

/// Dimmed, two-line "Example only — …" caption that sits immediately
/// below the input field on every import-entry screen. The leading
/// caption names the example as fake; the body shows the example
/// itself. Per Rule #18 §D the example MUST contain a `…` ellipsis
/// to read as fake (never confuse with a real value).
///
/// `monospaced` flips between proportional San Francisco (for
/// language-style examples like recovery phrases) and monospaced
/// (for data-style examples like addresses or hex keys, where
/// character-level disambiguation matters).
struct ImportExampleCaption: View {
    let caption: LocalizedStringKey
    let example: String
    let monospaced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            UniCaption(text: caption, color: UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: example)
                .font(exampleFont)
                .foregroundStyle(UniColors.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var exampleFont: Font {
        monospaced
            ? UniTypography.subheadline.monospaced()
            : UniTypography.subheadline
    }
}
