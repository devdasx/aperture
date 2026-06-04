import SwiftUI

/// A single onboarding slide — illustration, title, body. Pure content layer
/// (opaque). No bespoke animation: the user moves between slides by swiping
/// the system pager. The only motion in the slide itself is the native
/// `.symbolEffect(.bounce)` greeting fired on each SF Symbol when the beat
/// becomes active — that is system behavior on the symbol, not hand-built
/// motion. `isActive` is the propagated current-beat flag.
struct OnboardingSlideView: View {
    let slide: OnboardingSlide
    let isActive: Bool

    var body: some View {
        VStack(spacing: UniSpacing.xl) {
            Spacer(minLength: UniSpacing.l)

            OnboardingIllustrationView(kind: slide.illustration, isActive: isActive)

            VStack(spacing: UniSpacing.m) {
                UniLargeTitle(text: slide.title, alignment: .center)

                UniBody(
                    text: slide.body,
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
            }
            .padding(.horizontal, UniSpacing.s)

            Spacer(minLength: UniSpacing.l)
        }
        .padding(.horizontal, UniSpacing.l)
        .accessibilityElement(children: .combine)
        // Concatenate two localized `Text`s so VoiceOver speaks the title
        // and body together in the user's selected language (Rule #9).
        .accessibilityLabel(Text(slide.title) + Text(verbatim: " ") + Text(slide.body))
    }
}
