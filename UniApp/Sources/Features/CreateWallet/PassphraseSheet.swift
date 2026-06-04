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
    /// parent's state.
    @State private var buffer: String = ""

    /// `true` while the user has tapped the eye to reveal the passphrase
    /// in plain text. Defaults to masked — the privacy-aware default for
    /// any password-like field.
    @State private var isRevealed: Bool = false

    /// Field focus binding so the keyboard stays attached when the user
    /// toggles reveal — iOS would otherwise drop focus on the
    /// `SecureField → TextField` swap because the view identity changes.
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                bodyCopy
                input
                footnoteLine
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .navigationTitle("Optional passphrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        passphrase = buffer
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            buffer = passphrase
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

    /// Masked or plain text field plus a trailing eye toggle, both
    /// hosted inside a single rounded surface so the row reads as one
    /// input. `.trailing` padding inside the text field reserves room
    /// for the eye button so the typed text never slides under it.
    private var input: some View {
        ZStack(alignment: .trailing) {
            Group {
                if isRevealed {
                    TextField("Passphrase (optional)", text: $buffer)
                        .focused($isFieldFocused)
                } else {
                    SecureField("Passphrase (optional)", text: $buffer)
                        .focused($isFieldFocused)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .textContentType(.newPassword)
            .font(UniTypography.body)
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.s)
            .padding(.trailing, 36) // room for the eye button
            .background(
                RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                    .fill(UniColors.Background.secondary)
            )

            Button {
                isRevealed.toggle()
                // Preserve focus across the SecureField ↔ TextField swap.
                // Without this, the keyboard briefly dismisses on toggle.
                isFieldFocused = true
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .padding(.horizontal, UniSpacing.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(isRevealed ? "Hide passphrase" : "Show passphrase")
            )
        }
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
