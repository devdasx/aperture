import SwiftUI

/// Unified semantic haptic vocabulary — Aperture's tactile language.
///
/// Per the jony-ive 2026-06-05 redesign audit and `CLAUDE.md` Rule #10,
/// every haptic in the app names **meaning** (`.selection`, `.success`,
/// `.contextualImpact(.commit)`) — never raw weight or generator type.
/// The implementation layer maps semantics to native iOS 26 primitives:
/// `SensoryFeedback` for atomic platform-blessed beats, and
/// `CHHapticEngine` (via `UniHapticEngine`) for Aperture's six signature
/// AHAP patterns.
///
/// **Six families:**
/// - **Selection** — discrete state change (picker, toggle, nav push).
/// - **Impact** — physical tap acknowledgement at five significances.
/// - **Notification** — the canonical triad (success / warning / error)
///   plus a `successQuiet` for unlock-style "resumed access" moments.
/// - **Stepwise** — continuous-control feedback (increase / decrease /
///   alignment / levelChange) plus `progressTick(_:)` for state-driven
///   progressive intensity escalation.
/// - **Lifecycle** — long-running flow markers (start / stop).
/// - **Signature** — Aperture's bespoke AHAP patterns; the wallet's
///   tactile identity. Six total; new ones require SHIPPED.md
///   justification per Rule #10 §I.
///
/// User preference: `@AppStorage("hapticFeedbackEnabled")`. When `false`
/// every path through this enum short-circuits to no-op — `SensoryFeedback`,
/// `CHHapticEngine`, sequences, signatures, frustration-window state,
/// everything. One source of truth.
///
/// **Forbidden** (Rule #10): raw `UIImpactFeedbackGenerator` /
/// `UINotificationFeedbackGenerator` / inline `.sensoryFeedback(...)` calls
/// anywhere except this file and `UniHapticEngine.swift`.
enum UniHaptic: Hashable, Sendable {

    // MARK: - Family A: selection

    /// Picker change, toggle on, list-row tap, nav push, sheet open.
    case selection

    /// Toggle off, list-row deselect — slightly softer counterpart to
    /// `.selection`. Implemented as a faint light impact, not the
    /// system selection sound (which is symmetrical for on/off).
    case selectionDeselect

    // MARK: - Family B: impact (significance-driven)

    /// Physical tap acknowledgement at one of five significances.
    /// Encapsulates the weight × flexibility × intensity matrix so call
    /// sites name *what the tap means*, not its physics.
    ///
    /// - `.whisper`     — single character appearing, autofill accepted.
    /// - `.tap`         — keypad digit, dice tile, hex glyph.
    /// - `.commit`      — primary CTA that advances (Continue, Save).
    /// - `.weighted`    — destructive confirmation tap.
    /// - `.consequential` — irreversible commit (reset wallet); fires
    ///   a double-beat impact for emphasis.
    case contextualImpact(ImpactSignificance)

    // MARK: - Family C: notification

    /// Generic success — copy succeeded, save preference, all-three
    /// challenges complete. The full system success triad.
    case success

    /// Subdued success — verify-unlock PIN match, per-step backup
    /// challenge correct. The user isn't celebrating, they're resuming
    /// access; the full `.success` triad reads as boastful here.
    case successQuiet

    /// Destructive CTA tap, confirmation about to show. The user is
    /// about to do something reversible-but-weighty.
    case warning

    /// Validation failure — wrong PIN, biometric refused, network
    /// unreachable. Subject to `UniHapticEngine`'s frustration
    /// silencing (3 errors in 10s → next 2 silenced).
    case error

    // MARK: - Family D: stepwise

    /// Stepper up, slider up, swap-amount up, picker advance.
    case increase

    /// Stepper down, slider down, swap-amount down.
    case decrease

    /// Snap-to-grid, snap-to-value, picker detent.
    case alignment

    /// Network / chain switch, account switch — level changed.
    case levelChange

    /// Progress milestone in a long-running collection (Roll-your-own,
    /// future sync flows). The phase encodes intensity escalation so
    /// call sites name "how far along" not "how hard to vibrate":
    ///
    /// - `.early`    — first quarter (whisper-soft).
    /// - `.mid`      — first half (tap-light).
    /// - `.late`     — third quarter (commit-medium).
    /// - `.imminent` — final stretch (weighted-heavy).
    case progressTick(ProgressPhase)

    // MARK: - Family E: lifecycle

    /// Long-running flow begins (sync starts, fetch initiated).
    case start

    /// End of scroll, end of long flow, sheet bottom reached.
    case stop

    // MARK: - Family E.5: handoff additions (2026-06-10)

    /// **`toggle`** per the design handoff. Switch / on-off state
    /// flip. Distinct from `.selection`: a toggle is a stronger,
    /// more committed click — the user is changing a setting, not
    /// just navigating. Maps to `.impact(flexibility: .solid)`.
    case toggle

    /// **`countUp`** per the design handoff. A whisper-soft tick
    /// fired per rolling digit when the balance hero animates from
    /// one value to another. Call sites should throttle (the hero
    /// animation naturally rate-limits to ~30 ticks/sec at most;
    /// SwiftUI's `.contentTransition(.numericText())` fires
    /// `onChange` only on actual digit changes). Maps to
    /// `.impact(weight: .soft, intensity: 0.2)`.
    case countUp

    // MARK: - Family F: signature (Core Haptics AHAP)

    /// Aperture's six signature patterns. Fired via `UniHapticEngine`
    /// — gated by both the AppStorage preference AND
    /// `UIAccessibility.isReduceMotionEnabled` (signatures respect the
    /// user's accessibility choice; atomic `SensoryFeedback` cases do
    /// not because they're platform-blessed).
    case signature(Signature)

    /// Identity of an AHAP pattern bundled in
    /// `UniApp/Resources/Haptics/*.ahap`. Add a case here AND ship
    /// a corresponding `.ahap` file. Per Rule #10 §I, new signatures
    /// require a SHIPPED.md justification.
    enum Signature: String, Hashable, Sendable, CaseIterable {
        case walletSealed
        case phraseRevealed
        case phraseRegenerated
        case pinSealed
        case transactionSigned    // T-018 placeholder
        case transactionConfirmed // T-018 placeholder

        // **2026-06-10 — design handoff signatures.**
        /// Soft tick → medium tap. The aperture brand moment:
        /// splash → home handoff and pull-to-refresh completion.
        case irisSettle
        /// Rising continuous ramp resolving to a transient pop.
        /// Fires when funds leave on swipe-to-send release.
        case sendWhoosh

        /// Name of the AHAP file (without extension) under
        /// `Resources/Haptics/`.
        var resourceName: String { rawValue }
    }
}

// MARK: - ImpactSignificance

/// Encapsulates the weight × flexibility × intensity matrix of
/// `SensoryFeedback.impact` so call sites stay semantic. Adding a sixth
/// significance later means changing this file, not the 29+ call
/// sites in the app.
enum ImpactSignificance: Hashable, Sendable {
    /// Single character appearing, autofill accepted — barely felt.
    case whisper
    /// Keypad digit press, dice tile tap, hex glyph tap.
    case tap
    /// Primary CTA that advances the user.
    case commit
    /// Destructive confirmation tap.
    case weighted
    /// Irreversible commit. Internally a double-beat: a heavy initial
    /// impact, an 80ms gap, then a medium follow-through.
    case consequential

    /// Single-beat impacts map straight to `SensoryFeedback`. The
    /// `.consequential` case returns nil here — `UniHapticEngine` plays
    /// the double-beat directly through `UIImpactFeedbackGenerator`.
    fileprivate var feedback: SensoryFeedback? {
        switch self {
        case .whisper:   return .impact(weight: .light, intensity: 0.55)
        case .tap:       return .impact(flexibility: .solid, intensity: 0.85)
        case .commit:    return .impact(weight: .medium, intensity: 1.0)
        case .weighted:  return .impact(weight: .heavy, intensity: 1.0)
        case .consequential: return nil // handled by UniHapticEngine
        }
    }
}

// MARK: - ProgressPhase

/// Phase of a long-running collection. Used by `.progressTick(_:)` to
/// escalate haptic intensity as the user approaches completion.
enum ProgressPhase: Hashable, Sendable {
    case early       // first quarter
    case mid         // first half
    case late        // third quarter
    case imminent    // final stretch

    /// Compute the phase from a fractional progress value (0...1). Used
    /// by callers that want to derive the phase from their current
    /// state instead of hardcoding boundaries.
    static func phase(forFraction fraction: Double) -> ProgressPhase {
        switch fraction {
        case ..<0.25:  return .early
        case ..<0.50:  return .mid
        case ..<0.75:  return .late
        default:       return .imminent
        }
    }

    /// Map to the impact significance that drives the haptic.
    var impactSignificance: ImpactSignificance {
        switch self {
        case .early:    return .whisper
        case .mid:      return .tap
        case .late:     return .commit
        case .imminent: return .weighted
        }
    }
}

// MARK: - Mapping to SensoryFeedback

extension UniHaptic {
    /// Returns the `SensoryFeedback` value for cases that map directly
    /// to one. Returns `nil` for cases that go through
    /// `UniHapticEngine` (signatures, double-beat consequential
    /// impacts).
    fileprivate var feedback: SensoryFeedback? {
        switch self {
        case .selection:                  return .selection
        case .selectionDeselect:          return .impact(weight: .light, intensity: 0.6)
        case .contextualImpact(let sig):  return sig.feedback
        case .success:                    return .success
        case .successQuiet:               return .impact(weight: .light, intensity: 0.7)
        case .warning:                    return .warning
        case .error:                      return .error
        case .increase:                   return .increase
        case .decrease:                   return .decrease
        case .alignment:                  return .alignment
        case .levelChange:                return .levelChange
        case .progressTick(let phase):    return phase.impactSignificance.feedback
        case .start:                      return .start
        case .stop:                       return .stop
        case .toggle:                     return .impact(flexibility: .solid, intensity: 0.9)
        case .countUp:                    return .impact(weight: .light, intensity: 0.22)
        case .signature:                  return nil // handled by UniHapticEngine
        }
    }

    /// Whether this case is delegated to `UniHapticEngine` (i.e. needs
    /// Core Haptics or double-beat playback).
    fileprivate var requiresEngine: Bool {
        switch self {
        case .signature:                                  return true
        case .contextualImpact(.consequential):           return true
        default:                                          return false
        }
    }
}

// MARK: - View modifiers

extension View {
    /// Fire `haptic` when `trigger` changes, if the user has haptic
    /// feedback enabled in Settings.
    ///
    /// ```swift
    /// SomeView()
    ///     .uniHaptic(.selection, trigger: currentIndex)
    ///     .uniHaptic(.success, trigger: completedAt)
    /// ```
    func uniHaptic<T: Equatable>(_ haptic: UniHaptic, trigger: T) -> some View {
        modifier(UniHapticModifier(haptic: haptic, trigger: trigger))
    }

    /// Fire one of two haptics depending on the direction of the
    /// transition. The resolver receives `(oldValue, newValue)` and
    /// returns the haptic to play, or `nil` for no haptic on this
    /// transition. Useful for amount controls (increase / decrease).
    ///
    /// ```swift
    /// AmountStepper(value: $amount)
    ///     .uniHaptic(trigger: amount) { old, new in
    ///         new > old ? .increase : .decrease
    ///     }
    /// ```
    func uniHaptic<T: Equatable>(
        trigger: T,
        _ resolve: @escaping (T, T) -> UniHaptic?
    ) -> some View {
        modifier(UniHapticDirectionalModifier(trigger: trigger, resolve: resolve))
    }

    /// Fire a signature (AHAP) haptic when `trigger` changes. Routes
    /// through `UniHapticEngine` so Reduce Motion silences correctly.
    func uniHapticSignature<T: Equatable>(
        _ signature: UniHaptic.Signature,
        trigger: T
    ) -> some View {
        onChange(of: trigger) { _, _ in
            Task { @MainActor in
                UniHapticEngine.shared.play(.signature(signature))
            }
        }
    }
}

// MARK: - Internal modifiers

/// Single-shot haptic modifier. Hosts the `@AppStorage` read so the
/// preference check fires fresh on every view update.
///
/// **No structural branching on the preference.** Both modifiers below
/// are applied unconditionally and the preference gates the *effect*
/// (return `nil` feedback / early-return in `onChange`). An earlier
/// shape branched `if isEnabled { … } else { content }`, which changed
/// the wrapped subtree's structural identity the moment the Settings
/// haptics toggle flipped — SwiftUI tore down and rebuilt every
/// `.uniHaptic`-wrapped subtree app-wide, discarding `@State`,
/// `@FocusState`, and scroll positions.
///
/// **`.error` routes through `UniHapticEngine`** (not the direct
/// `SensoryFeedback` mapping) so Rule #10 §J frustration silencing
/// counts and mutes repeated error buzzes — mirroring
/// `UniHapticDirectionalModifier` below.
private struct UniHapticModifier<T: Equatable>: ViewModifier {
    let haptic: UniHaptic
    let trigger: T

    @AppStorage(HapticPreference.storageKey)
    private var isEnabled: Bool = HapticPreference.defaultValue

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: trigger) { _, _ in
                guard isEnabled else { return nil }
                // `.error` fires through the engine in `onChange`
                // below (frustration silencing, Rule #10 §J).
                guard haptic != .error else { return nil }
                return haptic.feedback
            }
            .onChange(of: trigger) { _, _ in
                guard isEnabled else { return }
                guard haptic.requiresEngine || haptic == .error else { return }
                Task { @MainActor in
                    UniHapticEngine.shared.play(haptic)
                }
            }
    }
}

/// Direction-aware modifier — resolves which haptic to fire by
/// comparing old and new values of the trigger.
///
/// Cases with a direct `SensoryFeedback` mapping fire through the
/// native `.sensoryFeedback(trigger:_:)` directional overload — the
/// platform path is frame-synced with the render loop, unlike a
/// `Task`-hopped UIKit generator fire. The `UniHapticEngine` path is
/// reserved for cases that genuinely need it: signatures and the
/// double-beat `.consequential` (no `SensoryFeedback` mapping), plus
/// `.error`, which stays on the engine so Rule #10 §J frustration
/// silencing keeps counting and muting repeated error buzzes.
private struct UniHapticDirectionalModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let resolve: (T, T) -> UniHaptic?

    @AppStorage(HapticPreference.storageKey)
    private var isEnabled: Bool = HapticPreference.defaultValue

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: trigger) { old, new in
                guard isEnabled else { return nil }
                guard let haptic = resolve(old, new) else { return nil }
                // `.error` routes through the engine (frustration
                // silencing); engine-only cases have no mapping anyway.
                guard haptic != .error else { return nil }
                return haptic.feedback
            }
            .onChange(of: trigger) { old, new in
                guard isEnabled else { return }
                guard let haptic = resolve(old, new) else { return }
                guard haptic.requiresEngine || haptic == .error else { return }
                Task { @MainActor in
                    UniHapticEngine.shared.play(haptic)
                }
            }
    }
}
