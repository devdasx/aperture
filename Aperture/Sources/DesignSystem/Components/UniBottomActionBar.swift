import SwiftUI

extension View {
    /// Pins a full-screen action bar to the physical bottom edge instead of
    /// floating it above the container safe area. Call sites keep their own
    /// internal padding and scroll-content clearance.
    func uniBottomActionBar<Bar: View>(
        @ViewBuilder _ bar: @escaping () -> Bar
    ) -> some View {
        overlay(alignment: .bottom) {
            bar()
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}
