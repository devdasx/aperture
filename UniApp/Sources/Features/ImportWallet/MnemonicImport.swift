import SwiftUI

// MARK: - Mnemonic entry step (single-field, live-validating)

/// Step 1 of the mnemonic-import flow — the user enters 12 or 24 words
/// into a single editor surface with per-word inline coloring, live
/// BIP-39 suggestion chips above the keyboard, and a tap-on-red-word
/// advice sheet. Per the jony-ive 2026-06-05 redesign:
///
/// - **One field**, not a 12-cell grid. The phrase is one continuous
///   string the user types or pastes; word boundaries are inferred.
/// - **Per-word color on commit** — when the caret moves off a word,
///   it commits green (`Validation.valid`) if in the BIP-39 wordlist,
///   red (`Validation.invalid`) otherwise. The word currently being
///   typed stays neutral (no flicker).
/// - **Suggestion strip above the keyboard** — up to 6 BIP-39 words
///   matching the current prefix, alphabetically sorted; tap to commit
///   the word + a trailing space.
/// - **Tap red word** → opens `MnemonicWordAdviceSheet` with the top 3
///   Levenshtein candidates from the 2048-word list. Tap a candidate
///   to replace the invalid word in one gesture.
/// - **Auto-dismiss keyboard** when the phrase is complete AND
///   validates via `BIP39.validate(_:)` (full checksum, not just
///   wordlist membership). Re-tap re-focuses, no friction.
/// - **Restrained motion** — color crossfade is `.snappy(0.22)`; no
///   per-character pop, no bounce (Rule #2 §A.4).
struct MnemonicEntryView: View {
    @Bindable var state: ImportWalletState
    let onContinue: () -> Void

    /// The full editor text. Derived `parsedWords` come from this on
    /// every change.
    @State private var editorText: String = ""

    /// Currently-focused state of the editor; auto-dismisses to false
    /// on successful full-phrase validation.
    @FocusState private var isEditorFocused: Bool

    /// The word currently being advised (red word the user tapped),
    /// or nil. Drives the `.sheet(item:)` presentation.
    @State private var advisedWord: AdvisedWord? = nil

    /// Recovery-phrase guide sheet visibility (Rule #18).
    @State private var isShowingGuide: Bool = false

    /// Leaked-seed warning sheet visibility — presented when the
    /// user's typed phrase matches the `KnownLeakedSeeds` blocklist.
    @State private var isShowingLeakedWarning: Bool = false

    /// Passphrase sheet visibility — opened from the toolbar overflow
    /// Menu ("Add passphrase" / "Edit passphrase"). Reuses the same
    /// `PassphraseSheet` the create-wallet flow uses so the contract
    /// (save vs. cancel, eye-toggle reveal, opaque background) is
    /// identical across both surfaces.
    @State private var isShowingPassphraseSheet: Bool = false

    /// Ambient app layout direction — read once from `@Environment`
    /// so the editor-surface fallback (when `editorText` is empty)
    /// follows the user's locale per Rule #11 §C "interactive input
    /// controls follow ambient when empty."
    @Environment(\.layoutDirection) private var ambientLayoutDirection

    // MARK: Derived

    private var words: [String] {
        editorText
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private var currentWord: String {
        // The word the caret is inside. Without a real caret API on
        // `TextEditor`, we use the heuristic: the last token if the
        // text doesn't end on whitespace, otherwise empty.
        guard let last = editorText.last else { return "" }
        if last.isWhitespace || last.isNewline { return "" }
        return editorText
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .last ?? ""
    }

    private var validCount: Int {
        let pendingIndex = endsWithIncompleteWord ? words.count - 1 : -1
        return words.enumerated().filter { idx, w in
            idx != pendingIndex && BIP39Wordlist.english.contains(w)
        }.count
    }

    private var endsWithIncompleteWord: Bool {
        guard let last = editorText.last else { return false }
        return !last.isWhitespace && !last.isNewline
    }

    /// Suggestion chips for the current word's prefix. Up to 6,
    /// alphabetical, only when the user is mid-typing a non-empty
    /// prefix.
    private var suggestions: [String] {
        let prefix = currentWord
        guard !prefix.isEmpty else { return [] }
        return BIP39Wordlist.english
            .lazy
            .filter { $0.hasPrefix(prefix) }
            .prefix(6)
            .map { $0 }
    }

    private var canContinue: Bool {
        (words.count == 12 || words.count == 24)
            && BIP39.validate(words)
    }

    /// `true` when the typed phrase is valid AND matches the
    /// `KnownLeakedSeeds` blocklist. Continue is still enabled — but
    /// the tap presents `LeakedSeedWarningSheet` instead of pushing
    /// straight to review.
    private var isLeakedPhrase: Bool {
        KnownLeakedSeeds.isLeaked(mnemonic: words)
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                ImportHeaderBlock(
                    title: "Enter your recovery phrase",
                    subtitle: "Type or paste the twelve or twenty-four words from the wallet you want to bring in. Aperture checks every word against the standard list as you go."
                )
                editorSurface
                ImportExampleCaption(
                    caption: "Example only — never type a real phrase you saw in a tutorial.",
                    example: "abandon abandon abandon … about",
                    monospaced: false
                )
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
            .padding(.bottom, UniSpacing.xl)
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Enter recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Per user direction 2026-06-05, the leading toolbar slot is
            // an overflow Menu that holds both the guide trigger and the
            // optional-passphrase entry — keeping the screen body free
            // of the inline DisclosureGroup and freeing real estate for
            // the suggestion strip. Paste stays in the trailing slot.
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        isShowingPassphraseSheet = true
                    } label: {
                        Label(
                            state.mnemonicPassphrase.isEmpty
                                ? "Add passphrase"
                                : "Edit passphrase",
                            systemImage: "key"
                        )
                    }
                    Button {
                        isShowingGuide = true
                    } label: {
                        Label("What's a recovery phrase?", systemImage: "info.circle")
                    }
                } label: {
                    // Bare `ellipsis` — no `.circle` chrome. M-003:
                    // the circle wrapper is the off-system look we
                    // already corrected once before. Toolbar icons
                    // inherit nav-bar tinting; adding chrome reads
                    // as a foreign bubble next to the title.
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text("More options"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Paste") {
                    pasteFromClipboard()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: UniSpacing.s) {
                // Strip is visible whenever the editor is focused AND
                // the user has a non-empty in-progress word. When the
                // prefix has zero BIP-39 matches the strip renders a
                // quiet "No matching word" hint instead of hiding —
                // absence-of-chips was reading as "the feature broke",
                // a single explanatory line is honest and calm.
                if isEditorFocused && !currentWord.isEmpty {
                    suggestionStrip
                }
                continueButton
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.l)
        }
        .onChange(of: editorText) { oldValue, newValue in
            // Enter = dismiss keyboard, never newline. Detect the
            // single-trailing-newline-on-prior-buffer signal that means
            // the user pressed Enter (vs pasted multi-line content, vs
            // deleted mid-buffer). On detection: strip the `"\n"`,
            // dismiss focus, and stop here — the normalization below
            // would otherwise filter the `"\n"` out as whitespace and
            // mask the signal. Aligns with the `UniTextField` contract;
            // see `CLAUDE.md` Rule #19 §D.
            if newValue.count == oldValue.count + 1,
               newValue.last == "\n",
               newValue.dropLast() == oldValue {
                editorText = String(newValue.dropLast())
                isEditorFocused = false
                return
            }
            // Normalize: lowercase + strip non-letter/whitespace.
            let cleaned = newValue
                .lowercased()
                .filter { $0.isLetter || $0.isWhitespace }
            if cleaned != newValue {
                editorText = cleaned
                return
            }
            // Sync into shared state (used by the next step).
            state.mnemonicWords = words

            // Auto-detect word count from pasted phrases.
            if words.count == 24, state.mnemonicWordCount != .twentyFour {
                state.mnemonicWordCount = .twentyFour
            } else if words.count == 12, state.mnemonicWordCount != .twelve {
                state.mnemonicWordCount = .twelve
            }

            // Auto-dismiss keyboard when the phrase is complete + valid.
            if canContinue, isEditorFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isEditorFocused = false
                }
            }
        }
        .uniHaptic(.success, trigger: canContinue)
        .sheet(item: $advisedWord) { advised in
            MnemonicWordAdviceSheet(
                typedWord: advised.word,
                onPickSuggestion: { replacement in
                    replaceWord(at: advised.index, with: replacement)
                    advisedWord = nil
                },
                onKeepEditing: {
                    advisedWord = nil
                    isEditorFocused = true
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingGuide) {
            RecoveryPhraseGuideSheet(onDismiss: { isShowingGuide = false })
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingPassphraseSheet) {
            PassphraseSheet(
                passphrase: $state.mnemonicPassphrase,
                onDismiss: { isShowingPassphraseSheet = false }
            )
            .uniAppEnvironment()
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingLeakedWarning) {
            LeakedSeedWarningSheet(
                kind: .mnemonic,
                onChooseDifferent: {
                    editorText = ""
                    isShowingLeakedWarning = false
                    isEditorFocused = true
                },
                onUseAnyway: {
                    isShowingLeakedWarning = false
                    // User explicitly overrode — proceed to review.
                    DispatchQueue.main.async {
                        onContinue()
                    }
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }



    // MARK: Counter row

    private var counterRow: some View {
        HStack {
            Text("\(validCount) of \(state.mnemonicWordCount.rawValue) words")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer()
            Button {
                pasteFromClipboard()
            } label: {
                HStack(spacing: UniSpacing.xs) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Paste")
                        .font(UniTypography.subheadline.weight(.semibold))
                }
                .foregroundStyle(UniColors.Tint.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Editor surface (overlay + transparent editor)

    private var editorSurface: some View {
        ZStack(alignment: .topLeading) {
            // Colored overlay — the visible text. Built from
            // AttributedString runs per word.
            coloredOverlay
                .padding(UniSpacing.s)
                .allowsHitTesting(true) // for link taps on red words

            // Transparent editor — the actual input. foregroundStyle
            // is clear so only the overlay renders; the native caret
            // (system tint) is still visible.
            TextEditor(text: $editorText)
                .focused($isEditorFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.password)
                .font(UniTypography.body)
                .foregroundStyle(Color.clear)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, UniSpacing.s - 5) // align with overlay
                .padding(.vertical, UniSpacing.s - 8)
                .multilineTextAlignment(.leading)

            // Empty-state placeholder.
            if editorText.isEmpty {
                Text("Type or paste your 12 or 24 word phrase")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .padding(UniSpacing.s)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 132, maxHeight: 220)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
        // Per Rule #11 §C "interactive input controls follow ambient"
        // with the **content-aware refinement (2026-06-06)**: when the
        // user types, the field's writing direction follows the
        // FIRST STRONG directional character — same `TextDirection.detect`
        // logic the `UniTextField` primitive uses. Empty editor →
        // follow ambient app locale (RTL placeholder right-aligned in
        // Arabic, LTR left-aligned in English). User types Latin
        // (BIP-39 English word) → field flips to LTR, cursor starts
        // at the left, text grows rightward. User types Arabic →
        // field stays RTL, cursor on right. Matches the user's
        // expectation from Image #50: "when write in LTR start from
        // left, when write in RTL start from right."
        .environment(
            \.layoutDirection,
            TextDirection.detect(in: editorText) ?? ambientLayoutDirection
        )
        .contentShape(Rectangle())
        .onTapGesture { isEditorFocused = true }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "aperture", url.host == "invalid-word",
               let last = url.pathComponents.last, let index = Int(last) {
                if index < words.count {
                    isEditorFocused = false
                    advisedWord = AdvisedWord(index: index, word: words[index])
                }
                return .handled
            }
            return .systemAction
        })
    }

    /// Builds the colored overlay as a SwiftUI `Text` with per-word
    /// AttributedString runs. Each word carries its validation color;
    /// invalid (committed) words also carry a `.link` attribute
    /// pointing to `aperture://invalid-word/<index>` so taps surface
    /// the advice sheet via the OpenURL environment action.
    private var coloredOverlay: some View {
        let pendingIndex = endsWithIncompleteWord ? words.count - 1 : -1
        var attributed = AttributedString()
        var firstWord = true
        for (index, word) in words.enumerated() {
            if !firstWord {
                attributed.append(AttributedString(" "))
            }
            firstWord = false
            var run = AttributedString(word)
            let isPending = (index == pendingIndex)
            let isValid = BIP39Wordlist.english.contains(word)
            if isPending {
                run.foregroundColor = UniColors.Validation.pending
            } else if isValid {
                run.foregroundColor = UniColors.Validation.valid
            } else {
                run.foregroundColor = UniColors.Validation.invalid
                run.underlineStyle = .single
                run.link = URL(string: "aperture://invalid-word/\(index)")
            }
            attributed.append(run)
        }
        // Trailing space the user may have typed.
        if editorText.last?.isWhitespace == true {
            attributed.append(AttributedString(" "))
        }
        return Text(attributed)
            .font(UniTypography.body)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(.snappy(duration: 0.22), value: words)
    }

    // MARK: Suggestion strip

    @ViewBuilder
    private var suggestionStrip: some View {
        if suggestions.isEmpty {
            // Quiet, calm "no matches" line — explains the absence
            // rather than disappearing the affordance entirely.
            HStack {
                Text("No matching word")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .italic()
                Spacer()
            }
            .padding(.horizontal, UniSpacing.s)
            .frame(height: 44)
        } else {
            GlassEffectContainer(spacing: UniSpacing.xs) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: UniSpacing.xs) {
                        ForEach(suggestions, id: \.self) { word in
                            Button {
                                commitSuggestion(word)
                            } label: {
                                Text(verbatim: word)
                                    .font(UniTypography.subheadline)
                                    .padding(.horizontal, UniSpacing.s)
                                    .padding(.vertical, UniSpacing.xs)
                                    .foregroundStyle(UniColors.Text.primary)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(UniColors.Background.secondary)
                                    )
                            }
                            .buttonStyle(.plain)
                            .uniHaptic(.contextualImpact(.tap), trigger: word)
                        }
                    }
                    .padding(.horizontal, UniSpacing.xs)
                }
            }
            .frame(height: 44)
        }
    }

    // MARK: Continue button

    /// Per Rule #19 — every CTA goes through `UniButton`. The
    /// leaked-phrase check lives inside the action closure; the
    /// `isEnabled:` parameter owns the disabled-state contract; the
    /// `.contextualImpact(.commit)` haptic auto-fires via the
    /// primary variant.
    private var continueButton: some View {
        UniButton(title: "Continue", variant: .primary, isEnabled: canContinue) {
            if isLeakedPhrase {
                isShowingLeakedWarning = true
            } else {
                onContinue()
            }
        }
    }

    // MARK: Actions

    private func commitSuggestion(_ word: String) {
        // Replace the in-progress word with the chosen suggestion +
        // trailing space so the user flows into the next word.
        var newText = editorText
        // Strip the last (in-progress) token.
        if let lastSpace = newText.lastIndex(where: { $0.isWhitespace || $0.isNewline }) {
            newText = String(newText[...lastSpace])
        } else {
            newText = ""
        }
        newText.append(word + " ")
        editorText = newText
    }

    private func replaceWord(at index: Int, with replacement: String) {
        let parts = editorText
            .components(separatedBy: .whitespacesAndNewlines)
            .enumerated()
            .map { i, w -> String in
                if i == index { return replacement }
                return w
            }
        editorText = parts.filter { !$0.isEmpty }.joined(separator: " ")
            + (editorText.last?.isWhitespace == true ? " " : "")
    }

    private func pasteFromClipboard() {
        guard let pasted = UIPasteboard.general.string else { return }
        let cleaned = pasted
            .lowercased()
            .filter { $0.isLetter || $0.isWhitespace || $0.isNewline }
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        editorText = cleaned + " "
        UIPasteboard.general.string = ""
    }
}

/// Identity for the `.sheet(item:)` invalid-word advice presentation.
private struct AdvisedWord: Identifiable, Hashable {
    let index: Int
    let word: String
    var id: String { "\(index)|\(word)" }
}


// MARK: - Mnemonic review step

struct MnemonicReviewView: View {
    @Bindable var state: ImportWalletState
    let onCommit: () -> Void

    @AppStorage(CurrencyPreference.storageKey)
    private var currencyCode: String = CurrencyPreference.defaultCode

    @State private var derivedAddresses: [SupportedChain: String] = [:]
    @State private var balances: [SupportedChain: ChainBalance] = [:]
    /// Discovered fungible tokens per chain (ERC-20 / SPL today;
    /// TRC-20 / TON jettons / Cosmos IBC follow). Keyed by chain so
    /// rendering can group tokens under their chain row.
    @State private var tokens: [SupportedChain: [TokenBalance]] = [:]
    @State private var isDeriving = true
    @State private var scanState: ScanState = .idle
    @State private var rescanTrigger: Int = 0
    /// `true` while the Test toolbar action has swapped in
    /// `TestAddresses.map`. Disables the Import CTA — the user
    /// can't commit a wallet they don't have the seed for — and
    /// shows an inline banner naming the state honestly.
    @State private var isTestMode: Bool = false

    /// Real on-chain balance scanner backed by `RPCClient` + per-family
    /// adapters. Each chain scans independently and streams its row to
    /// the UI as soon as both its balance and its USD price land — a
    /// slow / failing chain doesn't block the others.
    private let scanner = RealRPCBalanceScanner()

    private var sortedChains: [SupportedChain] {
        derivedAddresses.keys.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                UniHeadline(
                    text: "Does this look like the wallet you expected?",
                    alignment: .leading
                )
                .fixedSize(horizontal: false, vertical: true)
                UniBody(
                    text: "Aperture will derive accounts on every supported chain from this phrase. You can hide chains you don't use later.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)

                if isDeriving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UniSpacing.l)
                } else {
                    addressList
                }

                reviewFooter
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
            .padding(.bottom, UniSpacing.xl)
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Review wallet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: UniSpacing.xs) {
                    // Test action: swap in curated public addresses
                    // with known on-chain balances and re-run the
                    // scan. Auditable end-to-end verification —
                    // every chain hits its real RPC; rows that come
                    // back with balances prove the pipeline works
                    // for that chain end-to-end.
                    Button {
                        useTestAddresses()
                    } label: {
                        Image(systemName: "flask.fill")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Test against public addresses"))
                    .disabled(isDeriving)

                    Button {
                        rescanTrigger &+= 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .semibold))
                            .symbolEffect(.rotate, options: .nonRepeating, value: rescanTrigger)
                    }
                    .accessibilityLabel(Text("Rescan balances"))
                    .disabled(isDeriving)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Nav-bar back chevron is the only "go back" affordance —
            // every iOS user already knows it, so a duplicated
            // "Back" button at the bottom is noise (Rule #2 §A.2 —
            // remove the least-essential element).
            GlassEffectContainer(spacing: UniSpacing.s) {
                if isTestMode {
                    VStack(spacing: UniSpacing.s) {
                        UniFootnote(
                            text: "Test mode — scanning public addresses. The Import action is disabled while in this mode; exit to import your wallet.",
                            alignment: .center
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        UniButton(title: "Exit test mode", variant: .secondary) {
                            exitTestMode()
                        }
                    }
                } else {
                    UniButton(title: "Import wallet", variant: .primary) {
                        onCommit()
                    }
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.l)
        }
        .task {
            await deriveAddresses()
            await runScan()
        }
        .onChange(of: rescanTrigger) { _, _ in
            Task { await runScan() }
        }
    }

    private var addressList: some View {
        VStack(spacing: 0) {
            ForEach(sortedChains, id: \.self) { chain in
                if let address = derivedAddresses[chain] {
                    ReviewChainRow(
                        chain: chain,
                        address: address,
                        balance: balances[chain]
                    )
                    // Token sub-rows for this chain — render under
                    // the native row, sorted by fiat-value desc so
                    // the largest holdings surface first. Empty
                    // when none discovered.
                    let chainTokens = (tokens[chain] ?? []).sorted { a, b in
                        (a.fiatBalance ?? 0) > (b.fiatBalance ?? 0)
                    }
                    if !chainTokens.isEmpty {
                        ForEach(chainTokens) { token in
                            ReviewTokenRow(token: token)
                        }
                    }
                    if chain != sortedChains.last {
                        UniDivider()
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }

    private var reviewFooter: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniFootnote(
                text: "Addresses are derived locally on this iPhone using Trust Wallet Core — the same open-source cryptography Trust Wallet itself uses, so importing this phrase here produces the same addresses you would see there.",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            UniFootnote(
                text: "Balances are read directly from each chain's public RPC. Aperture has no servers — but the public providers may log your IP and the queried address.",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runScan() async {
        guard !derivedAddresses.isEmpty else { return }
        scanState = .scanning
        // Clear the prior round so the rows revert to the loading
        // state for visual continuity.
        balances = [:]
        tokens = [:]
        let currency = CurrencyPreference.currency(for: currencyCode)
            ?? CurrencyPreference.all[0]
        // Stream per-chain rows as soon as each one's balance + USD
        // price land. A slow / failing chain doesn't block the rest;
        // the user sees rows fill in progressively instead of one
        // big "everything appears at once" jump. Tokens stream
        // alongside natives — `USDC` on Ethereum may arrive before
        // `ETH` itself if Coinbase prices it faster.
        let stream = scanner.streamScan(
            addresses: derivedAddresses,
            currency: currency
        )
        for await row in stream {
            switch row {
            case .native(let chainBalance):
                balances[chainBalance.chain] = chainBalance
            case .token(let tokenBalance):
                var existing = tokens[tokenBalance.chain] ?? []
                // Replace any prior entry for the same contract
                // (the stream may yield refreshes; one source of
                // truth per (chain, contract)).
                existing.removeAll { $0.contract == tokenBalance.contract }
                existing.append(tokenBalance)
                tokens[tokenBalance.chain] = existing
            }
        }
        scanState = .completed
    }

    private func deriveAddresses() async {
        let words = state.mnemonicWords.map { $0.lowercased() }
        // WalletCore takes the mnemonic directly (it runs BIP-39 →
        // BIP-32 → per-chain derivation inside its C++ pipeline).
        // Resolves in a few milliseconds for all 24 chains.
        let addresses = await state.service.deriveAddresses(
            mnemonic: words,
            passphrase: state.mnemonicPassphrase
        )
        await MainActor.run {
            self.derivedAddresses = addresses
            self.state.derivedAddressesFromMnemonic = addresses
            self.isDeriving = false
        }
    }

    /// Swap in curated public addresses with known on-chain
    /// balances and re-run the same scan pipeline an imported
    /// wallet would. Purely a developer / verifier affordance —
    /// no funds move, no state persists beyond the screen, and
    /// `state.derivedAddressesFromMnemonic` (the value the import
    /// commit reads) is left untouched. The Import CTA is disabled
    /// while test mode is active so the user can't accidentally
    /// commit a wallet they don't have the seed for.
    private func useTestAddresses() {
        balances = [:]
        derivedAddresses = TestAddresses.map
        isTestMode = true
        Task { await runScan() }
    }

    /// Exit test mode and restore the originally-derived addresses.
    private func exitTestMode() {
        balances = [:]
        derivedAddresses = state.derivedAddressesFromMnemonic
        isTestMode = false
        Task { await runScan() }
    }
}
