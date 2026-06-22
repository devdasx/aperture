import SwiftUI

// MARK: - Mnemonic entry step — per-word BIP-39 grid (design_handoff_import_flows)

/// Recovery-phrase entry, rebuilt to the import-flows handoff. A **per-word
/// grid** replaces the old single text box:
///
/// - **Grid** — one grouped container, two columns, numbered slots, hairline
///   dividers (`SeedGrid.hairline`), the four corner cells rounding their outer
///   corner to the container radius. Each slot's 2px status border reflects its
///   word: **green** valid BIP-39 word, **red** not in the list, **gray** the
///   current/active field.
/// - **12 / 24 segmented control** + **Paste** in the head row. 15 / 18 / 21
///   are auto-detected from a paste (the grid grows; `BIP39.validate` accepts
///   every valid length).
/// - **Inline ghost completion** — the gray remainder shows only when the typed
///   prefix uniquely matches one BIP-39 word; space / the keyboard's **next** /
///   a suggestion tap accepts it, commits the word, and advances.
/// - **BIP-39 suggestion bar** above the keyboard (`.keyboard` toolbar).
/// - Tap any slot to jump back and edit it.
/// - The app-bar **key** opens the optional BIP-39 passphrase sheet.
///
/// All validation is real: `BIP39Wordlist` membership per word, `BIP39.validate`
/// checksum for the whole phrase, and the `KnownLeakedSeeds` blocklist.
struct MnemonicEntryView: View {
    @Bindable var state: ImportWalletState
    let onContinue: () -> Void

    /// The slot the user is currently editing.
    @State private var activeIndex: Int = 0
    /// In-progress text for the active slot. Kept in sync with
    /// `state.mnemonicWords[activeIndex]` so validation always sees it.
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    /// Pending keyboard auto-dismiss once the phrase validates.
    @State private var focusDismissTask: Task<Void, Never>? = nil

    @State private var isShowingLeakedWarning: Bool = false
    @State private var isShowingPassphraseSheet: Bool = false

    // MARK: Derived

    private var count: Int { state.mnemonicWords.count }

    /// Lowercased, trimmed words — the validation view of the grid.
    private var words: [String] {
        state.mnemonicWords.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var allFilled: Bool { words.allSatisfy { !$0.isEmpty } }

    /// Full-phrase checksum (BIP-39), valid only once every slot is filled.
    private var checksumValid: Bool { allFilled && BIP39.validate(words) }

    private var canContinue: Bool { checksumValid }

    private var isLeakedPhrase: Bool { KnownLeakedSeeds.isLeaked(mnemonic: words) }

    /// Up to 3 BIP-39 matches for the active draft (the suggestion bar).
    private var suggestions: [String] {
        SortedBIP39Words.matches(prefix: draft.lowercased(), limit: 3)
    }

    /// The inline ghost completion — the remainder of the unique BIP-39 word
    /// the draft prefixes, or `""` when the prefix is empty / ambiguous /
    /// already complete.
    private var ghost: String {
        let prefix = draft.lowercased()
        guard !prefix.isEmpty else { return "" }
        let matches = SortedBIP39Words.matches(prefix: prefix, limit: 2)
        guard matches.count == 1, matches[0] != prefix else { return "" }
        return String(matches[0].dropFirst(prefix.count))
    }

    /// The full BIP-39 word that `prefix` uniquely completes to, or `""` when
    /// the prefix is empty / ambiguous / already a complete word. Computed
    /// from the given prefix (not the active `draft`) so it's correct when
    /// committing pasted / space-separated tokens.
    private func uniqueCompletion(of prefix: String) -> String {
        let lower = prefix.lowercased()
        guard !lower.isEmpty else { return "" }
        let matches = SortedBIP39Words.matches(prefix: lower, limit: 2)
        guard matches.count == 1, matches[0] != lower else { return "" }
        return matches[0]
    }

    private enum SlotStatus { case empty, active, valid, invalid }

    private func status(_ i: Int) -> SlotStatus {
        if i == activeIndex { return .active }
        let w = words[i]
        if w.isEmpty { return .empty }
        return BIP39Wordlist.english.contains(w) ? .valid : .invalid
    }

    private func borderColor(_ st: SlotStatus) -> Color? {
        switch st {
        case .active:  return UniColors.SeedGrid.faint
        case .valid:   return UniColors.PinLock.positive
        case .invalid: return UniColors.Reset.danger
        case .empty:   return nil
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headRow
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 14) {
                    wordGrid
                    if allFilled { validationLine }
                    // The off-screen input field that drives the system
                    // keyboard for the active slot.
                    hiddenField
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                // Forced LTR + English so the slots fill 1→N and digits
                // render ASCII regardless of the app's locale.
                .environment(\.layoutDirection, .leftToRight)
                .environment(\.locale, Locale(identifier: "en"))
            }
            .scrollIndicators(.hidden)
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingPassphraseSheet = true
                } label: {
                    Image(systemName: "key")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text(
                    state.mnemonicPassphrase.isEmpty ? "Add passphrase" : "Edit passphrase"
                ))
            }
            ToolbarItemGroup(placement: .keyboard) {
                suggestionBar
            }
        }
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: UniSpacing.s) {
                UniButton(title: "Continue", variant: .primary, isEnabled: canContinue) {
                    if isLeakedPhrase {
                        isShowingLeakedWarning = true
                    } else {
                        onContinue()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, UniSpacing.l)
        }
        .onAppear { focusFirstEmpty() }
        .uniHaptic(.success, trigger: canContinue)
        .sheet(isPresented: $isShowingPassphraseSheet) {
            PassphraseSheet(
                passphrase: $state.mnemonicPassphrase,
                onDismiss: { isShowingPassphraseSheet = false }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingLeakedWarning) {
            LeakedSeedWarningSheet(
                kind: .mnemonic,
                onChooseDifferent: {
                    clearAll()
                    isShowingLeakedWarning = false
                    focusFirstEmpty()
                },
                onUseAnyway: {
                    isShowingLeakedWarning = false
                    DispatchQueue.main.async { onContinue() }
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: Head row (segmented length + Paste)

    private var headRow: some View {
        HStack {
            segmentedControl
            Spacer(minLength: 0)
            Button {
                pasteFromClipboard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Paste")
                        .font(.system(size: 14.5, weight: .semibold))
                }
                .foregroundStyle(UniColors.Text.primary)
            }
            .buttonStyle(.plain)
        }
    }

    private var segmentedControl: some View {
        HStack(spacing: 2) {
            segButton("12 words", length: 12)
            segButton("24 words", length: 24)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(UniColors.SeedGrid.hairline)
        )
    }

    private func segButton(_ title: String, length: Int) -> some View {
        let on = (count == length)
        return Button {
            selectLength(length)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? UniColors.Text.primary : UniColors.Text.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(UniColors.Background.secondary)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Word grid

    private var wordGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 0),
                GridItem(.flexible(), spacing: 0)
            ],
            spacing: 0
        ) {
            ForEach(Array(state.mnemonicWords.indices), id: \.self) { i in
                slotView(i)
            }
        }
        .background(UniColors.Background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    @ViewBuilder
    private func slotView(_ i: Int) -> some View {
        let st = status(i)
        let isActive = (i == activeIndex)
        HStack(spacing: 10) {
            Text(verbatim: "\(i + 1)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(UniColors.SeedGrid.faint)
                .frame(width: 16, alignment: .trailing)

            if isActive {
                HStack(spacing: 0) {
                    Text(verbatim: draft)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(verbatim: ghost)
                        .foregroundStyle(UniColors.SeedGrid.faint)
                    caret
                }
                .font(.system(size: 15, weight: .semibold))
            } else {
                Text(verbatim: words[i])
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        st == .invalid ? UniColors.Reset.danger : UniColors.Text.primary
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Column divider on the left column; row divider except the last row.
        .overlay(alignment: .trailing) {
            if i % 2 == 0 {
                Rectangle().fill(UniColors.SeedGrid.hairline).frame(width: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if i < count - 2 {
                Rectangle().fill(UniColors.SeedGrid.hairline).frame(height: 1)
            }
        }
        // Per-word status border (rounds the outer corner on the 4 corner cells
        // so the 2px stroke is never clipped by the container radius).
        .overlay {
            if let color = borderColor(st) {
                cornerShape(i).strokeBorder(color, lineWidth: 2)
            }
        }
        .animation(.snappy(duration: 0.18), value: st)
        .onTapGesture { activate(i) }
    }

    /// The active slot's blinking caret — deterministic via `TimelineView`, no
    /// per-view state.
    private var caret: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Rectangle()
                .fill(UniColors.Text.primary)
                .frame(width: 2, height: 18)
                .opacity(on ? 1 : 0)
                .padding(.leading, 1)
        }
    }

    private func cornerShape(_ i: Int) -> UnevenRoundedRectangle {
        let r: CGFloat = 20
        return UnevenRoundedRectangle(
            topLeadingRadius: i == 0 ? r : 0,
            bottomLeadingRadius: i == count - 2 ? r : 0,
            bottomTrailingRadius: i == count - 1 ? r : 0,
            topTrailingRadius: i == 1 ? r : 0,
            style: .continuous
        )
    }

    // MARK: Validation line

    @ViewBuilder
    private var validationLine: some View {
        HStack(spacing: 8) {
            Image(systemName: checksumValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(checksumValid
                 ? "Valid recovery phrase"
                 : "Invalid recovery phrase — checksum failed")
                .font(.system(size: 13.5, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(checksumValid ? UniColors.PinLock.positive : UniColors.Reset.danger)
        .padding(.horizontal, 2)
    }

    // MARK: Suggestion bar (keyboard accessory)

    @ViewBuilder
    private var suggestionBar: some View {
        if focused, !draft.isEmpty, !suggestions.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element) { index, word in
                    if index > 0 {
                        Rectangle()
                            .fill(UniColors.SeedGrid.hairline)
                            .frame(width: 1, height: 22)
                    }
                    Button {
                        UniHapticEngine.shared.play(.selection)
                        commitSuggestion(word)
                    } label: {
                        Text(verbatim: word)
                            .font(.system(size: 15, weight: index == 0 ? .bold : .semibold))
                            .foregroundStyle(UniColors.Text.primary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Hidden input

    /// The real (near-invisible) text field that holds the active slot's draft
    /// and drives the system keyboard. The grid is the visible surface.
    private var hiddenField: some View {
        TextField("", text: $draft)
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.asciiCapable)
            .submitLabel(.next)
            // `.password` suppresses the QuickType predictive strip (our own
            // BIP-39 bar replaces it) and the strong-password autofill.
            .textContentType(.password)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .onChange(of: draft) { _, newValue in handleDraftChange(newValue) }
            .onSubmit { commitWord(acceptGhost: true) }
    }

    // MARK: Input handling

    private func handleDraftChange(_ raw: String) {
        // A newline (Return / pasted line break) commits the current word.
        if raw.contains(where: \.isNewline) {
            draft = raw.filter { !$0.isNewline }
            commitWord(acceptGhost: true)
            return
        }
        // Whitespace → one or more word boundaries (typed space, or words
        // pasted into the field). Commit every completed token, keep the
        // trailing partial as the new draft.
        if raw.contains(where: { $0.isWhitespace }) {
            var tokens = raw.lowercased().components(separatedBy: .whitespaces)
            let trailing = tokens.removeLast()
            for token in tokens where !token.isEmpty {
                commit(word: token, acceptGhost: true)
            }
            draft = trailing.filter { $0.isLetter }
            syncDraftSlot()
            return
        }
        // Plain typing — keep letters only, lowercase, live-sync the slot.
        let cleaned = raw.lowercased().filter { $0.isLetter }
        if cleaned != raw {
            draft = cleaned
            return
        }
        syncDraftSlot()
        scheduleAutoDismiss()
    }

    /// Mirror the active draft into the shared model so validation + the grid
    /// reflect it live.
    private func syncDraftSlot() {
        guard activeIndex < state.mnemonicWords.count else { return }
        state.mnemonicWords[activeIndex] = draft
    }

    /// Commit the active draft to its slot and advance to the next slot.
    private func commitWord(acceptGhost: Bool) {
        commit(word: draft, acceptGhost: acceptGhost)
        draft = activeIndex < state.mnemonicWords.count ? state.mnemonicWords[activeIndex] : ""
        scheduleAutoDismiss()
    }

    /// Write `word` to the active slot (accepting its unique BIP-39 completion
    /// when `acceptGhost`) and step the active index forward (clamped to the
    /// last slot).
    private func commit(word: String, acceptGhost: Bool) {
        guard activeIndex < state.mnemonicWords.count else { return }
        let lower = word.lowercased()
        let final: String
        if acceptGhost {
            let completed = uniqueCompletion(of: lower)
            final = completed.isEmpty ? lower : completed
        } else {
            final = lower
        }
        state.mnemonicWords[activeIndex] = final
        if BIP39Wordlist.english.contains(final) {
            UniHapticEngine.shared.play(.selection)
        }
        if activeIndex < count - 1 { activeIndex += 1 }
    }

    private func commitSuggestion(_ word: String) {
        commit(word: word, acceptGhost: false)
        draft = activeIndex < state.mnemonicWords.count ? state.mnemonicWords[activeIndex] : ""
        scheduleAutoDismiss()
    }

    private func activate(_ index: Int) {
        guard index < state.mnemonicWords.count else { return }
        UniHapticEngine.shared.play(.selection)
        activeIndex = index
        draft = state.mnemonicWords[index]
        focused = true
    }

    private func focusFirstEmpty() {
        let firstEmpty = state.mnemonicWords.firstIndex(where: { $0.isEmpty }) ?? 0
        activeIndex = firstEmpty
        draft = state.mnemonicWords[firstEmpty]
        focused = true
    }

    private func clearAll() {
        for i in state.mnemonicWords.indices { state.mnemonicWords[i] = "" }
        activeIndex = 0
        draft = ""
    }

    /// Auto-dismiss the keyboard once the whole phrase validates, revealing the
    /// "Valid recovery phrase" line + the Continue CTA. Cancellable so a
    /// follow-on edit doesn't yank focus mid-type.
    private func scheduleAutoDismiss() {
        focusDismissTask?.cancel()
        guard canContinue, focused else { return }
        focusDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled else { return }
            focused = false
        }
    }

    // MARK: Length control + paste

    /// Switch the grid to a 12- or 24-word length (the segmented control). The
    /// shared model resizes via its `BIP39WordCount` setter, preserving the
    /// leading words.
    private func selectLength(_ length: Int) {
        guard count != length else { return }
        state.mnemonicWordCount = length == 24 ? .twentyFour : .twelve
        let firstEmpty = state.mnemonicWords.firstIndex(where: { $0.isEmpty }) ?? (state.mnemonicWords.count - 1)
        activeIndex = min(firstEmpty, state.mnemonicWords.count - 1)
        draft = state.mnemonicWords[activeIndex]
    }

    /// Paste a phrase from the clipboard, **auto-detecting its length**. A
    /// 12 / 15 / 18 / 21 / 24-word paste grows the grid to match (even if a
    /// different length was selected); anything else snaps to the nearest of
    /// 12 / 24.
    private func pasteFromClipboard() {
        guard let pasted = UIPasteboard.general.string else { return }
        let parts = pasted
            .lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        UniHapticEngine.shared.play(.contextualImpact(.commit))

        let detected = [12, 15, 18, 21, 24].contains(parts.count)
            ? parts.count
            : (parts.count > 12 ? 24 : 12)
        resizeGrid(to: detected)
        for (i, word) in parts.enumerated() where i < detected {
            state.mnemonicWords[i] = word
        }
        // Park the active slot just past the pasted content (or the last slot).
        activeIndex = min(parts.count, detected - 1)
        draft = state.mnemonicWords[activeIndex]
        // Consume the clipboard so the phrase doesn't linger.
        UIPasteboard.general.items = []
        scheduleAutoDismiss()
    }

    /// Resize the shared word buffer to `n` slots. 12 / 24 go through the
    /// `BIP39WordCount` setter; 15 / 18 / 21 (which the enum can't represent)
    /// resize the array directly — derivation reads the array, not the enum.
    private func resizeGrid(to n: Int) {
        if n == 12 {
            state.mnemonicWordCount = .twelve
        } else if n == 24 {
            state.mnemonicWordCount = .twentyFour
        } else {
            var w = state.mnemonicWords
            if w.count < n {
                w.append(contentsOf: Array(repeating: "", count: n - w.count))
            } else if w.count > n {
                w.removeLast(w.count - n)
            }
            state.mnemonicWords = w
        }
    }
}

/// Pre-sorted BIP-39 wordlist with binary-search prefix lookup.
/// Computed once per process; every keystroke after that is a
/// lower-bound search plus at most `limit` sequential reads.
private enum SortedBIP39Words {
    static let sortedWords: [String] = BIP39Wordlist.english.sorted()

    /// Index of the first word that is `>= prefix` (lower bound).
    private static func lowerBound(of prefix: String) -> Int {
        var low = 0
        var high = sortedWords.count
        while low < high {
            let mid = (low + high) / 2
            if sortedWords[mid] < prefix {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Up to `limit` words starting with `prefix`, in alphabetical
    /// order. Empty for an empty prefix.
    static func matches(prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var result: [String] = []
        var index = lowerBound(of: prefix)
        while index < sortedWords.count,
              result.count < limit,
              sortedWords[index].hasPrefix(prefix) {
            result.append(sortedWords[index])
            index += 1
        }
        return result
    }
}


// MARK: - Mnemonic review step

struct MnemonicReviewView: View {
    @Bindable var state: ImportWalletState
    /// True while the parent flow is persisting the wallet — drives the
    /// Import CTA's native loading spinner (the commit derives + writes
    /// to SwiftData + Keychain, a real beat).
    var isCommitting: Bool = false
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
                importCTA
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

    /// The commit CTA. Disabled until derivation has actually produced
    /// addresses — committing with an empty map would persist a wallet
    /// with no per-chain address rows.
    private var importCTA: some View {
        UniButton(
            title: isCommitting ? "Importing…" : "Import wallet",
            variant: .primary,
            isLoading: isCommitting,
            isEnabled: !derivedAddresses.isEmpty
        ) {
            onCommit()
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
}
