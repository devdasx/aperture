import SwiftUI

// MARK: - Mnemonic entry step — single chip-flow field (design_handoff_import_flows)

/// Recovery-phrase entry: a **single flat, full-width, square phrase field**
/// that fills with **square word chips** as the user types.
///
/// - One edge-to-edge `--surface` field (0 corner radius, no shadow) whose
///   height grows as chips wrap. Each committed word is a square chip (faint
///   index + word) bordered **green** (valid BIP-39) or **red** (not-in-list,
///   + red text); the current word is the 2px-ink `typing` chip with a blinking
///   caret and the gray unique-prefix **ghost** completion.
/// - **Tap any committed chip** to remove it and drop the cursor on that slot to
///   re-enter it (then the cursor returns to the end).
/// - Paste / Scan live as icon-only utility buttons inside the field's
///   bottom-right corner.
/// - **Length auto-detected** (12/15/18/21/24) + checksum-validated; nothing to
///   pick. The app-bar **⋯** opens the optional passphrase sheet.
/// - Custom **white** BIP-39 suggestion buttons float above the keyboard (not a
///   keyboard accessory), each its own pill on a transparent row.
///
/// The phrase is held as an array of committed `words` plus a separate `draft`
/// for the slot at `activeIndex` — this is what lets a tapped chip be edited
/// in place. A hidden single-line field drives the keyboard; a zero-width
/// sentinel prefix lets us detect Backspace on an empty draft (edit the
/// previous chip).
struct MnemonicEntryView: View {
    @Bindable var state: ImportWalletState
    var isCommitting: Bool = false
    let onContinue: () -> Void

    /// Committed words (no empties). The active slot's live text lives in
    /// `draft`, inserted at `activeIndex` — never stored here.
    @State private var words: [String] = []
    /// Live text for the slot at `activeIndex`.
    @State private var draft: String = ""
    /// Where the active (typing) slot sits, `0...words.count`.
    @State private var activeIndex: Int = 0
    /// Bound text of the hidden field — always `sentinel + draft`.
    @State private var fieldText: String = "\u{200B}"

    @FocusState private var focused: Bool
    @State private var focusDismissTask: Task<Void, Never>? = nil
    @State private var isShowingLeakedWarning = false
    @State private var isShowingPassphraseSheet = false
    @State private var isShowingScanner = false

    /// Drives the iOS 26 native **zoom** transition — the passphrase sheet
    /// scales out of the ⋯ toolbar button (`matchedTransitionSource` on the
    /// `ToolbarItem` ↔ `navigationTransition(.zoom)` on the sheet's root).
    @Namespace private var passphraseZoom
    private let passphraseZoomID = "passphrase"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Zero-width space that prefixes the hidden field so a Backspace on an
    /// empty draft (which deletes the sentinel) is detectable.
    private let sentinel = "\u{200B}"

    // MARK: Derived

    /// The full ordered phrase: committed words with the live draft inserted at
    /// the active slot.
    private var phrase: [String] {
        var arr = words
        if !draft.isEmpty { arr.insert(draft, at: min(activeIndex, arr.count)) }
        return arr
    }

    private var lengthValid: Bool { [12, 15, 18, 21, 24].contains(phrase.count) }
    private var allReal: Bool {
        !phrase.isEmpty && phrase.allSatisfy { BIP39Wordlist.english.contains($0) }
    }
    private var checksumValid: Bool { lengthValid && BIP39.validate(phrase) }
    private var canContinue: Bool { checksumValid }
    private var isLeakedPhrase: Bool { KnownLeakedSeeds.isLeaked(mnemonic: phrase) }

    /// Up to 3 BIP-39 matches for the current word (the suggestion row).
    private var suggestions: [String] {
        SortedBIP39Words.matches(prefix: draft, limit: 3)
    }

    /// The inline ghost completion — the remainder of the unique BIP-39 word the
    /// draft prefixes, or `""` when empty / ambiguous / complete.
    private var ghost: String {
        guard !draft.isEmpty else { return "" }
        let matches = SortedBIP39Words.matches(prefix: draft, limit: 2)
        guard matches.count == 1, matches[0] != draft else { return "" }
        return String(matches[0].dropFirst(draft.count))
    }

    private enum ChipKind { case valid, invalid, typing }
    private struct ChipModel: Identifiable {
        let id: Int            // committed index, or -1 for the typing chip
        let display: Int       // 1-based number
        let word: String
        let kind: ChipKind
        let committedIndex: Int?
        let ghost: String
        let caret: Bool
    }

    /// The ordered chips: committed words (green / red) with the typing chip
    /// spliced in at `activeIndex` while focused.
    private var chips: [ChipModel] {
        var result: [ChipModel] = []
        var display = 1
        let cut = min(activeIndex, words.count)
        func appendCommitted(_ wi: Int) {
            let w = words[wi]
            result.append(ChipModel(
                id: wi, display: display, word: w,
                kind: BIP39Wordlist.english.contains(w) ? .valid : .invalid,
                committedIndex: wi, ghost: "", caret: false
            ))
            display += 1
        }
        for wi in 0..<cut { appendCommitted(wi) }
        if focused {
            result.append(ChipModel(
                id: -1, display: display, word: draft, kind: .typing,
                committedIndex: nil, ghost: ghost, caret: true
            ))
            display += 1
        }
        for wi in cut..<words.count { appendCommitted(wi) }
        return result
    }

    /// Drives the field-growth / chip animation.
    private var phraseSignature: String {
        "\(words.joined(separator: "|"))#\(activeIndex)#\(draft)#\(focused ? 1 : 0)"
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                phraseField
                if lengthValid, allReal {
                    validationLine.padding(.horizontal, 24)
                }
                hiddenField
            }
            .padding(.top, 10)
            // Forced LTR + English so chips fill 1→N and digits render ASCII
            // regardless of the app locale.
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.locale, Locale(identifier: "en"))
        }
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle("Recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingPassphraseSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text(
                    state.mnemonicPassphrase.isEmpty ? "Add passphrase" : "Edit passphrase"
                ))
            }
            // The ⋯ item is the zoom source — the modifier goes on the
            // ToolbarItem (CustomizableToolbarContent), not the inner Button.
            .matchedTransitionSource(id: passphraseZoomID, in: passphraseZoom)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear {
            if words.isEmpty, draft.isEmpty {
                let restored = state.mnemonicWords.filter { !$0.isEmpty }
                words = restored
                activeIndex = restored.count
                fieldText = sentinel
            }
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            // On blur, fold the in-progress word into `words` so it renders as a
            // committed chip (the typing chip only shows while focused).
            if !isFocused, !draft.isEmpty {
                insertCommitted(draft)
                draft = ""
                fieldText = sentinel
                state.mnemonicWords = phrase
            }
        }
        .uniHaptic(.success, trigger: canContinue)
        .fullScreenCover(isPresented: $isShowingScanner) {
            UniQRScannerSheet(
                title: "Scan recovery phrase",
                prompt: "Point your camera at a recovery-phrase QR code.",
                onRawDeliver: { scanned in
                    fillFromText(scanned)
                    isShowingScanner = false
                }
            )
            .uniAppEnvironment()
        }
        .sheet(isPresented: $isShowingPassphraseSheet) {
            PassphraseSheet(
                passphrase: $state.mnemonicPassphrase,
                onDismiss: { isShowingPassphraseSheet = false }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
            // Native iOS 26 zoom — the sheet morphs out of the ⋯ source above.
            .navigationTransition(.zoom(sourceID: passphraseZoomID, in: passphraseZoom))
        }
        .sheet(isPresented: $isShowingLeakedWarning) {
            LeakedSeedWarningSheet(
                kind: .mnemonic,
                onChooseDifferent: {
                    clearAll()
                    isShowingLeakedWarning = false
                    focused = true
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

    // MARK: Bottom bar (floating suggestions + Continue)

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // Custom white suggestion pills — float above the keyboard, NOT a
            // keyboard accessory; the row itself has no background.
            if focused, !draft.isEmpty, !suggestions.isEmpty {
                suggestionRow
            }
            GlassEffectContainer(spacing: UniSpacing.s) {
                UniButton(
                    title: isCommitting ? "Importing…" : "Import wallet",
                    variant: .primary,
                    isLoading: isCommitting,
                    isEnabled: canContinue && !isCommitting
                ) {
                    if isLeakedPhrase {
                        isShowingLeakedWarning = true
                    } else {
                        onContinue()
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, UniSpacing.l)
    }

    // MARK: Phrase field (chip flow)

    private var phraseField: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if chips.isEmpty {
                    Text("Tap to type or paste your recovery phrase…")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(UniColors.SeedGrid.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    FlowLayout(spacing: 9, lineSpacing: 9) {
                        ForEach(chips) { chip in
                            chipView(chip)
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : .scale(scale: 0.9).combined(with: .opacity)
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.top, 15)
            .padding(.horizontal, 24)
            .padding(.bottom, 58)
            .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)

            phraseUtilityButtons
                .padding(.trailing, 18)
                .padding(.bottom, 14)
        }
        .background(UniColors.Background.secondary)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: phraseSignature)
    }

    @ViewBuilder
    private func chipView(_ chip: ChipModel) -> some View {
        let isInvalid = chip.kind == .invalid
        let border: Color = {
            switch chip.kind {
            case .valid:   return UniColors.PinLock.positive
            case .invalid: return UniColors.Reset.danger
            case .typing:  return UniColors.Text.primary
            }
        }()
        HStack(spacing: 6) {
            Text(verbatim: "\(chip.display)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(isInvalid ? UniColors.Reset.danger : UniColors.SeedGrid.faint)
            HStack(spacing: 0) {
                Text(verbatim: chip.word)
                if !chip.ghost.isEmpty {
                    Text(verbatim: chip.ghost).foregroundStyle(UniColors.SeedGrid.faint)
                }
                if chip.caret { caret }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isInvalid ? UniColors.Reset.danger : UniColors.Text.primary)
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
        .background(chip.kind == .typing ? UniColors.Background.secondary : UniColors.SeedGrid.hairline)
        .overlay {
            Rectangle().strokeBorder(border, lineWidth: chip.kind == .typing ? 2 : 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let ci = chip.committedIndex { editWord(at: ci) }
        }
    }

    /// Blinking caret for the typing chip — deterministic via `TimelineView`.
    private var caret: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Rectangle()
                .fill(UniColors.Text.primary)
                .frame(width: 2, height: 17)
                .opacity(on ? 1 : 0)
                .padding(.leading, 1)
        }
    }

    // MARK: Field utility buttons

    private var phraseUtilityButtons: some View {
        HStack(spacing: 10) {
            phraseUtilityButton(
                systemImage: "doc.on.clipboard",
                accessibilityLabel: "Paste recovery phrase"
            ) {
                pasteFromClipboard()
            }
            phraseUtilityButton(
                systemImage: "qrcode.viewfinder",
                accessibilityLabel: "Scan recovery phrase"
            ) {
                UniHapticEngine.shared.play(.selection)
                isShowingScanner = true
            }
        }
    }

    /// Icon-only utility button that lives inside the phrase field.
    private func phraseUtilityButton(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 38, height: 38)
                .background(UniColors.SeedGrid.hairline.opacity(0.7), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    // MARK: Validation line

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
    }

    // MARK: Suggestion row (custom white pills, detached from keyboard)

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.element) { index, word in
                    suggestionPill(word, isPrimary: index == 0)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }

    /// Modern, flat suggestion card — solid surface, hairline, **no shadow**.
    /// The first (best) match reads as a filled accent chip; the rest are
    /// neutral surface chips.
    private func suggestionPill(_ word: String, isPrimary: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Button {
            UniHapticEngine.shared.play(.selection)
            commitSuggestion(word)
        } label: {
            Text(verbatim: word)
                .font(.system(size: 15, weight: isPrimary ? .semibold : .medium))
                .foregroundStyle(isPrimary ? UniColors.Button.primaryLabel : UniColors.Text.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(isPrimary ? UniColors.Button.Primary.tint : UniColors.Background.secondary, in: shape)
                .overlay {
                    if !isPrimary {
                        shape.strokeBorder(UniColors.SeedGrid.hairline, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Hidden input

    /// The near-invisible single-line field that holds `sentinel + draft` and
    /// drives the keyboard. Return fires `.onSubmit`; the sentinel lets us catch
    /// Backspace on an empty draft.
    private var hiddenField: some View {
        TextField("", text: $fieldText)
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.asciiCapable)
            .submitLabel(.next)
            .textContentType(.password)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .onChange(of: fieldText) { _, new in handleFieldChange(new) }
            .onSubmit { acceptGhostAndAdvance() }
    }

    // MARK: Input handling

    private func handleFieldChange(_ new: String) {
        guard new.hasPrefix(sentinel) else {
            // Sentinel deleted → Backspace on an empty draft: edit the
            // previous chip.
            backspaceOnEmpty()
            fieldText = sentinel + draft
            return
        }
        let raw = String(new.dropFirst(sentinel.count))
            .lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
        if raw.contains(where: { $0.isWhitespace }) {
            commitTokens(from: raw)
        } else if raw != draft {
            draft = raw
            fieldText = sentinel + raw
            syncState()
        }
    }

    /// Split a whitespace-bearing buffer into words: everything before the final
    /// separator commits; a trailing fragment (no closing space) stays the draft.
    private func commitTokens(from raw: String) {
        let endsWithSpace = raw.last?.isWhitespace ?? false
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let toCommit = endsWithSpace ? tokens : Array(tokens.dropLast())
        for word in toCommit { insertCommitted(word) }
        draft = endsWithSpace ? "" : (tokens.last ?? "")
        fieldText = sentinel + draft
        if !toCommit.isEmpty { UniHapticEngine.shared.play(.selection) }
        syncState()
    }

    /// Place `word` at the active slot, then return the cursor to the end.
    private func insertCommitted(_ word: String) {
        words.insert(word, at: min(activeIndex, words.count))
        activeIndex = words.count
    }

    /// Backspace on an empty draft pulls the previous committed word back into
    /// the draft so it can be re-edited.
    private func backspaceOnEmpty() {
        guard draft.isEmpty, activeIndex > 0 else { return }
        activeIndex -= 1
        draft = words.remove(at: activeIndex)
        syncState()
    }

    /// Accept the unique ghost completion (if any), commit the word, keep typing.
    private func acceptGhostAndAdvance() {
        if !draft.isEmpty {
            insertCommitted(draft + ghost)
            draft = ""
            fieldText = sentinel
            UniHapticEngine.shared.play(.selection)
            syncState()
        }
        // `.onSubmit` resigns first responder — re-focus to keep going.
        focused = true
    }

    private func commitSuggestion(_ word: String) {
        insertCommitted(word)
        draft = ""
        fieldText = sentinel
        syncState()
    }

    /// Remove the tapped word and drop the cursor on its slot to re-enter it.
    private func editWord(at index: Int) {
        var target = index
        // Don't lose an in-progress draft when switching slots.
        if !draft.isEmpty {
            let dropped = draft
            words.insert(dropped, at: min(activeIndex, words.count))
            if activeIndex <= target { target += 1 }
            draft = ""
        }
        guard words.indices.contains(target) else { return }
        words.remove(at: target)
        activeIndex = target
        fieldText = sentinel
        focused = true
        UniHapticEngine.shared.play(.selection)
        syncState()
    }

    private func pasteFromClipboard() {
        UniHapticEngine.shared.play(.selection)
        guard let clipboard = SafePasteboard.string, !clipboard.isEmpty else { return }
        fillFromText(clipboard)
    }

    /// Parse a mnemonic out of arbitrary text (clipboard or scan) and load it
    /// into the field. Prefers a clean BIP-39 subsequence when the source has
    /// surrounding text; otherwise loads the raw words so inline validation can
    /// flag the problem.
    private func fillFromText(_ raw: String) {
        let tokens = raw.lowercased().split { !$0.isLetter }.map(String.init)
        guard !tokens.isEmpty else { return }
        let bip = tokens.filter { BIP39Wordlist.english.contains($0) }
        let chosen: [String]
        if [12, 15, 18, 21, 24].contains(tokens.count) {
            chosen = tokens
        } else if [12, 15, 18, 21, 24].contains(bip.count) {
            chosen = bip
        } else {
            chosen = tokens
        }
        words = chosen
        draft = ""
        activeIndex = chosen.count
        fieldText = sentinel
        syncState()
        UniHapticEngine.shared.play(canContinue ? .success : .selection)
        if !canContinue { focused = true }
    }

    private func clearAll() {
        words = []
        draft = ""
        activeIndex = 0
        fieldText = sentinel
        state.mnemonicWords = []
    }

    /// Push the ordered phrase into shared state + arm the auto-dismiss.
    private func syncState() {
        state.mnemonicWords = phrase
        scheduleAutoDismiss()
    }

    /// Auto-dismiss the keyboard once the whole phrase validates, revealing the
    /// "Valid recovery phrase" line + Continue. Cancellable so a follow-on edit
    /// doesn't yank focus mid-type.
    private func scheduleAutoDismiss() {
        focusDismissTask?.cancel()
        guard canContinue, focused else { return }
        focusDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled else { return }
            focused = false
        }
    }
}

// MARK: - Flow layout (wrapping chips)

/// A minimal wrapping layout: lays subviews left→right, wrapping to a new line
/// when the next subview would overflow the proposed width. Used by the
/// recovery-phrase chip field.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 9
    var lineSpacing: CGFloat = 9

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        let width = maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
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
