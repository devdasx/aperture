import SwiftUI

/// Beat 4 — locked by the device.
///
/// One native `.symbolEffect(.bounce)` when this beat becomes active.
struct FaceIDIllustration: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: "lock.shield")
            .resizable()
            .scaledToFit()
            .frame(width: 120, height: 120)
            .foregroundStyle(UniColors.Brand.mark)
            .symbolEffect(.bounce, options: .nonRepeating, value: isActive)
    }
}
