import SwiftUI
import UniformTypeIdentifiers
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

    /// Tap-to-reveal state (2026-06-20 redesign). The grid is blurred until
    /// the user taps; re-blurs on backgrounding and whenever the word count
    /// changes. Copy is locked until revealed.
    @State private var revealed: Bool = false

    /// Set when Copy is tapped before the phrase is revealed — flashes the
    /// button red + a "Tap to reveal first" hint, matching the Export flow.
    @State private var needsReveal: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                intro
                PhraseRevealGate(revealed: $revealed) {
                    PhraseGrid(words: state.words)
                }
                metaBlock
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
        .onChange(of: state.words) { _, _ in
            // Switching word count regenerates the phrase → re-blur + re-lock
            // Copy (handoff security note).
            revealed = false
        }
        .navigationTitle(Text("Recovery Phrase"))
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
            .uniSheetDetents([.large])
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

    private var intro: some View {
        Text("These words are your wallet. Write them in order, exactly as shown.")
            .font(UniTypography.body)
            .foregroundStyle(UniColors.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Meta (open source)

    /// "Open source. Learn more…" — gray caption + inline blue link
    /// (iOS 26 register). Opens the open-source verification sheet.
    private var metaBlock: some View {
        Button {
            UniHapticEngine.shared.play(.selection)
            isShowingOpenSource = true
        } label: {
            (
                Text("Open source. ").foregroundStyle(UniColors.Text.tertiary)
                + Text("Learn more…").foregroundStyle(UniColors.Button.text)
            )
            .font(UniTypography.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Open source. Learn more"))
        .accessibilityHint(Text("Opens a sheet describing how this recovery phrase was generated"))
    }

    // MARK: - Copy

    private func copyPhrase() {
        let phrase = state.words.joined(separator: " ")
#if canImport(UIKit)
        // `.expirationDate` tells iOS to auto-clear the pasteboard — the
        // only honest way to put a recovery phrase on the clipboard.
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: phrase]],
            options: [.expirationDate: Date().addingTimeInterval(20)]
        )
#endif
        UniHapticEngine.shared.play(.success)
        withAnimation(.easeOut(duration: 0.2)) { isShowingCopiedConfirmation = true }
        // Green "Copied" reverts after 1.8s (handoff); the clipboard still
        // expires on the OS-managed schedule.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeIn(duration: 0.25)) { isShowingCopiedConfirmation = false }
        }
    }

    // MARK: - Actions

    /// Footer: [Copy | Back up now] on one row, Skip for now full-width below.
    private var actionRegion: some View {
        VStack(spacing: UniSpacing.s) {
            if needsReveal {
                Text("Tap to reveal first")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Status.errorForeground)
            }
            HStack(spacing: UniSpacing.s) {
                copyButton
                UniButton(title: "Back up now", variant: .primary) {
                    onBackUpNow()
                }
                .frame(maxWidth: .infinity)
            }
            UniButton(title: "Skip for now", variant: .secondary) {
                onSkipForNow()
            }
        }
        .onChange(of: revealed) { _, isRevealed in
            if isRevealed { needsReveal = false }
        }
        .task(id: needsReveal) {
            guard needsReveal else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) { needsReveal = false }
            }
        }
    }

    /// Copy — the unified `.secondary` button, matching the Export flow's Copy
    /// exactly (2026-06-20 user direction): locked until the phrase is
    /// revealed; tapping it while blurred flashes it red (`.destructive`) with
    /// a "Tap to reveal first" hint and a warning haptic — it does NOT copy or
    /// auto-reveal. +4pt each side of breathing room.
    private var copyButton: some View {
        UniButton(
            title: isShowingCopiedConfirmation ? "Copied" : "Copy",
            variant: needsReveal ? .destructive : .secondary,
            systemImage: isShowingCopiedConfirmation ? "checkmark" : "doc.on.doc"
        ) {
            if revealed {
                copyPhrase()
            } else {
                UniHapticEngine.shared.play(.warning)
                withAnimation(.easeOut(duration: 0.2)) { needsReveal = true }
            }
        }
        .fixedSize()
        .padding(.horizontal, 4)
        .opacity(revealed || needsReveal ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: needsReveal)
        .animation(.easeInOut(duration: 0.2), value: isShowingCopiedConfirmation)
        .accessibilityLabel(Text("Copy recovery phrase"))
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
