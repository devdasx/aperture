import SwiftUI

/// The "Smart" URL field at the top of `BrowserHomeView` — the
/// browser's primary affordance. Mirrors iOS Safari's start-page
/// hero search field: large, glass-effect Capsule, full-bleed
/// inside the horizontal page padding, leading SF Symbol, the
/// `.search` submit-label native keyboard return key.
///
/// **Why a dedicated primitive.** The wallet's search field in
/// `WalletHomeView` is `.searchable(text:)` (Rule #14 — system
/// placement, system chrome). The browser's start-page field
/// occupies a fundamentally different role: it's not a filter over
/// a visible list, it's the user's typing surface for "where do
/// you want to go." Rule #14 explicitly carves out search affordances
/// as the system-owned shape; the browser's commit-to-URL surface
/// is a different affordance class. Apple's Safari, Chrome, and
/// every other browser ship a custom hero field for the same reason.
///
/// **Liquid Glass (Rule #2 §B.5).** `.glassEffect(.regular.interactive(), in:
/// .rect(cornerRadius: UniRadius.l))` — translucency + specular +
/// motion contract on a custom-shape glass surface. The
/// `.interactive()` flag opts the surface into the touch-deformation
/// response (Rule #2 §B.1 behavior #3). One glass layer; the
/// content beneath scrolls under it.
///
/// **Honesty (Rule #2 §A.7).** The placeholder reads "Search or
/// enter address" — a verbatim copy of mobile Safari's placeholder
/// because users already recognise it. No promotional ("BLAZING-fast
/// dApp search!") copy. The field doesn't promise to find anything;
/// it accepts the typing and routes it.
struct BrowserSearchField: View {
    @Binding var text: String
    /// Fires when the user taps Go on the keyboard or presses
    /// return. Caller resolves the text through
    /// `BrowserURLNormalizer` and navigates.
    let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(UniColors.Icon.secondary)
                .accessibilityHidden(true)

            TextField(
                "",
                text: $text,
                prompt: Text("Search or enter address")
                    .foregroundStyle(UniColors.Text.placeholder)
            )
            .font(UniTypography.body)
            .foregroundStyle(UniColors.Text.primary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .focused($isFocused)
            .onSubmit {
                onSubmit()
                isFocused = false
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(UniColors.Icon.tertiary)
                        .contentShape(Circle())
                        .accessibilityLabel(Text("Clear"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .frame(height: 52)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: UniRadius.l)
        )
        .contentShape(RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous))
        .onTapGesture {
            isFocused = true
        }
    }
}
