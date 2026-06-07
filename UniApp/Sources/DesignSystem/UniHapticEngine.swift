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
