import SwiftUI

struct WordmarkIllustration: View {
    var body: some View {
        Image("LogoCircle")
            .resizable()
            .scaledToFit()
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
    }
}
