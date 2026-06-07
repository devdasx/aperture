import SwiftUI

/// A single onboarding slide — illustration, title, body. Pure content layer
/// (opaque). No bespoke animation: the user moves between slides by swiping
/// the system pager. The only motion in the slide itself is the native
/// `.symbolEffect(.bounce)` greeting fired on each SF Symbol when the beat
/// becomes active — that is system behavior on the symbol, not hand-built
/// motion. `isActive` is the propagated current-beat flag.
///
/// **Open-source anchor (Rule #16 §A.4 / §C).** The welcome slide (the
/// first surface a user sees in a session) carries a restrained "Open
/// source" badge below the body copy. Tapping calls `onOpenSourceTap`,
/// which the parent uses to present `OpenSourceSheet`. The badge only
/// appears on the wordmark beat — other slides are marketing content,
/// not security-touching surfaces, so they do not need the anchor.
struct OnboardingSlideView: View {
    let slide: OnboardingSlide
    let isActive: Bool
    /// Fires when the user taps the welcome slide's open-source badge.
    /// Other slides (`illustration != .wordmark`) ignore this closure.
    var onOpenSourceTap: () -> Void = {}
    /// Logo namespace from `AppRoot`, threaded down for the welcome
    /// slide's `matchedGeometryEffect`. Other slides ignore it.
    let logoNamespace: Namespace.ID
    /// App-wide phase from `AppRoot`. The welcome slide gates its
    /// non-logo content (title + body + open-source badge) on
    /// `phase != .splash` so they stagger in once the transition
    /// starts; the logo itself stays present (it's the matched
    /// geometry destination) and does not fade.
    let phase: AppPhase

    /// True for the welcome beat — the only slide carrying the
    /// open-source anchor today. Slide identity is matched by the
    /// illustration kind so the rule survives ordering changes in
    /// `OnboardingSlide.all`.
    private var isWelcomeSlide: Bool {
        slide.illustration == .wordmark
    }

    /// Becomes true the instant the splash → onboarding transition
    /// fires. Drives the per-element staggered fade-in below; the
    /// logo (matchedGeometryEffect destination) is excluded so it
    /// stays visible the moment it arrives.
    private var contentVisible: Bool { phase != .splash }

    var body: some View {
        VStack(spacing: UniSpacing.xl) {
            Spacer(minLength: UniSpacing.l)

            OnboardingIllustrationView(
                kind: slide.illustration,
                isActive: isActive,
                logoNamespace: logoNamespace,
                phase: phase
            )

            VStack(spacing: UniSpacing.m) {
                UniLargeTitle(text: slide.title, alignment: .center)
                    .modifier(OnboardingStaggeredFadeIn(
                        visible: !isWelcomeSlide || contentVisible,
                        delay: isWelcomeSlide ? 0.10 : 0
                    ))

                UniBody(
                    text: slide.body,
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
                .modifier(OnboardingStaggeredFadeIn(
                    visible: !isWelcomeSlide || contentVisible,
                    delay: isWelcomeSlide ? 0.16 : 0
                ))

                if isWelcomeSlide {
                    openSourceBadge
                        .padding(.top, UniSpacing.xs)
                        .modifier(OnboardingStaggeredFadeIn(
                            visible: contentVisible,
                            delay: 0.22
                        ))
                }
            }
            .padding(.horizontal, UniSpacing.s)

            Spacer(minLength: UniSpacing.l)
        }
        .padding(.horizontal, UniSpacing.l)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Open-source badge

    /// Restrained tappable badge — small `lock.shield` glyph, the words
    /// "Open source", and a trailing `chevron.right`. All in
    /// `UniColors.Text.tertiary` so the affordance reads as an honest
    /// footnote, not a marketing banner (Rule #16 §B "Restraint, not
    /// alarm"). Tap presents the `OpenSourceSheet` via the parent.
    private var openSourceBadge: some View {
        Button(action: onOpenSourceTap) {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .regular))
                Text("Open source")
                    .font(UniTypography.footnote)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(UniColors.Text.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Open source"))
        .accessibilityHint(Text("Opens a sheet describing what you can verify in the source code"))
    }
}
