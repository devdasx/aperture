import SwiftUI

/// Inline URL-edit sheet — surfaced when the user taps the URL
/// pill in `BrowserSessionView`'s top chrome. Lets the user type
/// a new destination without leaving the current page until they
/// commit.
///
/// **Sheet shape (Rule #15).** Wrapped in `NavigationStack`, title
/// via `.navigationTitle("Enter URL")` on `.inline` display mode
/// for the `.medium` detent. Cancel in the leading slot, Go in
/// the trailing slot. The body is a single `UniTextField`-class
/// row + a small footnote.
///
/// **Honesty (Rule #16).** The text field accepts whatever the
/// user types, then routes it through the same
/// `BrowserURLNormalizer` the home view uses. A typed search
/// query (no `.`) becomes a Google search; a typed URL becomes a
/// navigation. The footnote names this honestly.
struct BrowserURLEditSheet: View {
    let initialURL: URL
    let onSubmit: (URL) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                HStack(spacing: UniSpacing.s) {
                    Image(systemName: "globe")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.secondary)

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
                    .onSubmit(submit)
                }
                .padding(.horizontal, UniSpacing.m)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )

                UniFootnote(
                    text: "Type a URL to navigate, or any search term to search the web.",
                    color: UniColors.Text.secondary
                )

                Spacer()
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.top, UniSpacing.m)
            .navigationTitle("Enter URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Go") {
                        submit()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                text = initialURL.absoluteString
                isFocused = true
            }
        }
    }

    private func submit() {
        let resolution = BrowserURLNormalizer.resolve(text)
        switch resolution {
        case .url(let url), .search(let url, _):
            onSubmit(url)
        case .empty:
            break
        }
    }
}
