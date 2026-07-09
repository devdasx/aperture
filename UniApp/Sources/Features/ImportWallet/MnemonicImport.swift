import SwiftUI

// MARK: - Mnemonic entry step

/// Recovery-phrase entry for imported wallets. The input is intentionally a
/// visible native SwiftUI `TextField(axis: .vertical)` instead of the older
/// hidden-field chip editor. The field accepts typed, pasted, or scanned BIP-39
/// words, then normalizes them only when a paste/scan/suggestion action is used.
struct MnemonicEntryView: View {
    @Bindable var state: ImportWalletState
    var isCommitting: Bool = false
    let onContinue: () -> Void

    @State private var phraseText: String = ""
    @FocusState private var phraseFocused: Bool
    @State private var focusDismissTask: Task<Void, Never>? = nil
    @State private var isShowingLeakedWarning = false
    @State private var isShowingPassphraseSheet = false
    @State private var isShowingScanner = false

    /// Drives the iOS 26 native **zoom** transition — the passphrase sheet
    /// scales out of the ⋯ toolbar button (`matchedTransitionSource` on the
    /// `ToolbarItem` ↔ `navigationTransition(.zoom)` on the sheet's root).
    @Namespace private var passphraseZoom
    private let passphraseZoomID = "passphrase"

    // MARK: Derived

    private var phrase: [String] {
        Self.mnemonicTokens(from: phraseText)
    }

    private var lengthValid: Bool {
        [12, 15, 18, 21, 24].contains(phrase.count)
    }

    private var allReal: Bool {
        !phrase.isEmpty && phrase.allSatisfy { BIP39Wordlist.english.contains($0) }
    }

    private var checksumValid: Bool {
        lengthValid && BIP39.validate(phrase)
    }

    private var canContinue: Bool { checksumValid }

    private var isLeakedPhrase: Bool {
        KnownLeakedSeeds.isLeaked(mnemonic: phrase)
    }

    private var currentDraft: String {
        Self.trailingToken(in: phraseText)
    }

    /// Up to 3 BIP-39 matches for the current word (the suggestion row).
    private var suggestions: [String] {
        SortedBIP39Words.matches(prefix: currentDraft, limit: 3)
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                phraseField
                if lengthValid, allReal {
                    validationLine.padding(.horizontal, 24)
                }
            }
            .padding(.top, 10)
            // BIP-39 English phrases should remain LTR regardless of app locale.
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
            .matchedTransitionSource(id: passphraseZoomID, in: passphraseZoom)
        }
        .uniBottomActionBar { bottomBar }
        .onAppear {
            if phraseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let restored = state.mnemonicWords.filter { !$0.isEmpty }
                phraseText = restored.joined(separator: " ")
            }
            syncState()
            DispatchQueue.main.async { phraseFocused = true }
        }
        .onChange(of: phraseText) { _, _ in
            syncState()
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
            .navigationTransition(.zoom(sourceID: passphraseZoomID, in: passphraseZoom))
        }
        .sheet(isPresented: $isShowingLeakedWarning) {
            LeakedSeedWarningSheet(
                kind: .mnemonic,
                onChooseDifferent: {
                    clearAll()
                    isShowingLeakedWarning = false
                    phraseFocused = true
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
            if phraseFocused, !currentDraft.isEmpty, !suggestions.isEmpty {
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
    }

    // MARK: Phrase field

    private var phraseField: some View {
        ZStack(alignment: .bottomTrailing) {
            TextField("Enter recovery phrase", text: $phraseText, axis: .vertical)
                .focused($phraseFocused)
                .textFieldStyle(.automatic)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.asciiCapable)
                .textContentType(.password)
                .submitLabel(.done)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Input.text)
                .tint(UniColors.Tint.accent)
                .lineLimit(4...8)
                .padding(.horizontal, UniSpacing.mPlus)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, 62)
                .frame(maxWidth: .infinity, minHeight: 166, alignment: .topLeading)
                .background(inputBackground)
                .privacySensitive()

            phraseUtilityButtons
                .padding(.trailing, UniSpacing.s)
                .padding(.bottom, UniSpacing.s)
        }
        .padding(.horizontal, 24)
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
            .fill(UniColors.Input.background)
            .overlay {
                RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
                    .stroke(
                        phraseFocused ? UniColors.Input.focusedBorder : UniColors.Input.border,
                        lineWidth: phraseFocused ? 1 : 0
                    )
            }
    }

    // MARK: Field utility buttons

    private var phraseUtilityButtons: some View {
        HStack(spacing: 8) {
            phraseUtilityButton(
                title: "Paste",
                systemImage: "doc.on.clipboard",
                accessibilityLabel: "Paste recovery phrase"
            ) {
                pasteFromClipboard()
            }

            phraseUtilityButton(
                title: "Scan",
                systemImage: "qrcode.viewfinder",
                accessibilityLabel: "Scan recovery phrase"
            ) {
                UniHapticEngine.shared.play(.selection)
                isShowingScanner = true
            }
        }
    }

    private func phraseUtilityButton(
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(UniColors.Text.primary)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(UniColors.Input.border.opacity(0.7), lineWidth: 1)
                }
                .contentShape(Capsule())
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

    // MARK: Suggestion row

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

    // MARK: Input handling

    private func commitSuggestion(_ word: String) {
        var tokens = phrase
        if !currentDraft.isEmpty, !tokens.isEmpty {
            tokens[tokens.count - 1] = word
        } else {
            tokens.append(word)
        }
        phraseText = tokens.joined(separator: " ") + " "
        phraseFocused = true
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
        let tokens = Self.mnemonicTokens(from: raw)
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
        phraseText = chosen.joined(separator: " ")
        syncState()
        UniHapticEngine.shared.play(canContinue ? .success : .selection)
        if !canContinue { phraseFocused = true }
    }

    private func clearAll() {
        phraseText = ""
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
        guard canContinue, phraseFocused else { return }
        focusDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled else { return }
            phraseFocused = false
        }
    }

    private static func mnemonicTokens(from text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
    }

    private static func trailingToken(in text: String) -> String {
        guard let last = text.last, last.isLetter else { return "" }
        return text.lowercased().split { !$0.isLetter }.last.map(String.init) ?? ""
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
