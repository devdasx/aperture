import SwiftUI

/// Identifies which real, designed visual accompanies a given onboarding beat.
///
/// Per Rule #7 (real visuals only) each case resolves to either:
///   - an Apple-authored **SF Symbol** (`Image(systemName:)`), or
///   - a real **bundled brand asset** from `Assets.xcassets/` (reserved for
///     screens that show specific brand marks — currently used by the
///     wordmark illustration; the chain-logo PNGs bundled under
///     `Assets.xcassets/Crypto/` are kept for the future wallet/portfolio
///     view, not consumed here).
///
/// Hand-building icons / logos / illustrations from `Shape` / `Path` /
/// `Canvas` primitives is **forbidden** (Rule #7 Part C). Structural shapes
/// inside an illustration (the fee-ticket capsule, the threshold doors)
/// carry layout — not meaning — and remain allowed per Rule #7 Part C's
/// "structural shapes" exception.
///
/// All colors flow through `UniColors.Illustration` (Rule #4); all spacing
/// through `UniSpacing`; all radii through `UniRadius`.
enum OnboardingIllustration: Sendable, Hashable {
    case wordmark
    case constellation
    case vault
    case faceID
    case recoveryPhrase
    case receive
    case send
    case swap
    case privacy
    case threshold
}

/// Resolves an `OnboardingIllustration` to its rendered SwiftUI scene.
///
/// `isActive` propagates the pager's current-beat state so each SF Symbol
/// can fire one native `.symbolEffect(.bounce)` greeting when its slide
/// becomes active.
struct OnboardingIllustrationView: View {
    let kind: OnboardingIllustration
    let isActive: Bool

    var body: some View {
        Group {
            switch kind {
            case .wordmark:        WordmarkIllustration(isActive: isActive)
            case .constellation:   ConstellationIllustration(isActive: isActive)
            case .vault:           VaultIllustration(isActive: isActive)
            case .faceID:          FaceIDIllustration(isActive: isActive)
            case .recoveryPhrase:  RecoveryPhraseIllustration(isActive: isActive)
            case .receive:         ReceiveIllustration(isActive: isActive)
            case .send:            SendIllustration(isActive: isActive)
            case .swap:            SwapIllustration(isActive: isActive)
            case .privacy:         PrivacyIllustration(isActive: isActive)
            case .threshold:       ThresholdIllustration(isActive: isActive)
            }
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
