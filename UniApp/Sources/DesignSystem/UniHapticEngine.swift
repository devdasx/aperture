import Foundation
import CoreHaptics
import UIKit
import SwiftUI

/// Core Haptics machinery for Aperture's signature AHAP patterns plus
/// the double-beat `.consequential` impact. Singleton, main-actor
/// isolated, lazy `CHHapticEngine` startup, lazy AHAP pattern loading.
///
/// Feature code never touches this class directly — it goes through
/// `UniHaptic.signature(...)` / `.contextualImpact(.consequential)` /
/// `.uniHapticSignature(...)`. The engine handles:
///
/// - Lazy `CHHapticEngine` startup and restart on `stoppedHandler`.
/// - AHAP file loading from `Resources/Haptics/` on first use of each
///   signature.
/// - `UIAccessibility.isReduceMotionEnabled` gating for signature
///   patterns (per Rule #10 §I — signatures are richer; if the user
///   has told iOS they want fewer choreographed sensory beats, we
///   honor that for Core Haptics patterns).
/// - Frustration silencing (per Rule #10 §J — after 3 consecutive
///   `.error` haptics within 10s, the next 2 errors are silenced).
/// - Single-shot `UIImpactFeedbackGenerator` instances for ad-hoc
///   fires from the directional modifier.
@MainActor
final class UniHapticEngine {
    static let shared = UniHapticEngine()

    /// Lazy Core Haptics engine. `nil` if the device doesn't support
    /// haptics (iPhone 7 and earlier — vanishingly rare on iOS 26).
    private var engine: CHHapticEngine?

    /// Loaded patterns keyed by signature. Each is loaded once on
    /// first play, then cached for the app's lifetime.
    private var patterns: [UniHaptic.Signature: CHHapticPattern] = [:]

    /// Rolling deque of recent `.error` timestamps. Used to compute
    /// the frustration window (Rule #10 §J).
    private var recentErrors: [Date] = []

    /// How many of the next errors to silence after the frustration
    /// threshold is exceeded. Decremented on each silenced error.
    private var pendingErrorSilences: Int = 0

    private init() {}

    // MARK: - Public entry points

    /// Play a `UniHaptic` case that requires the engine: signatures
    /// (`Core Haptics`) and the double-beat `.consequential` impact.
    /// No-op for any other case.
    ///
    /// Gated by the AppStorage preference (read fresh each call) and,
    /// for signatures, by `UIAccessibility.isReduceMotionEnabled`.
    func play(_ haptic: UniHaptic) {
        guard isHapticsEnabled else { return }
        switch haptic {
        case .signature(let signature):
            playSignature(signature)
        case .contextualImpact(.consequential):
            playConsequential()
        case .error:
            playError()
        default:
            // For non-engine cases fired through this path (e.g. from
            // the directional modifier), fall through to the simple
            // generator-based fire below.
            fire(haptic)
        }
    }

    /// Ad-hoc one-shot fire for haptics that need an immediate event
    /// (used by the directional modifier where `.sensoryFeedback`
    /// can't bind a trigger). Uses `UIImpactFeedbackGenerator(view:)`
    /// where appropriate, `UINotificationFeedbackGenerator` for the
    /// notification triad.
    func fire(_ haptic: UniHaptic) {
        guard isHapticsEnabled else { return }
        switch haptic {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .selectionDeselect:
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred(intensity: 0.6)
        case .contextualImpact(let sig):
            fireImpact(sig)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .successQuiet:
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred(intensity: 0.7)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            playError()
        case .increase, .decrease, .alignment, .levelChange, .start, .stop:
            // These cases have no direct UIKit generator analogue; the
            // platform's `SensoryFeedback` is the only correct path.
            // Directional-fire of these via UIKit isn't supported;
            // call sites use `.uniHaptic(_:trigger:)` instead.
            break
        case .progressTick(let phase):
            fireImpact(phase.impactSignificance)
        case .signature(let sig):
            playSignature(sig)
        }
    }

    // MARK: - Preference + accessibility gates

    private var isHapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: HapticPreference.storageKey) as? Bool
            ?? HapticPreference.defaultValue
    }

    private var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    // MARK: - Signature playback

    private func playSignature(_ signature: UniHaptic.Signature) {
        // Reduce Motion silences signature patterns specifically. Per
        // Rule #10 §I — signatures are choreographed and richer than
        // atomic SensoryFeedback beats; the user has told iOS they
        // want fewer such beats.
        guard !isReduceMotionEnabled else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        ensureEngineStarted()
        guard let engine else { return }

        let pattern: CHHapticPattern
        if let cached = patterns[signature] {
            pattern = cached
        } else {
            guard let loaded = loadPattern(named: signature.resourceName) else { return }
            patterns[signature] = loaded
            pattern = loaded
        }

        do {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Silently no-op — the user shouldn't see haptic errors;
            // they'll just not feel the signature.
        }
    }

    private func loadPattern(named name: String) -> CHHapticPattern? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ahap") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [CHHapticPattern.Key: Any]
                else { return nil }
            return try CHHapticPattern(dictionary: dict)
        } catch {
            return nil
        }
    }

    private func ensureEngineStarted() {
        if engine == nil {
            do {
                let e = try CHHapticEngine()
                e.stoppedHandler = { [weak self] _ in
                    // Engine stops on app background, interruption,
                    // etc. Clear so next play() restarts it lazily.
                    Task { @MainActor in
                        self?.engine = nil
                    }
                }
                e.resetHandler = { [weak self] in
                    Task { @MainActor in
                        try? self?.engine?.start()
                    }
                }
                try e.start()
                engine = e
            } catch {
                engine = nil
            }
        }
    }

    // MARK: - Consequential (double-beat) impact

    private func playConsequential() {
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        heavy.impactOccurred(intensity: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.080) {
            let medium = UIImpactFeedbackGenerator(style: .medium)
            medium.impactOccurred(intensity: 1.0)
        }
    }

    private func fireImpact(_ significance: ImpactSignificance) {
        switch significance {
        case .whisper:
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred(intensity: 0.55)
        case .tap:
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred(intensity: 0.85)
        case .commit:
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred(intensity: 1.0)
        case .weighted:
            let gen = UIImpactFeedbackGenerator(style: .heavy)
            gen.impactOccurred(intensity: 1.0)
        case .consequential:
            playConsequential()
        }
    }

    // MARK: - Scrub tick (variable-intensity transient)

    /// Fires a single Core Haptics transient whose intensity + sharpness
    /// track the magnitude of the change the user is feeling under their
    /// finger. Used by `SparklineChart`'s scrub gesture so the haptic
    /// communicates the slope of the curve at the highlighted point —
    /// a flat region whispers, a steep wall thumps.
    ///
    /// `intensity` is clamped to `[0.05, 1.0]`. Sharpness derives from
    /// intensity at `intensity * 0.8` (also clamped) — sharper at higher
    /// intensities so the steep regions feel distinct from the gentle
    /// ones not just by amplitude but by character.
    ///
    /// Gated by both the `hapticFeedbackEnabled` preference and Reduce
    /// Motion. Falls back to a `.selection` sensory beat when Core
    /// Haptics isn't supported on the device — keeps the affordance
    /// alive on legacy hardware without inventing a second engine.
    ///
    /// Rule #10 §F carve-out: scrub feedback is the canonical "genuinely
    /// custom signature event" the §F exception was written for —
    /// continuous, intensity-modulated, choreographed against the user's
    /// motion. It lives here (the only file that touches Core Haptics)
    /// rather than in `UniHaptic`'s enum because the per-tick intensity
    /// is data, not vocabulary.
    func playScrubTick(intensity: Float) {
        guard isHapticsEnabled else { return }
        guard !isReduceMotionEnabled else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            // Fallback for the rare device without Core Haptics. The
            // selection beat is symmetrical and discrete — close enough
            // to the "something moved under your finger" affordance.
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        ensureEngineStarted()
        guard let engine else { return }

        let clampedIntensity = max(0.05, min(1.0, intensity))
        let sharpness = max(0.1, min(1.0, clampedIntensity * 0.8))
        let events = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: clampedIntensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: 0
            ),
        ]
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Pattern failed — fall back rather than vanish. The user's
            // finger is on the screen; some beat is better than none.
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// Fires a single soft transient when the user lifts off the scrub
    /// gesture — the "you stopped" acknowledgement. Less intense than a
    /// tap impact so it lands as resolution, not as commitment.
    func playScrubRelease() {
        guard isHapticsEnabled else { return }
        guard !isReduceMotionEnabled else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            // Fallback — light impact at 0.4 intensity matches the soft
            // resolution character without a second engine.
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.4)
            return
        }
        ensureEngineStarted()
        guard let engine else { return }

        let events = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                ],
                relativeTime: 0
            ),
        ]
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.4)
        }
    }

    // MARK: - Frustration silencing (Rule #10 §J)

    /// Threshold of `.error` haptics within the window to trigger
    /// silencing.
    private static let frustrationThreshold = 3

    /// Window length in seconds that the threshold is measured over.
    private static let frustrationWindow: TimeInterval = 10

    /// How many of the next errors to silence once the threshold is hit.
    private static let frustrationSilenceCount = 2

    private func playError() {
        let now = Date()
        // Drop timestamps older than the window.
        recentErrors.removeAll { now.timeIntervalSince($0) > Self.frustrationWindow }

        if pendingErrorSilences > 0 {
            pendingErrorSilences -= 1
            return // Silenced — the user's already heard enough.
        }

        recentErrors.append(now)
        if recentErrors.count >= Self.frustrationThreshold {
            // Threshold reached — silence the next N errors after this
            // one. Reset the window so re-triggering requires three
            // more errors in a fresh 10s span.
            pendingErrorSilences = Self.frustrationSilenceCount
            recentErrors.removeAll()
        }

        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
