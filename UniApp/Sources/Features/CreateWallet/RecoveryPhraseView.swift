import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The single most important screen in the entire app: the moment the user
/// sees the words that *are* their wallet.
///
/// **Intent (one sentence):** present the words clearly, with the
/// appropriate weight of consequence, give the user every honest tool to
/// save them (copy with auto-expiring clipboard, screenshot-warning sheet
/// with a regenerate-the-phrase escape hatch), and offer the two paths
/// out — back up now, or skip with eyes open.
///
/// **Layout.**
/// - Top hero: a small `key.fill` mark in `UniColors.Brand.mark`, plus a
///   single line of honest framing copy.
/// - A 2-column `LazyVGrid` of word cells (12 or 24 depending on user
///   preference). Each cell is a flat `UniColors.Background.secondary`
///   surface (`UniRadius.m`) with a 2-digit position badge in
///   `UniColors.Text.tertiary` and the word in body-emphasized weight.
///   Non-interactive: no tap, no copy menu.
/// - A subtle `Copy` button below the grid. Tap copies the phrase to
///   `UIPasteboard.general` with a 60-second `.expirationDate` so the
///   system auto-clears it; a transient `UniFootnote` confirms and names
///   the expiry.
/// - A short footnote reminding the user the phrase will not be shown
///   again, plus a hint that switching word counts replaces the phrase.
/// - Two CTAs in one `GlassEffectContainer` at the bottom: primary
///   "Back up now" and secondary "Skip for now".
///
/// **Toolbar.** Leading: a bare inline `xmark` glyph (no glass pill —
/// per the iOS 26 navigation-bar pattern for a sheet-style close).
/// Trailing: an overflow `Menu` rendered as a bare `ellipsis` glyph (no
/// `.circle` chrome — see `MISTAKES.md` M-003) containing the word-count
/// picker and the passphrase action.
///
/// **Screenshot policy.** The view does **not** blank the words when a
/// screenshot fires. Honest behaviour: the screenshot succeeds, and an
/// immediate sheet warns about the risks (cloud sync, photo library,
/// unlocked-phone access) plus offers two ways forward — regenerate the
/// phrase (the screenshot is now of an invalidated wallet) or keep the
/// screenshot (the user knows what they're doing).
struct RecoveryPhraseView: View {
    /// Shared flow state — owns the mnemonic, the word-count preference,
    /// and the optional passphrase. The view binds to it via `@Bindable`
    /// so the toolbar's `Picker` writes through cleanly.
    @Bindable var state: CreateWalletState

    /// Fires when the user taps the close (xmark) button. The caller
    /// dismisses the parent `fullScreenCover`.
    let onClose: () -> Void
    /// Fires when the user taps "Back up now". Caller routes to the
    /// backup flow (T-015 — currently a `RecoveryPhraseDestination.verify`
    /// push).
    let onBackUpNow: () -> Void
    /// Fires when the user taps "Skip for now". The caller presents
    /// `SkipBackupWarningSheet`.
    let onSkipForNow: () -> Void

    /// Toggle for the passphrase sheet. Local state — the sheet does not
    /// need to survive a `.id`-driven rebuild because it is incidental
    /// to the flow.
    @State private var isShowingPassphraseSheet: Bool = false

    /// Toggle for the screenshot-warning sheet. Set to `true` from the
    /// `UIApplication.userDidTakeScreenshotNotification` publisher; the
    /// sheet itself decides what happens next.
    @State private var isShowingScreenshotWarning: Bool = false

    /// Toggle for the "Roll your own" entropy sheet (user-supplied
    /// dice / coin / hex entropy). Local state — the sheet is
    /// self-contained and commits its result to `state.words` on
    /// success.
    @State private var isShowingRollYourOwn: Bool = false

    /// Tracks whether this view is currently the topmost (visible) view
    /// in the navigation stack. The screenshot notification is global —
    /// `.onReceive` keeps firing even when `RecoveryPhraseView` has been
    /// pushed-onto (e.g., the user is in `BackupVerifyView` or
    /// `PinSetupFlow`). Without this gate, taking a screenshot in PIN
    /// setup would surface the recovery-phrase regenerate warning, which
    /// is wrong: the sensitive surface is only visible HERE, so only
    /// here should the warning fire. Toggled by `.onAppear` /
    /// `.onDisappear`, which fire on push/pop in `NavigationStack`.
    @State private var isVisible: Bool = false

    /// Toggle for the open-source verification sheet (Rule #16 §A.4).
    /// Anchored to this surface because the recovery-phrase view is
    /// the most consequential security moment in the app — the user
    /// must be able to audit *here* how the words on screen were
    /// generated.
    @State private var isShowingOpenSource: Bool = false

    /// Visible iff the user just tapped Copy. Auto-clears after a short
    /// delay so the confirmation does not linger.
    @State private var isShowingCopiedConfirmation: Bool = false

    /// Trigger counter for the copy-success haptic. Incremented on each
    /// successful copy so `.uniHaptic` observes a change and fires.
    @State private var copyTickCount: Int = 0

    /// Two equal-width columns for the word grid. `UniSpacing.s` gap
    /// between cells reads as group-internal, not section-internal.
    private let gridColumns: [GridItem] = [
        GridItem(.flexible(), spacing: UniSpacing.s),
        GridItem(.flexible(), spacing: UniSpacing.s)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                wordGrid
                copyRow
                footnoteBlock
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
        .navigationTitle(Text("Your recovery phrase"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                closeButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                optionsMenu
            }
        }
        .sheet(isPresented: $isShowingPassphraseSheet) {
            PassphraseSheet(
                passphrase: $state.passphrase,
                onDismiss: { isShowingPassphraseSheet = false }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingOpenSource) {
            OpenSourceSheet()
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingScreenshotWarning) {
            ScreenshotWarningSheet(
                onRegeneratePhrase: {
                    // The screenshot just taken is now of a phrase that
                    // is no longer the wallet's. New entropy, new words.
                    // The passphrase is also cleared so the user starts
                    // from scratch — anything else would be dishonest.
                    state.passphrase = ""
                    state.regenerate()
                    isShowingScreenshotWarning = false
                },
                onKeepScreenshot: {
                    isShowingScreenshotWarning = false
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingRollYourOwn) {
            // Per the jony-ive 2026-06-05 audit: this is a navigation
            // experience (NavigationStack-rooted, three screens) — same
            // family member as the Settings sheet, so the same
            // presentation modifiers apply. NOT intrinsicHeightSheet —
            // that's for content-card sheets (warning sheets, etc.).
            RollYourOwnSheet(
                state: state,
                onDismiss: { isShowingRollYourOwn = false }
            )
            .uniAppEnvironment()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .uniHapticSignature(.phraseRevealed, trigger: state.words.joined())
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.userDidTakeScreenshotNotification
            )
        ) { _ in
            // Only fire when the recovery-phrase view is actually on
            // screen. If the user has navigated forward (BackupVerify,
            // PinSetup) or backward (closed the cover), a screenshot
            // taken elsewhere should NOT surface this sheet — the
            // sensitive content (the 12/24 words) is no longer visible.
            guard isVisible else { return }
            isShowingScreenshotWarning = true
        }
    }

    // MARK: - Toolbar leading: bare X (no glass pill — see MISTAKES.md M-002)

    /// Inline `xmark` glyph — no fill, no background pill, no
    /// `.buttonStyle(.glass)`. The iOS 26 nav-bar pattern for a
    /// sheet/cover close lets the bare symbol inherit the nav-bar tint.
    /// See `MISTAKES.md` M-002 for the full rationale.
    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
        }
        .accessibilityLabel(Text("Close"))
    }

    // MARK: - Toolbar trailing: overflow menu (bare ellipsis — see MISTAKES.md M-003)

    /// Native `Menu` opened from a bare `ellipsis` glyph — three dots, no
    /// `.circle` chrome (`MISTAKES.md` M-003). Houses the word-count
    /// `Picker` and the passphrase entry point. Inherits the nav-bar
    /// tint like every other iOS 26 toolbar item.
    private var optionsMenu: some View {
        Menu {
            Section {
                Picker(selection: $state.wordCount) {
                    Text("12 words").tag(BIP39WordCount.twelve)
                    Text("24 words").tag(BIP39WordCount.twentyFour)
                } label: {
                    Text("Word count")
                }
            }

            Section {
                Button {
                    isShowingPassphraseSheet = true
                } label: {
                    if state.passphrase.isEmpty {
                        Label("Add passphrase", systemImage: "key.viewfinder")
                    } else {
                        Label("Edit passphrase", systemImage: "key.viewfinder")
                    }
                }
            }

            Section {
                Button {
                    isShowingRollYourOwn = true
                } label: {
                    Label("Roll your own…", systemImage: "dice")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
        }
        .accessibilityLabel(Text("Options"))
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: UniSpacing.s) {
            Image(systemName: "key.fill")
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .accessibilityHidden(true)

            UniHeadline(
                text: "These words are your wallet. Write them in order, exactly as shown.",
                alignment: .leading
            )
        }
    }

    // MARK: - Word grid

    private var wordGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: UniSpacing.s) {
            ForEach(Array(state.words.enumerated()), id: \.offset) { index, word in
                WordCell(position: index + 1, word: word)
            }
        }
        // Force LTR per Rule #11 §C "English-only display content"
        // exception. A recovery phrase has a STRICT ordinal sequence —
        // position 1 → 2 → 3 → ... → 12 must read left-to-right,
        // top-to-bottom regardless of the app's locale. In RTL the
        // default would flip the grid (position 1 to top-right, 2 to
        // top-left) which silently inverts the reading order and
        // causes users to write the phrase down wrong. The words
        // themselves are English BIP-39 entries (universally LTR);
        // the surrounding chrome (title, body copy, toolbar items)
        // stays in the ambient direction so the screen still reads
        // as Arabic / Hebrew where appropriate.
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Copy row

    /// A subtle tertiary text button beneath the grid. Tap copies the
    /// phrase to the system pasteboard with a 60-second `.expirationDate`
    /// — iOS auto-clears the clipboard at that point so a forgotten copy
    /// does not sit in the user's paste history indefinitely. A brief
    /// inline footnote confirms the copy and names the expiry. No emoji,
    /// no exclamation, no marketing softening (Rule #2 §A.7 — honest copy).
    private var copyRow: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Button {
                copyPhrase()
            } label: {
                Label {
                    Text("Copy")
                        .font(UniTypography.bodyEmphasized)
                } icon: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15, weight: .regular))
                }
                .foregroundStyle(UniColors.Button.tertiaryLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Copy recovery phrase"))
            .uniHaptic(.success, trigger: copyTickCount)

            if isShowingCopiedConfirmation {
                UniFootnote(
                    text: "Copied. The clipboard clears in 60 seconds.",
                    alignment: .leading
                )
                .transition(.opacity)
            }
        }
    }

    private func copyPhrase() {
        let phrase = state.words.joined(separator: " ")
#if canImport(UIKit)
        // `setItems(_:options:)` with `.expirationDate` instructs iOS to
        // clear the pasteboard automatically at the given date — the only
        // honest way to put a recovery phrase on the clipboard.
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: phrase]],
            options: [.expirationDate: Date().addingTimeInterval(60)]
        )
#endif
        copyTickCount &+= 1
        withAnimation(.easeOut(duration: 0.2)) {
            isShowingCopiedConfirmation = true
        }
        // Auto-dismiss the inline confirmation after ~2 s so it doesn't
        // linger. The clipboard still expires on the OS-managed schedule.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeIn(duration: 0.25)) {
                isShowingCopiedConfirmation = false
            }
        }
    }

    // MARK: - Footnote block

    /// One line of guidance plus the open-source verification anchor.
    /// The "Aperture cannot show this phrase again" line was REMOVED
    /// per user direction — the user can re-open the recovery phrase
    /// later via Settings (T-016 "Back up your recovery phrase"). Per
    /// Rule #2 §A.7 (honesty), a wallet that CAN show the phrase later
    /// must not claim otherwise.
    ///
    /// Rule #16 §A.4 — the most consequential security surface in the
    /// app carries its own open-source badge so the user can verify,
    /// at the moment of seeing their words, exactly how those words
    /// were generated.
    private var footnoteBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniFootnote(
                text: "Changing word count generates a new phrase.",
                alignment: .leading
            )

            openSourceBadge
        }
    }

    /// Restrained tappable badge — same visual register as the welcome
    /// slide's anchor: `lock.shield` glyph, "Open source" footnote
    /// text, trailing chevron. All `UniColors.Text.tertiary` so the
    /// affordance reads as honest footnote, not marketing banner.
    private var openSourceBadge: some View {
        Button {
            isShowingOpenSource = true
        } label: {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .regular))
                Text("Open source")
                    .font(UniTypography.footnote)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(UniColors.Text.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Open source"))
        .accessibilityHint(Text("Opens a sheet describing how this recovery phrase was generated"))
    }

    // MARK: - Actions

    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            VStack(spacing: UniSpacing.s) {
                UniButton(title: "Back up now", variant: .primary) {
                    onBackUpNow()
                }
                UniButton(title: "Skip for now", variant: .secondary) {
                    onSkipForNow()
                }
            }
        }
    }
}

// MARK: - Word cell

/// A single cell in the word grid. Non-interactive by design: the user
/// reads and writes; they do not tap, copy, or share. The position badge
/// uses 2-digit zero-padded Western numerals (`01`, `02`, …) — these are
/// data, not localized copy, so they render as `Text(verbatim:)`.
private struct WordCell: View {
    let position: Int
    let word: String

    private var positionLabel: String {
        String(format: "%02d", position)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            Text(verbatim: positionLabel)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .monospacedDigit()

            Text(verbatim: word)
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.s)
        .padding(.vertical, UniSpacing.s)
        .background(
            // `Material.card` (white in light, near-black in dark)
            // not `Background.secondary` — the cell IS a card on
            // top of the page, so it has to read as one card-step
            // above the page color. The pre-color-flip code (using
            // `Background.secondary`) happened to land on a similar
            // gray value for both tokens, masking the mis-naming;
            // the 2026-06-07 flip to the iOS Settings register
            // exposed it (the cells disappeared into the page on
            // light mode). Rule #4-honest fix.
            RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                .fill(UniColors.Material.card)
        )
        // VoiceOver reads "01, abandon" not the styled stacked layout.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(position), \(word)"))
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        RecoveryPhraseView(
            state: CreateWalletState(),
            onClose: {},
            onBackUpNow: {},
            onSkipForNow: {}
        )
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        RecoveryPhraseView(
            state: CreateWalletState(),
            onClose: {},
            onBackUpNow: {},
            onSkipForNow: {}
        )
    }
    .preferredColorScheme(.dark)
}
