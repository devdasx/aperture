import Foundation
import LocalAuthentication

/// Canonical wrapper around `LocalAuthentication` per `CLAUDE.md` Rule #17 §B.
/// Feature code calls `authenticate(reason:)` — never imports `LAContext`
/// directly. This is the only file in UniApp that imports `LocalAuthentication`.
///
/// **Fresh `LAContext` per call** — Apple's recommendation. A reused
/// `LAContext` retains the result of its last evaluation; that's useful
/// for "authenticate once, run several gated operations" but a hazard for
/// our case (one prompt = one explicit user action). Each `authenticate`
/// call constructs a new context.
///
/// **Simulator limitation.** On the iOS Simulator with no enrolled
/// biometry, `canEvaluatePolicy(...)` returns `false` and our `isAvailable`
/// surfaces that honestly. There is no Swift-side test vector we can run
/// without a real device with biometrics enrolled — biometric prompts are
/// presented by the OS in a separate process and cannot be programmatically
/// answered from XCTest / Swift Testing.
@MainActor
final class BiometricService: Sendable {

    /// Concrete biometry type currently available on the device. Resolved
    /// at init time from a fresh `LAContext.biometryType`.
    enum BiometryType {
        case none
        case touchID
        case faceID
        case opticID
    }

    /// Failure modes from `authenticate(reason:)`. `feature code shouldn't
    /// try/catch around biometrics — the failure modes are part of the UX.
    enum AuthError: Error, Sendable {
        /// Device has no biometry enrolled (or hardware doesn't support it).
        case unavailable
        /// User tapped Cancel on the system prompt, or otherwise dismissed it.
        case userCancelled
        /// Biometric scan failed (face not recognized, fingerprint mismatched).
        case authenticationFailed
        /// Anything else — passed through with the underlying `LAError`.
        case systemError(Error)
    }

    /// The biometry type the device currently exposes. Resolved once at
    /// init via a fresh `LAContext`. Feature code may inspect this to
    /// pick the right SF Symbol (`faceid` / `touchid` / `opticid`).
    let biometryType: BiometryType

    /// `true` iff `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, _)`
    /// returned `true` at init time. Read this before presenting any
    /// biometric affordance; if `false`, hide the Face ID / Touch ID
    /// option entirely rather than offering a button that will fail.
    let isAvailable: Bool

    init() {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        self.isAvailable = canEvaluate
        self.biometryType = Self.mapBiometryType(context.biometryType)
    }

    /// Presents the system biometric prompt with the localized `reason`
    /// string. Returns `.success(())` if the user authenticated,
    /// `.failure(_)` otherwise. Never throws.
    ///
    /// The reason is passed as a `LocalizedStringResource` so it flows
    /// through the String Catalog (Rule #9). Apple's iOS prompt renders
    /// the resolved string verbatim under the biometric glyph.
    func authenticate(reason: LocalizedStringResource) async -> Result<Void, AuthError> {
        // Fresh context per call — Apple's recommendation. Reusing a
        // context retains the prior evaluation result, which we explicitly
        // don't want.
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &policyError
        ) else {
            return .failure(.unavailable)
        }

        // Re-stamp the resource's locale to the user's in-app
        // language selection (see `ApertureLocalization`). Without
        // this, `String(localized:)` resolves through the bundle's
        // launch-time `preferredLocalizations` — which does NOT see
        // SwiftUI's `\.environment(\.locale)` change.
        var localizedReason = reason
        localizedReason.locale = ApertureLocalization.currentLocale
        let resolvedReason = String(localized: localizedReason)

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: resolvedReason
            )
            return success ? .success(()) : .failure(.authenticationFailed)
        } catch {
            return .failure(Self.mapError(error))
        }
    }

    // MARK: - Private mappers

    private static func mapBiometryType(_ type: LABiometryType) -> BiometryType {
        switch type {
        case .none:    return .none
        case .touchID: return .touchID
        case .faceID:  return .faceID
        case .opticID: return .opticID
        @unknown default: return .none
        }
    }

    private static func mapError(_ error: Error) -> AuthError {
        guard let laError = error as? LAError else {
            return .systemError(error)
        }
        switch laError.code {
        case .userCancel, .appCancel, .systemCancel:
            return .userCancelled
        case .authenticationFailed, .userFallback:
            return .authenticationFailed
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
            return .unavailable
        default:
            return .systemError(error)
        }
    }
}
