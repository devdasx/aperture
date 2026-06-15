import SwiftUI

/// The one canonical "this section / sheet is loading its data" surface.
///
/// Per `CLAUDE.md` Rule #3 (native-only) the spinner is Apple's native
/// `ProgressView` — never a custom or branded loader. Per Rule #2
/// (restraint) it's a single calm, centered spinner with an optional
/// one-line caption; nothing more. Per Rule #4 every color is a
/// `UniColors` role.
///
/// **When to use this (vs. `UniButton(isLoading:)`).**
/// - A button / CTA that triggers async work shows its loading inline via
///   `UniButton(isLoading:)` — the spinner lives in the button.
/// - A whole screen / sheet / section that can't show its content until a
///   fetch lands (a fee sheet resolving the network fee, a coin-selection
///   sheet fetching UTXOs, a review screen deriving an address) shows
///   `UniLoadingState` centered in the content area while it waits.
///
/// This keeps the wait *visible* and *consistent* everywhere: the user
/// always sees the same native spinner, never a blank pane and never a
/// dishonest "unavailable" while data is still in flight.
///
/// The spinner uses `.controlSize(.large)` (medium-weight, section scale)
/// to read clearly against an empty content pane — distinct from the
/// `.small` spinner a `UniButton` shows inline.
struct UniLoadingState: View {
    /// Optional one-line caption under the spinner ("Loading the network
    /// fee…", "Fetching token info…"). Omit for a bare spinner.
    var caption: LocalizedStringKey?

    init(caption: LocalizedStringKey? = nil) {
        self.caption = caption
    }

    var body: some View {
        VStack(spacing: UniSpacing.m) {
            ProgressView()
                .controlSize(.large)
                .tint(UniColors.Icon.secondary)
            if let caption {
                Text(caption)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(UniSpacing.l)
        // The spinner is the meaningful element; the caption is read by
        // VoiceOver. Group them so the surface announces as one "Loading"
        // status rather than two separate elements.
        .accessibilityElement(children: .combine)
    }
}

#Preview("Caption · Light") {
    UniLoadingState(caption: "Loading the network fee…")
        .background(UniColors.Background.primary)
        .preferredColorScheme(.light)
}

#Preview("Bare · Dark") {
    UniLoadingState()
        .background(UniColors.Background.primary)
        .preferredColorScheme(.dark)
}
