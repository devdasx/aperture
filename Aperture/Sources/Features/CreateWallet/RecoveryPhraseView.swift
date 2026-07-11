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
/// save them (copy with auto-expiring clipboard), then continue into
/// passcode setup.
///
/// **Layout.**
/// - Top hero: a small `key.fill` mark in `UniColors.Brand.mark`, plus a
///   single line of honest framing copy.
/// - A 2-column `LazyVGrid` of word cells (12 or 24 depending on user
///   preference). The grouped phrase surface uses `UniColors.SeedGrid.surface`
///   with a 2-digit position badge in
///   `UniColors.Text.tertiary` and the word in body-emphasized weight.
///   Non-interactive: no tap, no copy menu.
/// - A centered plain text `Copy` action directly below the grid. Tap copies
///   the phrase to `UIPasteboard.general` with a short `.expirationDate` so
///   the system auto-clears it.
/// - One bottom CTA: Continue.
///
/// **Toolbar.** Leading: a bare inline `xmark` glyph (no glass pill —
/// per the iOS 26 navigation-bar pattern for a sheet-style close).
/// Trailing: an overflow `Menu` rendered as a bare `ellipsis` glyph (no
/// `.circle` chrome — see `MISTAKES.md` M-003) containing the word-count
/// picker and the passphrase action.
struct RecoveryPhraseView: View {
    /// Shared flow state — owns the mnemonic, the word-count preference,
    /// and the optional passphrase. The view binds to it via `@Bindable`
    /// so the toolbar's `Picker` writes through cleanly.
    @Bindable var state: CreateWalletState

    /// Fires when the user taps the close (xmark) button. The caller
    /// dismisses the parent `fullScreenCover`.
    let onClose: () -> Void
    /// Fires when the user taps Continue. Caller routes to passcode setup
    /// or the wallet-ready screen, depending on existing security state.
    let onContinue: () -> Void

    /// Root presentations show a close glyph so the user can dismiss the
    /// slide-up flow.
    var showsCloseButton: Bool = true

    /// Toggle for the passphrase sheet. Local state — the sheet does not
    /// need to survive a `.id`-driven rebuild because it is incidental
    /// to the flow.
    @State private var isShowingPassphraseSheet: Bool = false

    /// Toggle for the "Roll your own" entropy sheet (user-supplied
    /// dice / coin / hex entropy). Local state — the sheet is
    /// self-contained and commits its result to `state.words` on
    /// success.
    @State private var isShowingRollYourOwn: Bool = false

    /// Visible iff the user just tapped Copy. Auto-clears after a short
    /// delay so the confirmation does not linger.
    @State private var isShowingCopiedConfirmation: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                intro
                    .padding(.bottom, UniSpacing.l)
                PhraseGrid(words: state.words)
                copyTextButton
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.l)
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .uniBottomActionBar {
            actionRegion
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.s)
        }
        .navigationTitle(Text("Recovery Phrase"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    closeButton
                }
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
            .apertureEnvironment()
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
            .apertureEnvironment()
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .uniHapticSignature(.phraseRevealed, trigger: state.words.joined())
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

    // MARK: - Copy

    private func copyPhrase() {
        let phrase = state.words.joined(separator: " ")
#if canImport(UIKit)
        // `.expirationDate` tells iOS to auto-clear the pasteboard — the
        // only honest way to put a recovery phrase on the clipboard.
        SafePasteboard.setItems(
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

    /// Bottom CTA. Copy lives directly under the phrase grid as a text
    /// action, so the bottom stays focused on forward progress.
    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(title: "Continue", variant: .primary) {
                onContinue()
            }
            .frame(height: 47)
        }
    }

    /// Copy as plain text under the phrase grid. It deliberately avoids the
    /// unified glass button treatment so the only heavy CTA on this screen is
    /// Continue.
    private var copyTextButton: some View {
        Button {
            copyPhrase()
        } label: {
            Text(isShowingCopiedConfirmation ? "Copied" : "Copy")
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(
                    isShowingCopiedConfirmation
                        ? UniColors.Feedback.Success.foreground
                        : UniColors.Button.text
                )
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            onContinue: {}
        )
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        RecoveryPhraseView(
            state: CreateWalletState(),
            onClose: {},
            onContinue: {}
        )
    }
    .preferredColorScheme(.dark)
}
