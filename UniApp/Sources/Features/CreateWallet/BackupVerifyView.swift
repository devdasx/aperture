import SwiftUI

/// Verify-your-phrase step in the create-wallet flow. Pushed onto the
/// cover's `NavigationStack` when the user taps "Back up now" on
/// `RecoveryPhraseView`.
///
/// **Intent (one sentence):** make sure the user actually wrote down the
/// phrase — without lecturing them, without locking them out on a wrong
/// guess.
///
/// **Design.** Three position cards in a vertical stack. Each card shows
/// the position label ("Word 04") and four word choices in a 2×2 grid —
/// the correct word and three random distractors drawn from the BIP-39
/// wordlist. Selection is local: tapping a button selects it and
/// deselects the others in that card. Correctness is **not** revealed
/// until the user taps "Continue". On all-three-correct the flow
/// advances to `WalletReadyView`; on any wrong selection, the failing
/// card gains a `Status.error` outline and a small "Try again" footnote.
/// The user can change their picks and retry indefinitely — no lockout,
/// no cooldown.
///
/// **Randomness.** Challenge positions and distractors are picked **once
/// on appear**, captured in `@State`. Otherwise every re-render would
/// reshuffle the cards out from under the user.
struct BackupVerifyView: View {
    /// Source mnemonic + word-count from the parent flow state.
    let state: CreateWalletState

    /// Fires when the user passes all three challenges. The caller pushes
    /// `WalletReadyView` onto the cover's `NavigationStack`.
    let onVerified: () -> Void

    /// Three challenge cards generated once on appear. `nil` until appear.
    @State private var challenges: [Challenge] = []

    /// The user's selected word per position, keyed by `positionIndex`.
    @State private var selections: [Int: String] = [:]

    /// Per-position validation outcome: `nil` until the user taps
    /// Continue; `.correct` / `.incorrect` afterwards. The error state is
    /// per-card so the user can fix only the wrong picks.
    @State private var outcomes: [Int: Outcome] = [:]

    /// Trigger counter for the success / error haptics. Bumped inside
    /// `verify()` so the haptic only fires on a user-driven check, not
    /// on every state change.
    @State private var haptic: HapticEvent = .none

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                subtitle
                ForEach(challenges) { challenge in
                    challengeCard(challenge)
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.l)
        }
        .safeAreaInset(edge: .bottom) {
            actionRegion
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
        }
        .navigationTitle(Text("Verify your recovery phrase"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if challenges.isEmpty {
                challenges = Self.makeChallenges(for: state.words)
            }
        }
        .uniHaptic(.success, trigger: haptic == .success ? 1 : 0)
        .uniHaptic(.error, trigger: haptic == .error ? 1 : 0)
        .uniHaptic(.selection, trigger: selections.count)
    }

    // MARK: - Subtitle

    private var subtitle: some View {
        UniBody(
            text: "Pick the word at each position to confirm you saved your phrase.",
            color: UniColors.Text.secondary
        )
    }

    // MARK: - Challenge card

    @ViewBuilder
    private func challengeCard(_ challenge: Challenge) -> some View {
        let outcome = outcomes[challenge.positionIndex]
        let isError = outcome == .incorrect

        VStack(alignment: .leading, spacing: UniSpacing.s) {
            // Position label — Western digits, zero-padded.
            Text(verbatim: positionLabel(for: challenge.positionIndex))
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .monospacedDigit()

            LazyVGrid(columns: choiceColumns, spacing: UniSpacing.s) {
                ForEach(challenge.choices, id: \.self) { word in
                    choiceButton(word: word, positionIndex: challenge.positionIndex)
                }
            }

            if isError {
                UniFootnote(
                    text: "Try again.",
                    color: UniColors.Status.errorForeground
                )
            }
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                .stroke(
                    isError ? UniColors.Status.errorStroke : Color.clear,
                    lineWidth: isError ? 1.5 : 0
                )
        )
    }

    private var choiceColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: UniSpacing.s),
            GridItem(.flexible(), spacing: UniSpacing.s)
        ]
    }

    @ViewBuilder
    private func choiceButton(word: String, positionIndex: Int) -> some View {
        let isSelected = selections[positionIndex] == word

        Button {
            selections[positionIndex] = word
            // Clear the per-card outcome so the error outline disappears
            // as soon as the user touches the card again.
            outcomes[positionIndex] = nil
        } label: {
            Text(verbatim: word)
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(
                    isSelected
                        ? UniColors.Button.primaryLabel
                        : UniColors.Text.primary
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, UniSpacing.s)
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                .fill(
                    isSelected
                        ? UniColors.Button.primaryTint
                        : UniColors.Background.tertiary
                )
        )
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(
                title: "Continue",
                variant: .primary,
                isEnabled: allPositionsSelected
            ) {
                verify()
            }
        }
    }

    private var allPositionsSelected: Bool {
        challenges.allSatisfy { selections[$0.positionIndex] != nil }
    }

    // MARK: - Verify

    /// Compares each card's selection to the correct word. On all
    /// correct, fires `.success` and hands off to the caller. On any
    /// wrong, fires `.error` and lights up the failing cards.
    private func verify() {
        guard !challenges.isEmpty else { return }
        var pass = true
        var newOutcomes: [Int: Outcome] = [:]
        for challenge in challenges {
            let selected = selections[challenge.positionIndex]
            if selected == challenge.correctWord {
                newOutcomes[challenge.positionIndex] = .correct
            } else {
                newOutcomes[challenge.positionIndex] = .incorrect
                pass = false
            }
        }
        outcomes = newOutcomes
        haptic = pass ? .success : .error
        if pass {
            // Honest consumption of the passphrase: derive the real
            // 64-byte BIP-39 seed from mnemonic + passphrase now, while
            // the user is still standing in the create-wallet flow. The
            // seed itself stays in memory on `CreateWalletState` until
            // T-012 wires Keychain encryption — no log, no `UserDefaults`,
            // no network. The derivation is also a useful sanity check
            // that the PBKDF2 path is exercised on every successful
            // backup verification.
            _ = state.deriveSeed()
            onVerified()
        }
    }

    // MARK: - Helpers

    private func positionLabel(for index: Int) -> String {
        // 1-based, zero-padded to 2 digits — matches `WordCell`.
        String(format: "Word %02d", index + 1)
    }

    /// Builds three distinct, randomly-chosen challenges. Each challenge
    /// holds the correct word plus three distractors drawn from the rest
    /// of the BIP-39 wordlist (never the correct word at this position).
    private static func makeChallenges(for words: [String]) -> [Challenge] {
        guard words.count >= 3 else { return [] }
        let positions = Array(0..<words.count).shuffled().prefix(3).sorted()
        let wordlist = BIP39Wordlist.english
        return positions.map { positionIndex in
            let correct = words[positionIndex]
            var distractors: Set<String> = []
            while distractors.count < 3 {
                let candidate = wordlist.randomElement() ?? "abandon"
                if candidate != correct {
                    distractors.insert(candidate)
                }
            }
            let choices = (Array(distractors) + [correct]).shuffled()
            return Challenge(
                positionIndex: positionIndex,
                correctWord: correct,
                choices: choices
            )
        }
    }

    // MARK: - Types

    private struct Challenge: Identifiable, Hashable {
        let positionIndex: Int        // 0-based index into `state.words`
        let correctWord: String
        let choices: [String]         // 4 words: correct + 3 distractors, shuffled
        var id: Int { positionIndex }
    }

    private enum Outcome: Hashable {
        case correct
        case incorrect
    }

    /// Drives the success/error haptic triggers. `.uniHaptic` fires when
    /// its `trigger` Equatable changes, so we toggle 0 ↔ 1 by setting
    /// the case and reading it back via `== .success` / `== .error`.
    private enum HapticEvent: Hashable {
        case none
        case success
        case error
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        BackupVerifyView(state: CreateWalletState(), onVerified: {})
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        BackupVerifyView(state: CreateWalletState(), onVerified: {})
    }
    .preferredColorScheme(.dark)
}
