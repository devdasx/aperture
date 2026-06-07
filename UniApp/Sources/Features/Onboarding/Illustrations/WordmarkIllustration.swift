import SwiftUI

/// Beat 1 — Identity. Welcome to Aperture.
///
/// The iris IS the brand mark; on this slide it sits still as the
/// identity beat. The animated bloom belongs to the cold-launch
/// `SplashView` (the "first breath" — only fires once per launch);
/// slide 1 is a calm restatement of the identity, not a second
/// performance of the same motion. Ive restraint: one animation, one
/// moment, earned.
///
/// **Easter egg (2026-06-05).** A tap on the iris cycles the shutter
/// — close (~600ms total close + open) — then plays a success
/// scale-breath (~250ms) with a `.success` haptic — then presents
/// `HelloSheet` ("Hi from Aperture."). Native end-to-end: `withAnimation`
/// drives the existing `ApertureIrisView`'s `rc` + `rot` parameters; no
/// Lottie (Rule #3). The Lottie files in `/Downloads/logo 5/lottie/`
/// served as motion brief only.
///
/// `isActive` is accepted for API uniformity with the other illustration
/// views but is unused here.
struct WordmarkIllustration: View {
    let isActive: Bool

    // MARK: - Animation state

    @State private var irisRc: CGFloat = ApertureIrisView.openValue
    @State private var irisRot: CGFloat = 0
    @State private var irisScale: CGFloat = 1.0
    @State private var isAnimating: Bool = false
    @State private var isShowingHelloSheet: Bool = false
    @State private var tapHapticTrigger: Int = 0
    @State private var successHapticTrigger: Int = 0

    var body: some View {
        ApertureIrisView(rc: irisRc, rot: irisRot)
            .frame(width: 112, height: 112)
            .scaleEffect(irisScale)
            .contentShape(Circle())
            .onTapGesture {
                guard !isAnimating else { return }
                runShutterCycle()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Opens a note from Aperture"))
            .uniHaptic(.contextualImpact(.tap), trigger: tapHapticTrigger)
            .uniHaptic(.success, trigger: successHapticTrigger)
            .sheet(isPresented: $isShowingHelloSheet) {
                HelloSheet(onDismiss: { isShowingHelloSheet = false })
                    .uniAppEnvironment()
                    .intrinsicHeightSheet()
                    .presentationBackground(UniColors.Background.primary)
            }
    }

    private func runShutterCycle() {
        isAnimating = true
        tapHapticTrigger &+= 1

        // Stage A — shutter close (≈300ms): rc shrinks to near-closed
        // while the iris rotates a soft 51° (~π/3.5). The half-rotation
        // is deliberately asymmetric (not a clean 90°) — symmetry reads
        // as decoration; asymmetry reads as motion.
        withAnimation(.easeIn(duration: 0.28)) {
            irisRc = ApertureIrisView.shutValue
            irisRot += .pi / 3.5
        }

        // Stage A — shutter open (≈300ms) — continues the rotation
        // while re-opening to fully open. Chains via asyncAfter so the
        // close completes before the open begins (a real camera
        // shutter, not a tween).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            withAnimation(.easeOut(duration: 0.30)) {
                irisRc = ApertureIrisView.openValue
                irisRot += .pi / 3.5
            }
        }

        // Stage B — success scale-breath (1.0 → 1.06 → 1.0) and the
        // `.success` haptic. Restraint here is critical — anything
        // bigger reads as a bug.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
                irisScale = 1.06
            }
            successHapticTrigger &+= 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.70)) {
                irisScale = 1.0
            }
        }

        // Stage C — sheet presents while Stage B is still settling so
        // the user feels the sheet as a consequence of the success
        // beat, not as a separate event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            isShowingHelloSheet = true
            isAnimating = false
        }
    }
}
