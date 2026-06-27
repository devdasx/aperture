import SwiftUI

struct WordmarkIllustration: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.black)
            Image(systemName: "camera.aperture")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.white)
        }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
    }
}
