import SwiftUI

/// Unified semantic haptic vocabulary. Every haptic the app emits names
/// *meaning* (`.success`, `.warning`, `.mediumImpact`) — never raw weight
/// or generator type. Each case maps internally to the matching iOS 26
/// `SensoryFeedback` constant.
///
/// Per `CLAUDE.md` Rule #10, this is the **only** allowed way to fire a
/// haptic from a view. Raw `UIImpactFeedbackGenerator` /
/// `UINotificationFeedbackGenerator` / inline `.sensoryFeedback(...)` calls
/// are forbidden outside this file.
///
/// ### Usage
///
/// ```swift
/// SomeView()
///     .uniHaptic(.selection, trigger: currentIndex)
/// ```
///
/// `UniButton` fires the variant-appropriate haptic automatically; for
/// non-button interactive surfaces (sliders, custom gestures, sheet
/// dismissals, toggle changes), apply `.uniHaptic(_:trigger:)` to the view
/// that owns the changing state.
///
/// User preference: `@AppStorage("hapticFeedbackEnabled")`, default `true`.
/// When the preference is `false`, `.uniHaptic(_:trigger:)` resolves to a
/// no-op and the underlying `.sensoryFeedback(...)` modifier is not
/// installed — silent for the whole app, with one source of truth.
enum UniHaptic: Hashable, Sendable {
    /// Picker change, toggle on/off, list-row tap that opens detail.
    case selection
    /// Lightweight tap acknowledgement.
    case softImpact
    /// Primary CTA tap that commits to a flow.
    case mediumImpact
    /// Significant commit (sign transaction, confirm seed phrase).
    case firmImpact
    /// Wallet created, transaction confirmed, copy-to-clipboard succeeded.
    case success
    /// Destructive CTA tap, confirmation about to show.
    case warning
    /// Failed transaction, validation failure, biometric refused.
    case error
    /// Stepper up, slider up, swap-amount up.
    case increase
    /// Stepper down, slider down, swap-amount down.
    case decrease
    /// Animation start, beginning of a long-running flow.
    case start
    /// Animation end, end-of-list reached.
    case stop
    /// Snap to grid, snap to value.
    case alignment
    /// Network change in a picker, chain switch.
    case levelChange

    /// Maps a semantic case to the iOS 26 native `SensoryFeedback` value.
    /// Returns `nil` only if the case has no haptic (none currently —
    /// reserved for future cases such as a deliberate `.silent`).
    fileprivate var feedback: SensoryFeedback? {
        switch self {
        case .selection:     return .selection
        case .softImpact:    return .impact(weight: .light)
        case .mediumImpact:  return .impact(weight: .medium)
        case .firmImpact:    return .impact(weight: .heavy)
        case .success:       return .success
        case .warning:       return .warning
        case .error:         return .error
        case .increase:      return .increase
        case .decrease:      return .decrease
        case .start:         return .start
        case .stop:          return .stop
        case .alignment:     return .alignment
        case .levelChange:   return .levelChange
        }
    }
}

extension View {
    /// Fire `haptic` when `trigger` changes, *if* the user has haptic
    /// feedback enabled in Settings. The check is read fresh from
    /// `@AppStorage` on every view update, so flipping the preference
    /// takes effect immediately — no app restart, no cache invalidation.
    ///
    /// Multiple `.uniHaptic(...)` calls may be chained on one view to
    /// react to different state changes:
    ///
    /// ```swift
    /// SomeView()
    ///     .uniHaptic(.selection, trigger: currentIndex)
    ///     .uniHaptic(.success, trigger: completedAt)
    /// ```
    func uniHaptic<T: Equatable>(_ haptic: UniHaptic, trigger: T) -> some View {
        modifier(UniHapticModifier(haptic: haptic, trigger: trigger))
    }
}

/// Implementing modifier — exists only to host the `@AppStorage` read.
/// The public `.uniHaptic(_:trigger:)` extension can't own state itself.
private struct UniHapticModifier<T: Equatable>: ViewModifier {
    let haptic: UniHaptic
    let trigger: T

    @AppStorage(HapticPreference.storageKey)
    private var isEnabled: Bool = HapticPreference.defaultValue

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled, let feedback = haptic.feedback {
            content.sensoryFeedback(feedback, trigger: trigger)
        } else {
            content
        }
    }
}
