import SwiftUI

/// "Roll your own" — user-supplied entropy flow.
///
/// Per the jony-ive 2026-06-05 native-navigation audit, this is a
/// `NavigationStack`-rooted three-screen flow (mirroring the Settings
/// sheet's architecture exactly): a List-of-modes root, a pushed
/// collecting screen, and a pushed preview screen. The earlier
/// `@State step` state machine is gone — push/pop is system-native, the
/// back chevron comes from `NavigationStack` automatically, the
/// slide-in-from-trailing animation is the platform's, and RTL flips
/// the slide direction for free.
///
/// **Cryptographic honesty.** Same SHA-256 collapse pipeline as before:
/// the user's deterministic input string passes through SHA-256 once
/// and the resulting bytes drive `BIP39.mnemonic(fromEntropy:)`. The
/// resulting phrase is real and BIP-39-valid.
///
/// **Sheet shape.** NavigationStack-rooted at the sheet body, presented
/// with `.presentationDetents([.large])` to match the Settings sheet's
/// family member. Not UniSheet — UniSheet is for single-decision
/// content cards, this is a navigation experience.
struct RollYourOwnSheet: View {
    @Bindable var state: CreateWalletState
    let onDismiss: () -> Void

    /// Local navigation path. The sheet is transient — no need to
    /// hoist this to the presenter; it doesn't survive direction-flip
    /// rebuilds, but the user can re-enter the flow.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            RollYourOwnModeSelectionView(
                wordCount: state.wordCount
            )
            .navigationTitle("Roll your own")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: RollYourOwnDestination.self) { destination in
                switch destination {
                case .collecting(let mode):
                    RollYourOwnKeypadView(
                        mode: mode,
                        wordCount: state.wordCount,
                        onGenerate: { words in
                            path.append(RollYourOwnDestination.preview(words: words))
                        }
                    )
                case .preview(let words):
                    RollYourOwnPreviewView(
                        words: words,
                        onCommit: {
                            state.commit(words: words)
                            onDismiss()
                        },
                        onDiscard: {
                            // Pop all the way back to mode selection
                            // so the user can pick a fresh start.
                            path = NavigationPath()
                        }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
            }
        }
    }
}

/// Push destinations within the Roll-your-own NavigationStack. The
/// inputs travel as associated values so the destination resolver in
/// `navigationDestination(for:)` can construct the pushed view with
/// exactly the data it needs.
enum RollYourOwnDestination: Hashable {
    case collecting(EntropyEncoder.Mode)
    case preview(words: [String])
}

// MARK: - Mode selection (root view)

/// Mode-selection root. Mirrors the Settings sheet chrome exactly:
/// `List(.insetGrouped)` with `.scrollContentBackground(.hidden)` and
/// `.background(UniColors.Background.primary)`, rows on
/// `UniColors.Background.secondary`, honesty footnote in a final
/// section with a transparent row background reading as a footer band.
private struct RollYourOwnModeSelectionView: View {
    let wordCount: BIP39WordCount

    var body: some View {
        List {
            Section {
                heroAndBodyHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: UniSpacing.l, leading: UniSpacing.l, bottom: UniSpacing.l, trailing: UniSpacing.l))
                    .listRowSeparator(.hidden)
            }

            Section {
                NavigationLink(value: RollYourOwnDestination.collecting(.dice)) {
                    RollYourOwnModeRow(
                        systemImage: "dice",
                        title: "Dice",
                        trailing: countDescription(for: .dice)
                    )
                }
                .listRowBackground(UniColors.Background.secondary)

                NavigationLink(value: RollYourOwnDestination.collecting(.coin)) {
                    RollYourOwnModeRow(
                        systemImage: "circle.lefthalf.filled",
                        title: "Coin",
                        trailing: countDescription(for: .coin)
                    )
                }
                .listRowBackground(UniColors.Background.secondary)

                NavigationLink(value: RollYourOwnDestination.collecting(.numbers)) {
                    RollYourOwnModeRow(
                        systemImage: "number",
                        title: "Numbers",
                        trailing: countDescription(for: .numbers)
                    )
                }
                .listRowBackground(UniColors.Background.secondary)
            }

            Section {
                Text("Use a fair die or coin. Patterns from birthdays or phone numbers reduce real randomness.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
    }

    private var heroAndBodyHeader: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack {
                Spacer()
                Image(systemName: "dice.fill")
                    .font(.system(size: 48, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Brand.mark)
                    .accessibilityHidden(true)
                Spacer()
            }
            UniBody(
                text: "Make your own phrase by rolling dice, flipping a coin, or typing numbers. Your input is hashed with SHA-256 so every digit shapes the result.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func countDescription(for mode: EntropyEncoder.Mode) -> String {
        let count = mode.requiredCount(for: wordCount)
        switch mode {
        case .dice:    return String.apertureLocalized("\(count) rolls")
        case .coin:    return String.apertureLocalized("\(count) flips")
        case .numbers: return String.apertureLocalized("\(count) digits")
        }
    }
}

/// Local row primitive — mirrors `SettingsRow` shape (private to
/// SettingsView, so a sibling private struct here keeps both files
/// self-contained). Leading SF Symbol + title + trailing subtitle.
/// `NavigationLink` supplies the trailing chevron automatically — we
/// do not render one here.
private struct RollYourOwnModeRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let trailing: String

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)

            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)

            Spacer()

            Text(verbatim: trailing)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}

// MARK: - Collecting view (pushed)

/// Pushed via `RollYourOwnDestination.collecting(mode)`. Owns its own
/// `buffer` — re-entering the same mode starts a fresh collection,
/// which is the honest behavior. The system back chevron at
/// `topBarLeading` is automatic and means "discard this in-flight
/// collection and pick a different mode." No mode-switch ribbon
/// required (the user pops to root and picks another row).
private struct RollYourOwnKeypadView: View {
    let mode: EntropyEncoder.Mode
    let wordCount: BIP39WordCount
    let onGenerate: ([String]) -> Void

    @State private var buffer: [String] = []
    @State private var keypressTrigger: Int = 0
    @State private var deleteTrigger: Int = 0
    @State private var completeTrigger: Int = 0

    // Coin-specific state — see currentFaceContent + recordFlip.
    @State private var flipTurn: Double = 0
    @State private var coinLandTrigger: Int = 0
    private enum CoinFace { case heads, tails }
    private var coinDisplayFace: CoinFace {
        switch buffer.last {
        case "1":  return .tails
        case "0":  return .heads
        default:   return .heads
        }
    }

    private var required: Int { mode.requiredCount(for: wordCount) }
    private var isComplete: Bool { buffer.count >= required }

    var body: some View {
        VStack(spacing: UniSpacing.l) {
            progressRow
            lastEntriesRow
            keypad
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.l)
        .background(UniColors.Background.primary)
        .navigationTitle(titleKey)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actionRegion
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
        }
        .uniHaptic(.selection, trigger: keypressTrigger)
        .uniHaptic(.selectionDeselect, trigger: deleteTrigger)
        .uniHaptic(.success, trigger: completeTrigger)
        .uniHaptic(.selection, trigger: coinLandTrigger)
    }

    private var titleKey: LocalizedStringKey {
        switch mode {
        case .dice:    return "Roll dice"
        case .coin:    return "Flip the coin"
        case .numbers: return "Type your numbers"
        }
    }

    // MARK: Action region

    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(
                title: isComplete
                    ? LocalizedStringKey("Generate phrase")
                    : LocalizedStringKey("Need \(required - buffer.count) more"),
                variant: .primary,
                isEnabled: isComplete
            ) {
                let words = EntropyEncoder.mnemonic(
                    from: buffer,
                    mode: mode,
                    wordCount: wordCount
                )
                onGenerate(words)
            }
        }
    }

    // MARK: Progress

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack {
                Text("\(buffer.count) of \(required)")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Spacer()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(UniColors.Background.secondary)
                        .frame(height: 6)
                    Capsule()
                        .fill(isComplete ? UniColors.Status.successForeground : UniColors.Tint.accent)
                        .frame(width: proxy.size.width * CGFloat(min(buffer.count, required)) / CGFloat(required), height: 6)
                        .animation(.easeInOut(duration: 0.2), value: buffer.count)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: Last 8 entries

    private var lastEntriesRow: some View {
        HStack(spacing: UniSpacing.xs) {
            ForEach(Array(buffer.suffix(8).enumerated()), id: \.offset) { _, entry in
                Text(verbatim: entry.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Text.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .padding(.horizontal, UniSpacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(UniColors.Background.secondary)
                    )
            }
            Spacer()
        }
        .frame(height: 28)
    }

    // MARK: Keypad

    @ViewBuilder
    private var keypad: some View {
        switch mode {
        case .dice:    diceTray
        case .coin:    coinView
        case .numbers: numbersGrid
        }
    }

    // MARK: Dice tray (2 rows × 3 columns of die.face.N.fill).

    private var diceTray: some View {
        VStack(spacing: UniSpacing.s) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: UniSpacing.s), count: 3), spacing: UniSpacing.s) {
                ForEach(1...6, id: \.self) { n in
                    diceFaceKey(n)
                }
            }
            deleteKey
        }
    }

    @ViewBuilder
    private func diceFaceKey(_ n: Int) -> some View {
        Button {
            guard !isComplete else { return }
            buffer.append(String(n))
            keypressTrigger &+= 1
            if buffer.count >= required {
                completeTrigger &+= 1
            }
        } label: {
            Image(systemName: "die.face.\(n).fill")
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .symbolEffect(.bounce, options: .nonRepeating, value: keypressTrigger)
                .frame(maxWidth: .infinity, minHeight: 88)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isComplete)
        .opacity(isComplete ? 0.5 : 1)
        .accessibilityLabel(Text("Die face \(n)"))
        .uniHaptic(.contextualImpact(.tap), trigger: keypressTrigger)
    }

    // MARK: Coin (single disc, two buttons).

    private var coinView: some View {
        VStack(spacing: UniSpacing.l) {
            coinDisc
            HStack(spacing: UniSpacing.s) {
                UniButton(title: "Heads", variant: .secondary) {
                    recordFlip(.heads)
                }
                .accessibilityHint(Text("Records this flip"))
                UniButton(title: "Tails", variant: .secondary) {
                    recordFlip(.tails)
                }
                .accessibilityHint(Text("Records this flip"))
            }
            deleteKey
        }
    }

    private var coinDisc: some View {
        ZStack {
            Circle()
                .fill(UniColors.Background.secondary)
                .frame(width: 140, height: 140)
            currentFaceContent
        }
        .rotation3DEffect(
            .degrees(flipTurn),
            axis: (x: 1, y: 0, z: 0)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: flipTurn)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var currentFaceContent: some View {
        switch coinDisplayFace {
        case .heads:
            ApertureIrisView(
                ringColor: UniColors.Brand.mark,
                negativeColor: UniColors.Background.secondary
            )
            .frame(width: 72, height: 72)
        case .tails:
            Text(verbatim: "U")
                .font(UniTypography.largeTitle.weight(.bold))
                .foregroundStyle(UniColors.Brand.mark)
        }
    }

    private func recordFlip(_ face: CoinFace) {
        guard !isComplete else { return }
        buffer.append(face == .heads ? "0" : "1")
        keypressTrigger &+= 1
        flipTurn += 180
        if buffer.count >= required {
            completeTrigger &+= 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            coinLandTrigger &+= 1
        }
    }

    // MARK: Numbers (hex grid).

    private var numbersGrid: some View {
        let alphabet = EntropyEncoder.Mode.numbers.alphabet
        return GlassEffectContainer(spacing: UniSpacing.s) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: UniSpacing.s), count: 4), spacing: UniSpacing.s) {
                ForEach(alphabet, id: \.self) { symbol in
                    Button {
                        guard !isComplete else { return }
                        buffer.append(symbol)
                        keypressTrigger &+= 1
                        if buffer.count >= required {
                            completeTrigger &+= 1
                        }
                    } label: {
                        Text(verbatim: symbol.uppercased())
                            .font(.system(size: 22, weight: .regular, design: .default))
                            .foregroundStyle(UniColors.Text.primary)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: UniRadius.m))
                            // Hit-test fix (2026-06-08): mirror the
                            // glass shape so taps in the painted glass
                            // outside the glyph's intrinsic bounds
                            // register. Same root cause as the
                            // `UniButton` capsule fix.
                            .contentShape(.rect(cornerRadius: UniRadius.m))
                    }
                    .buttonStyle(.plain)
                    .disabled(isComplete)
                    .opacity(isComplete ? 0.5 : 1)
                    .accessibilityLabel(Text(verbatim: symbol))
                }
                deleteKey
            }
        }
    }

    // MARK: Delete (shared).

    private var deleteKey: some View {
        Button {
            guard !buffer.isEmpty else { return }
            buffer.removeLast()
            deleteTrigger &+= 1
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(UniColors.Text.primary)
                .frame(maxWidth: .infinity, minHeight: 56)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: UniRadius.m))
                // Hit-test fix (2026-06-08) — see numbersGrid above.
                .contentShape(.rect(cornerRadius: UniRadius.m))
        }
        .buttonStyle(.plain)
        .disabled(buffer.isEmpty)
        .opacity(buffer.isEmpty ? 0.4 : 1)
        .accessibilityLabel(Text("Clear last"))
    }
}

// MARK: - Preview view (pushed)

/// Pushed via `RollYourOwnDestination.preview(words:)`. Shows the
/// generated mnemonic in the same grid pattern as the main
/// `RecoveryPhraseView`. Bottom CTAs: "Use this phrase" commits;
/// "Discard and start over" pops to the mode-selection root.
private struct RollYourOwnPreviewView: View {
    let words: [String]
    let onCommit: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            UniBody(
                text: "Your recovery phrase will be replaced.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            wordsGrid
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.l)
        .background(UniColors.Background.primary)
        .navigationTitle("Your recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actionRegion
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
        }
    }

    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            VStack(spacing: UniSpacing.s) {
                UniButton(title: "Use this phrase", variant: .primary) {
                    onCommit()
                }
                UniButton(title: "Discard and start over", variant: .destructive) {
                    onDiscard()
                }
            }
        }
    }

    private var wordsGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: UniSpacing.s),
            GridItem(.flexible(), spacing: UniSpacing.s)
        ]
        return LazyVGrid(columns: columns, spacing: UniSpacing.s) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: UniSpacing.xs) {
                    Text(verbatim: String(format: "%02d", index + 1))
                        .font(UniTypography.caption2.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                        .frame(minWidth: 22, alignment: .trailing)
                    Text(verbatim: word)
                        .font(UniTypography.body.weight(.semibold))
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, UniSpacing.s)
                .padding(.vertical, UniSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
            }
        }
    }
}
