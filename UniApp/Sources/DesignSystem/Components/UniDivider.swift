import SwiftUI

/// Hairline divider on the system separator color. One physical pixel
/// tall — derived from the environment's display scale (the
/// per-window, deprecation-safe replacement for `UIScreen.main.scale`).
struct UniDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(UniColors.Separator.regular)
            .frame(height: 1 / max(displayScale, 1))
            .accessibilityHidden(true)
    }
}
