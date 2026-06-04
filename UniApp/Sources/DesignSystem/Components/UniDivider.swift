import SwiftUI

/// Hairline divider on the system separator color.
struct UniDivider: View {
    var body: some View {
        Rectangle()
            .fill(UniColors.Separator.regular)
            .frame(height: 1 / UIScreen.main.scale)
            .accessibilityHidden(true)
    }
}
