import SwiftUI

/// Optional BIP-39 passphrase entry. Presented over `RecoveryPhraseView`
/// from the toolbar's overflow menu.
///
/// **Intent (one sentence):** let the user add a memorised "25th word" to
/// their phrase, and be honest about the fact that we cannot recover it
/// for them.
///
/// **Honesty (Rule #2 §A.7).** The body copy states plainly that the
/// passphrase is **not stored anywhere** and **cannot be recovered**.
/// There is no "remember this device" affordance, no Keychain write — by
/// BIP-39 design the passphrase exists only in the user's head, and
/// combined with the mnemonic it produces a *different* wallet. We tell
/// them so.
///
/// **Native input + reveal toggle.** A trailing eye button toggles between
/// `SecureField` (masked dots, the iOS default for any password-like
/// field) and `TextField` (plain text, when the user actively asks to
/// see what they wrote). Both forms share the same content-type and
/// autocapitalization settings so the keyboard does not change underneath
/// the user when they reveal. iOS's saved-passwords prompt is suppressed
/// via `.textContentType(.newPassword)` rather than `.password` — this is
/// a wallet passphrase, not a login.
///
/// **Sheet shape (Rule #15).** A `NavigationStack` wraps the content; the
/// title lives in `.navigationTitle("Optional passphrase")` with
/// `.navigationBarTitleDisplayMode(.inline)` to match the `.medium`
/// detent. Cancel sits at `topBarLeading`, Save at `topBarTrailing`, both
/// as native nav-bar text buttons — the same geometry Apple's Mail compose
/// uses. No `ScrollView`: the body, the input, and the footnote fit the
/// medium detent on every device.
///
/// **Material.** The sheet's content background is the opaque system
/// background (`UniColors.Background.primary`) applied via
/// `.presentationBackground(...)` at the call site — solid surface, no
/// see-through onto the recovery-phrase view behind. iOS 26's native
/// sheet still owns the outer corner radius and drag indicator.
struct PassphraseSheet: View {
    /// Two-way binding to the parent's in-memory passphrase. Initialised
    /// from a buffer so the user can Cancel without committing to changes.
    @Binding var passphrase: String

    /// Dismissal handler — Cancel and Save both call it (Save first
    /// commits `buffer` to `passphrase`).
    let onDismiss: () -> Void

    /// Local editing buffer. Initialised from the bound passphrase on
    /// appear so Cancel discards in-flight edits without touching the
    /// parent's state. `UniTextField` owns its own reveal state + focus
    /// binding, so no per-sheet `isRevealed` / `isFieldFocused` is needed.
    @State private var buffer: String = ""

    var body: some View {
        UniSheet(title: "Optional passphrase") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                bodyCopy
                input
                footnoteLine
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Save", variant: .primary) {
                        passphrase = buffer
                        onDismiss()
                    }
                    UniButton(title: "Cancel", variant: .secondary) {
                        onDismiss()
                    }
                }
            }
        }
        .onAppear {
            buffer = passphrase
        }
    }

    // MARK: - Hero

    /// Rule #16 §A.1 — a single quiet `key.viewfinder` glyph in
    /// `UniColors.Brand.mark` (graphite/soft-white). The size is
    /// restrained for the `.medium` detent — 40pt sits above the body
    /// without competing with the inline nav title or pushing the
    /// input below the fold. The symbol carries the meaning of the
    /// surface (an extra key, scrutinized) without alarm.
    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "key.viewfinder")
                .font(.system(size: 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    // MARK: - Body copy

    /// The title now lives in the nav bar; the body paragraph stays as the
    /// honest framing of what the passphrase is and what we cannot do
    /// for the user.
    private var bodyCopy: some View {
        UniBody(
            text: "An optional extra word that combines with your recovery phrase to create a different wallet. You must remember it — it is not stored anywhere, and it cannot be recovered.",
            color: UniColors.Text.secondary
        )
    }

    // MARK: - Input

    /// Passphrase input — `UniTextField` with the secure-reveal toggle
    /// baked in. Direction is `.automatic` because a passphrase may be
    /// any script the user remembers (Arabic, Hebrew, Latin, mixed).
    private var input: some View {
        UniTextField(
            placeholder: "Passphrase (optional)",
            text: $buffer,
            directionPolicy: .automatic,
            isSecure: true,
            showsRevealToggle: true,
            contentType: .newPassword
        )
    }

    private var footnoteLine: some View {
        UniFootnote(
            text: "You can leave this empty.",
            alignment: .leading
        )
    }
}

// MARK: - Previews

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PassphraseSheet(passphrase: .constant(""), onDismiss: {})
                .presentationBackground(UniColors.Background.primary)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PassphraseSheet(passphrase: .constant(""), onDismiss: {})
                .presentationBackground(UniColors.Background.primary)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}
