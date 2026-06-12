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
/// - Lazy `CHHapticEngine` startup and **lazy re-creation** after the
///   haptic server stops or resets the engine (phone call, Siri, app
///   background) — `ensureEngine()` rebuilds a fresh instance on the
///   next play path.
/// - AHAP file loading from `Resources/Haptics/` on first use of each
///   signature.
/// - `UIAccessibility.isReduceMotionEnabled` gating for signature
///   patterns (per Rule #10 §I — signatures are richer; if the user
///   has told iOS they want fewer choreographed sensory beats, we
///   honor that for Core Haptics patterns).
/// - Frustration silencing (per Rule #10 §J — after 3 consecutive
///   `.error` haptics within 10s, the next 2 errors are silenced).
/// - Pre-warmed, long-lived `UIImpactFeedbackGenerator` /
///   `UINotificationFeedbackGenerator` / `UISelectionFeedbackGenerator`
///   instances for ad-hoc fires from the directional modifier — one
///   generator per style, re-`prepare()`d after each fire so the
///   Taptic Engine stays warm (creating a generator per fire adds
///   latency and drops beats under load).
@MainActor
final class UniHapticEngine {
    static let shared = UniHapticEngine()

    /// Lazy Core Haptics engine. `nil` if the device doesn't support
    /// haptics (iPhone 7 and earlier — vanishingly rare on iOS 26),
    /// or after the engine stopped/reset and the next play hasn't
    /// rebuilt it yet (see `ensureEngine()`).
    private var engine: CHHapticEngine?

    /// Loaded patterns keyed by signature. Each is loaded once on
    /// first play, then cached for the app's lifetime. Patterns are
    /// engine-independent, so this cache survives engine rebuilds.
    private var patterns: [UniHaptic.Signature: CHHapticPattern] = [:]

    /// Cached scrub-tick player. Built lazily on first tick, replayed
    /// for every subsequent tick (up to ~30/s) with per-tick dynamic
    /// parameters instead of allocating a pattern + player per fire.
    /// **Tied to the engine identity that created it** — invalidated
    /// whenever the engine is rebuilt (`ensureEngine()` /
    /// `discardEngine(ifCurrent:)`), because players from a dead
    /// engine throw on `start`.
    private var scrubTickPlayer: CHHapticAdvancedPatternPlayer?

    /// Cached scrub-release player. Same lifecycle as
    /// `scrubTickPlayer`; fixed parameters, so a basic player suffices.
    private var scrubReleasePlayer: CHHapticPatternPlayer?

    // MARK: - Pre-warmed UIKit feedback generators
    //
    // One long-lived generator per style. Each fire is followed by
    // `prepare()` so the next fire lands with minimal latency — the
    // standard UIKit pre-warm pattern. These are the ONLY
    // UIImpactFeedbackGenerator / UINotificationFeedbackGenerator /
    // UISelectionFeedbackGenerator instances in the app (Rule #10 §D).

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let selectionGenerator = UISelectionFeedbackGenerator()

    /// Rolling deque of recent `.error` timestamps. Used to compute
    /// the frustration window (Rule #10 §J).
    private var recentErrors: [Date] = []

    /// How many of the next errors to silence after the frustration
    /// threshold is exceeded. Decremented on each silenced error.
    private var pendingErrorSilences: Int = 0

    /// Timestamp of the most recent `.error` haptic (fired or
    /// silenced). Used to expire `pendingErrorSilences` per Rule #10
    /// §J's "state resets after 10s of no errors" — without it,
    /// silence credits earned by three rapid failures would still
    /// mute an unrelated error hours later.
    private var lastErrorAt: Date?

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
    /// can't bind a trigger). Uses the stored, pre-warmed generators —
    /// each fire re-`prepare()`s its generator so the Taptic Engine
    /// stays warm for the next beat.
    func fire(_ haptic: UniHaptic) {
        guard isHapticsEnabled else { return }
        switch haptic {
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .selectionDeselect:
            lightImpact.impactOccurred(intensity: 0.6)
            lightImpact.prepare()
        case .contextualImpact(let sig):
            fireImpact(sig)
        case .success:
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        case .successQuiet:
            lightImpact.impactOccurred(intensity: 0.7)
            lightImpact.prepare()
        case .warning:
            notificationGenerator.notificationOccurred(.warning)
            notificationGenerator.prepare()
        case .error:
            playError()
        case .increase, .decrease, .alignment, .levelChange, .start, .stop:
            // These cases have no direct UIKit generator analogue; the
            // platform's `SensoryFeedback` is the only correct path.
            // Directional-fire of these via UIKit isn't supported;
            // call sites use `.uniHaptic(_:trigger:)` instead.
            break
        case .toggle:
            // 2026-06-10 handoff toggle pattern — rigid impact.
            rigidImpact.impactOccurred(intensity: 0.9)
            rigidImpact.prepare()
        case .countUp:
            // 2026-06-10 handoff countUp pattern — whisper-soft tick
            // per rolling digit. Light impact at low intensity.
            lightImpact.impactOccurred(intensity: 0.22)
            lightImpact.prepare()
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
        guard let engine = ensureEngine() else { return }

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

    /// Returns a started `CHHapticEngine`, building a fresh one on
    /// demand when none exists — either because this is the first play,
    /// or because the previous instance died (phone call, Siri, audio
    /// session reset, app background) and its handlers cleared the
    /// reference. **Lazy re-creation is the recovery strategy**: the
    /// pre-2026-06-10 implementation had `resetHandler` call
    /// `self?.engine?.start()`, but `stoppedHandler` had already nil'd
    /// `engine`, so the restart was a no-op on a nil reference and
    /// haptics stayed dead for the rest of the session. Every play
    /// path now calls this instead.
    ///
    /// Returns `nil` when the hardware doesn't support haptics or the
    /// engine can't be created/started.
    private func ensureEngine() -> CHHapticEngine? {
        if let engine { return engine }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        do {
            let e = try CHHapticEngine()
            // The handlers hop to the MainActor via a @Sendable Task;
            // `CHHapticEngine` is not Sendable, so the identity check
            // crosses the boundary as a Sendable `ObjectIdentifier`.
            let engineID = ObjectIdentifier(e)
            e.stoppedHandler = { [weak self] _ in
                // Engine stops on app background, interruption, etc.
                // Drop the dead instance (and the cached players built
                // on it) so the next play() lazily rebuilds.
                Task { @MainActor in
                    self?.discardEngine(matching: engineID)
                }
            }
            e.resetHandler = { [weak self] in
                // The haptic server reclaimed this engine's resources.
                // The instance and any players created from it are
                // dead — discard both; the next play() rebuilds fresh
                // through this same configuration path.
                Task { @MainActor in
                    self?.discardEngine(matching: engineID)
                }
            }
            try e.start()
            engine = e
            // Cached players (if any) belonged to a previous engine —
            // invalidate so they're lazily rebuilt against this one.
            scrubTickPlayer = nil
            scrubReleasePlayer = nil
            return e
        } catch {
            engine = nil
            return nil
        }
    }

    /// Drops the current engine and the players cached against it —
    /// but only if `id` identifies the live instance. A stale handler
    /// firing from an already-replaced engine must not tear down its
    /// successor.
    private func discardEngine(matching id: ObjectIdentifier) {
        guard let engine, ObjectIdentifier(engine) == id else { return }
        self.engine = nil
        scrubTickPlayer = nil
        scrubReleasePlayer = nil
    }

    // MARK: - Consequential (double-beat) impact

    private func playConsequential() {
        heavyImpact.impactOccurred(intensity: 1.0)
        heavyImpact.prepare()
        // Second beat 80ms later — structured MainActor sleep instead
        // of DispatchQueue.asyncAfter, using the stored pre-warmed
        // generator so the follow-through never misses its window.
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            self.mediumImpact.impactOccurred(intensity: 1.0)
            self.mediumImpact.prepare()
        }
    }

    private func fireImpact(_ significance: ImpactSignificance) {
        switch significance {
        case .whisper:
            lightImpact.impactOccurred(intensity: 0.55)
            lightImpact.prepare()
        case .tap:
            lightImpact.impactOccurred(intensity: 0.85)
            lightImpact.prepare()
        case .commit:
            mediumImpact.impactOccurred(intensity: 1.0)
            mediumImpact.prepare()
        case .weighted:
            heavyImpact.impactOccurred(intensity: 1.0)
            heavyImpact.prepare()
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
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
            return
        }
        guard let player = ensureScrubTickPlayer() else {
            // Engine or player couldn't be built — fall back rather
            // than vanish. The user's finger is on the screen; some
            // beat is better than none.
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
            return
        }

        let clampedIntensity = max(0.05, min(1.0, intensity))
        let sharpness = max(0.1, min(1.0, clampedIntensity * 0.8))
        do {
            // The cached player's base transient is authored at
            // intensity 1.0 / sharpness 0.0. Intensity control is
            // multiplicative and sharpness control is additive, so the
            // played values land exactly at `clampedIntensity` /
            // `sharpness` — one player, replayed per tick, no per-fire
            // pattern + player allocation at up to 30 ticks/s.
            try player.sendParameters(
                [
                    CHHapticDynamicParameter(
                        parameterID: .hapticIntensityControl,
                        value: clampedIntensity,
                        relativeTime: 0
                    ),
                    CHHapticDynamicParameter(
                        parameterID: .hapticSharpnessControl,
                        value: sharpness,
                        relativeTime: 0
                    ),
                ],
                atTime: CHHapticTimeImmediate
            )
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // The player may be stale (engine died between ticks) —
            // drop the cache so the next tick rebuilds, and fall back
            // so this beat isn't lost.
            scrubTickPlayer = nil
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
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
            lightImpact.impactOccurred(intensity: 0.4)
            lightImpact.prepare()
            return
        }
        guard let player = ensureScrubReleasePlayer() else {
            lightImpact.impactOccurred(intensity: 0.4)
            lightImpact.prepare()
            return
        }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            scrubReleasePlayer = nil
            lightImpact.impactOccurred(intensity: 0.4)
            lightImpact.prepare()
        }
    }

    /// Lazily builds (and caches) the scrub-tick player against the
    /// current engine. The base pattern is a single transient at
    /// intensity 1.0 / sharpness 0.0; per-tick values are applied via
    /// dynamic parameters in `playScrubTick(intensity:)`. Advanced
    /// player because it's the canonical Apple surface for
    /// parameter-modulated replay. Returns `nil` when the engine can't
    /// be built or the player creation fails.
    private func ensureScrubTickPlayer() -> CHHapticAdvancedPatternPlayer? {
        if let scrubTickPlayer { return scrubTickPlayer }
        guard let engine = ensureEngine() else { return nil }
        let events = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.0),
                ],
                relativeTime: 0
            ),
        ]
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            scrubTickPlayer = player
            return player
        } catch {
            return nil
        }
    }

    /// Lazily builds (and caches) the fixed-parameter scrub-release
    /// player against the current engine.
    private func ensureScrubReleasePlayer() -> CHHapticPatternPlayer? {
        if let scrubReleasePlayer { return scrubReleasePlayer }
        guard let engine = ensureEngine() else { return nil }
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
            scrubReleasePlayer = player
            return player
        } catch {
            return nil
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

        // Rule #10 §J: "state resets after 10s of no errors." Silence
        // credits expire with the window — they must never carry over
        // to an unrelated error long after the frustration burst.
        if let lastErrorAt,
           now.timeIntervalSince(lastErrorAt) > Self.frustrationWindow {
            pendingErrorSilences = 0
        }
        lastErrorAt = now

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

        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }
}
