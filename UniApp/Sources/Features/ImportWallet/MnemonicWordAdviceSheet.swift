import SwiftUI

/// Presented when the user taps a red (invalid) word in the mnemonic
/// editor. Names plainly that BIP-39 uses a fixed 2048-word list,
/// shows up to 3 closest matches by Levenshtein edit distance, and
/// lets the user tap a candidate to replace the invalid word in one
/// gesture.
///
/// **Per Rule #15** — built on the canonical `UniSheet` shell;
/// `.intrinsicHeightSheet()` at the call site sizes to content.
/// **Per Rule #16** — honest about what BIP-39 is (a fixed list, not
/// a guess engine); the user picks the replacement, Aperture does not
/// auto-substitute.
struct MnemonicWordAdviceSheet: View {
    /// The typed word that's not in the wordlist.
    let typedWord: String

    /// Fires with a chosen replacement word. The caller swaps it into
    /// the editor at the original word's position.
    let onPickSuggestion: (String) -> Void

    /// Fires when the user taps "Keep editing". The caller dismisses
    /// the sheet without changing the word.
    let onKeepEditing: () -> Void

    private var suggestions: [(word: String, distance: Int)] {
        typedWord.bip39Suggestions(topK: 3)
    }

    var body: some View {
        UniSheet(title: LocalizedStringKey("\(typedWord) isn't a recovery word")) {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                UniBody(
                    text: "BIP-39 recovery phrases use a fixed list of 2048 English words. Aperture didn't find this one — it may be a typo. Here are the closest matches.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)

                if suggestions.isEmpty {
                    emptyState
                } else {
                    suggestionList
                }
            }
        } actions: {
            UniButton(title: "Keep editing", variant: .secondary) {
                onKeepEditing()
            }
        }
    }

    // MARK: - Suggestions

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    onPickSuggestion(suggestion.word)
                } label: {
                    suggestionRow(suggestion)
                }
                .buttonStyle(.plain)
                if index < suggestions.count - 1 {
                    UniDivider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }

    private func suggestionRow(_ suggestion: (word: String, distance: Int)) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(verbatim: suggestion.word)
                .font(UniTypography.body.weight(.semibold).monospaced())
                .foregroundStyle(UniColors.Text.primary)

            Spacer()

            Text(distanceLabel(suggestion.distance))
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)

            Image(systemName: "arrow.up.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
        .contentShape(Rectangle())
    }

    private func distanceLabel(_ distance: Int) -> LocalizedStringKey {
        distance == 1
            ? LocalizedStringKey("\(distance) letter different")
            : LocalizedStringKey("\(distance) letters different")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniHeadline(text: "No close matches found", alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "Check the original phrase you wrote down — this word may be from a different wordlist.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }
}
