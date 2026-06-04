import SwiftUI

/// Presented immediately after the user takes a screenshot of the
/// recovery-phrase view. Honest behaviour: the screenshot was already
/// taken — we cannot un-take it. Instead, the sheet names the risk and
/// offers the user a real way out (generate a new phrase, so the
/// screenshot is now of an invalidated wallet), or a deliberate accept
/// (keep the screenshot, with eyes open).
///
/// **Intent (one sentence):** the user just put their recovery phrase
/// somewhere risky — give them a one-tap escape that turns the leaked
/// phrase into nothing.
///
/// **Honesty (Rule #2 §A.7).**
/// - We name the actual risks (iCloud sync, photo library access by
///   anyone with the unlocked phone, Recents, Files app).
/// - We list real alternatives (paper, hardware key, metal stamping).
/// - We do not shame the user for the choice — "Keep my screenshot" is
///   a first-class CTA at full weight, not a tiny escape link.
///
/// **Sheet shape (Rule #15).** A `NavigationStack` wraps the content; the
/// title lives in `.navigationTitle("Screenshot detected")` with
/// `.navigationBarTitleDisplayMode(.large)` so the title compresses into
/// the nav bar as the user scrolls. The detent is `.large` — the body
/// paragraph plus three better-method rows deserves the room, and the
/// screenshot moment itself is high-stakes enough that the screen
/// shouldn't feel like a peek. A `ScrollView` survives here in case
/// Dynamic Type at `xxxLarge` pushes the content past the screen height.
///
/// **Material.** Per the same convention as `PassphraseSheet`, the
/// sheet's content background is the opaque system background
/// (`UniColors.Background.primary`) applied via
/// `.presentationBackground(...)` at the call site. The presenter
/// surrounds it with iOS 26's native sheet chrome (corner radius,
/// drag indicator, dim layer); we do not approximate that ourselves.
struct ScreenshotWarningSheet: View {
    /// The user wants to regenerate. The parent clears the passphrase
    /// and draws fresh entropy; the screenshot the user just took is
    /// now of a phrase that is no longer the wallet's.
    let onRegeneratePhrase: () -> Void

    /// The user accepts the risk and wants to keep the screenshot. The
    /// parent simply dismisses the sheet.
    let onKeepScreenshot: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    hero
                    bodyCopy
                    betterMethods
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.l)
            }
            .safeAreaInset(edge: .bottom) {
                actionRegion
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.bottom, UniSpacing.l)
            }
            .navigationTitle("Screenshot detected")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Hero

    /// A modest warning glyph — not an alarm triangle, not red. The
    /// user has not done something wrong; they have done something
    /// risky, which is a different thing.
    private var hero: some View {
        Image(systemName: "exclamationmark.shield.fill")
            .font(.system(size: 40, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Status.warningForeground)
            .accessibilityHidden(true)
    }

    // MARK: - Body copy

    private var bodyCopy: some View {
        UniBody(
            text: "Saving your recovery phrase as a screenshot is risky. Screenshots sync to iCloud, appear in your photo library and Recents, and can be read by anyone with your unlocked phone.",
            color: UniColors.Text.secondary
        )
    }

    // MARK: - Better methods card

    private var betterMethods: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniFeatureRow(
                    systemImage: "pencil.line",
                    title: "Write it on paper. Keep the paper offline."
                )
                UniDivider()
                UniFeatureRow(
                    systemImage: "lock.shield",
                    title: "Use a hardware security key."
                )
                UniDivider()
                UniFeatureRow(
                    systemImage: "creditcard.and.123",
                    title: "Stamp it into metal for fire and water survival."
                )
            }
        }
    }

    // MARK: - Actions

    /// Both CTAs sit in one `GlassEffectContainer` so they morph as one
    /// group on press (Liquid Glass §4 §B.5). "Generate new phrase" is
    /// primary because it is the *honest* recovery — the screenshot the
    /// user took is now harmless. "Keep current phrase" is secondary —
    /// the user keeps the current recovery phrase as it is and accepts
    /// the risk of the screenshot existing. The label names the *action*
    /// (what we keep) rather than the artifact (the screenshot).
    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            VStack(spacing: UniSpacing.s) {
                UniButton(title: "Generate new phrase", variant: .primary) {
                    onRegeneratePhrase()
                }
                UniButton(title: "Keep current phrase", variant: .secondary) {
                    onKeepScreenshot()
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ScreenshotWarningSheet(
                onRegeneratePhrase: {},
                onKeepScreenshot: {}
            )
            .presentationBackground(UniColors.Background.primary)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ScreenshotWarningSheet(
                onRegeneratePhrase: {},
                onKeepScreenshot: {}
            )
            .presentationBackground(UniColors.Background.primary)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}
