import SwiftUI

// MARK: - Mnemonic entry step — single chip-flow field (design_handoff_import_flows)

/// Recovery-phrase entry, rebuilt to the updated import-flows handoff: a
/// **single flat, full-width, square phrase field** that fills with **square
/// word chips** as the user types — no per-word grid, no 12/24 control, no
/// Paste button.
///
/// - One edge-to-edge `--surface` field (0 corner radius, no shadow) whose
///   height grows as chips wrap to new lines.
/// - Each committed word is a square chip: a faint index number + the word,
///   with a **green** 1.5px border (valid BIP-39 word) or **red** (not in the
///   list, + red text). The **current** word is the `typing` chip — a 2px ink
///   border, a blinking caret, and the gray inline **ghost** completion (shown
///   only when the prefix uniquely matches one BIP-39 word).
/// - **Length is auto-detected** — any valid BIP-39 length (12 / 15 / 18 / 21 /
///   24) validates against its own checksum; nothing for the user to pick.
/// - A **BIP-39 suggestion bar** sits above the keyboard; the app-bar **⋯**
///   opens the optional passphrase sheet.
///
/// All validation is real: `BIP39Wordlist` membership per word, `BIP39.validate`
/// checksum for the whole phrase, and the `KnownLeakedSeeds` blocklist.
struct MnemonicEntryView: View {
    @Bindable var state: ImportWalletState
    let onContinue: () -> Void

    /// The full phrase as typed — one space-separated string driving the hidden
    /// field. The chips are derived from it.
    @State private var text: String = ""
    @FocusState private var focused: Bool

    @State private var focusDismissTask: Task<Void, Never>? = nil
    @State private var isShowingLeakedWarning: Bool = false
    @State private var isShowingPassphraseSheet: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Derived

    /// Lowercased words parsed from the field (the last one may be in-progress).
    private var words: [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    /// The in-progress (current) word — the trailing token when the field does
    /// not end on whitespace.
    private var currentWord: String {
        guard let last = text.last, !last.isWhitespace else { return "" }
        return words.last ?? ""
    }

    private var lengthValid: Bool { [12, 15, 18, 21, 24].contains(words.count) }

    private var allReal: Bool {
        !words.isEmpty && words.allSatisfy { BIP39Wordlist.english.contains($0) }
    }

    private var checksumValid: Bool { lengthValid && BIP39.validate(words) }
    private var canContinue: Bool { checksumValid }
    private var isLeakedPhrase: Bool { KnownLeakedSeeds.isLeaked(mnemonic: words) }

    /// Up to 3 BIP-39 matches for the current word (the suggestion bar).
    private var suggestions: [String] {
        SortedBIP39Words.matches(prefix: currentWord, limit: 3)
    }

    /// The inline ghost completion — the remainder of the unique BIP-39 word
    /// the current word prefixes, or `""` when empty / ambiguous / complete.
    private var ghost: String {
        let prefix = currentWord
        guard !prefix.isEmpty else { return "" }
        let matches = SortedBIP39Words.matches(prefix: prefix, limit: 2)
        guard matches.count == 1, matches[0] != prefix else { return "" }
        return String(matches[0].dropFirst(prefix.count))
    }

    private enum ChipStatus { case valid, invalid, typing }
    private struct ChipModel: Identifiable {
        let id: Int          // 0-based slot
        let word: String
        let status: ChipStatus
        let ghost: String
        let caret: Bool
    }

    /// The chips to render: committed words (green / red) + the current typing
    /// chip while the field is focused.
    private var chips: [ChipModel] {
        var result: [ChipModel] = []
        let cw = currentWord
        let committed = focused ? (cw.isEmpty ? words : Array(words.dropLast())) : words
        for (i, w) in committed.enumerated() {
            result.append(ChipModel(
                id: i, word: w,
                status: BIP39Wordlist.english.contains(w) ? .valid : .invalid,
                ghost: "", caret: false
            ))
        }
        if focused {
            result.append(ChipModel(
                id: committed.count, word: cw, status: .typing, ghost: ghost, caret: true
            ))
        }
        return result
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    phraseField
                    if lengthValid, allReal {
                        validationLine.padding(.horizontal, 24)
                    }
                    hiddenField
                }
                .padding(.top, 10)
                // Forced LTR + English so the chips fill 1→N and digits render
                // ASCII regardless of the app's locale.
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
                    Image(systemName: "ellipsis")
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
        .onAppear {
            if text.isEmpty {
                text = state.mnemonicWords.filter { !$0.isEmpty }.joined(separator: " ")
            }
            focused = true
        }
        .onChange(of: text) { _, newValue in handleTextChange(newValue) }
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
                    text = ""
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

    // MARK: Phrase field (chip flow)

    private var phraseField: some View {
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
        .padding(.vertical, 15)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
        .background(UniColors.Background.secondary)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: text)
    }

    @ViewBuilder
    private func chipView(_ chip: ChipModel) -> some View {
        let isInvalid = chip.status == .invalid
        let border: Color = {
            switch chip.status {
            case .valid:   return UniColors.PinLock.positive
            case .invalid: return UniColors.Reset.danger
            case .typing:  return UniColors.Text.primary
            }
        }()
        HStack(spacing: 6) {
            Text(verbatim: "\(chip.id + 1)")
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
        .background(chip.status == .typing ? UniColors.Background.secondary : UniColors.SeedGrid.hairline)
        .overlay {
            Rectangle().strokeBorder(border, lineWidth: chip.status == .typing ? 2 : 1.5)
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

    // MARK: Suggestion bar (keyboard accessory)

    @ViewBuilder
    private var suggestionBar: some View {
        if focused, !currentWord.isEmpty, !suggestions.isEmpty {
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

    /// The near-invisible field that holds the phrase text and drives the
    /// system keyboard. The chip field is the visible surface; the system paste
    /// menu / keyboard fills this directly (no Paste button needed).
    private var hiddenField: some View {
        TextField("", text: $text, axis: .vertical)
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.asciiCapable)
            .submitLabel(.next)
            .textContentType(.password)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .onSubmit { acceptGhostAndAdvance() }
    }

    // MARK: Input handling

    private func handleTextChange(_ raw: String) {
        // A newline (Return / pasted line break) accepts the ghost + advances.
        if raw.contains(where: \.isNewline) {
            text = raw.filter { !$0.isNewline }
            acceptGhostAndAdvance()
            return
        }
        // Normalize: lowercase, keep letters + whitespace only.
        let cleaned = raw.lowercased().filter { $0.isLetter || $0.isWhitespace }
        if cleaned != raw {
            text = cleaned
            return
        }
        state.mnemonicWords = words
        if BIP39Wordlist.english.contains(currentWord) {
            // A complete valid word just resolved (e.g. via space or full type).
            UniHapticEngine.shared.play(.selection)
        }
        scheduleAutoDismiss()
    }

    /// Accept the unique ghost completion for the current word (if any), commit
    /// it with a trailing space, and keep the keyboard up for the next word.
    private func acceptGhostAndAdvance() {
        let cw = currentWord
        if !cw.isEmpty, !ghost.isEmpty {
            text = String(text.dropLast(cw.count)) + cw + ghost + " "
            UniHapticEngine.shared.play(.selection)
        } else if !cw.isEmpty {
            text += " "
        }
        // `.onSubmit` resigns first responder — re-focus so the user keeps typing.
        focused = true
    }

    private func commitSuggestion(_ word: String) {
        let cw = currentWord
        if cw.isEmpty {
            text += word + " "
        } else {
            text = String(text.dropLast(cw.count)) + word + " "
        }
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
