import SwiftUI

/// A simple feature/benefit row — leading SF Symbol, title, optional detail.
/// Used in onboarding, settings explanations, empty states.
///
/// Both `title` and `detail` accept `LocalizedStringKey` so every call site
/// flows through the String Catalog (Rule #9).
struct UniFeatureRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    var tint: Color = UniColors.Icon.primary

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniBody(text: title)

                if let detail {
                    UniSubtitle(text: detail)
                }
            }
        }
    }
}
