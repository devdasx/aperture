import Foundation
import LocalAuthentication

/// Canonical wrapper around `LocalAuthentication` per `CLAUDE.md` Rule #17 §B.
/// Feature code calls `authenticate(reason:)` — never imports `LAContext`
/// directly. This is the only file in Aperture that imports `LocalAuthentication`.
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
    enum BiometryType: Sendable {
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

    /// The biometry type the device currently exposes. Updated by
    /// `refresh()` / `authenticate` so a temporary lockout is not stuck
    /// for the life of a long-lived view.
    private(set) var biometryType: BiometryType

    /// `true` iff biometrics can be evaluated as of the last `refresh()`.
    /// Call `refresh()` before showing a Face ID affordance after a long
    /// gap (sheet appear, settings onAppear).
    private(set) var isAvailable: Bool

    init() {
        biometryType = .none
        isAvailable = false
        refresh()
    }

    /// Re-query `LAContext` for current availability and biometry type.
    @discardableResult
    func refresh() -> Bool {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        isAvailable = canEvaluate
        biometryType = Self.mapBiometryType(context.biometryType)
        return canEvaluate
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
        // don't want. Also refresh cached availability for UI observers.
        let context = LAContext()
        var policyError: NSError?
        let canEvaluate = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &policyError
        )
        isAvailable = canEvaluate
        biometryType = Self.mapBiometryType(context.biometryType)
        guard canEvaluate else {
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

extension BiometricService.BiometryType {
    var displayName: String {
        switch self {
        case .faceID:  return String.apertureLocalized("Face ID")
        case .touchID: return String.apertureLocalized("Touch ID")
        case .opticID: return String.apertureLocalized("Optic ID")
        case .none:    return String.apertureLocalized("Biometrics")
        }
    }

    var systemImageName: String {
        switch self {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none:    return "lock.shield"
        }
    }

    var enableReason: LocalizedStringResource {
        switch self {
        case .faceID:  return "Enable Face ID for Aperture."
        case .touchID: return "Enable Touch ID for Aperture."
        case .opticID: return "Enable Optic ID for Aperture."
        case .none:    return "Enable biometric unlock for Aperture."
        }
    }

    var unlockReason: LocalizedStringResource {
        switch self {
        case .faceID:  return "Unlock Aperture with Face ID."
        case .touchID: return "Unlock Aperture with Touch ID."
        case .opticID: return "Unlock Aperture with Optic ID."
        case .none:    return "Unlock Aperture."
        }
    }

    var disableReason: LocalizedStringResource {
        switch self {
        case .faceID:  return "Confirm turning off Face ID for Aperture."
        case .touchID: return "Confirm turning off Touch ID for Aperture."
        case .opticID: return "Confirm turning off Optic ID for Aperture."
        case .none:    return "Confirm turning off biometric unlock for Aperture."
        }
    }

    var disableSendingReason: LocalizedStringResource {
        switch self {
        case .faceID:  return "Confirm turning off Face ID for sending transactions."
        case .touchID: return "Confirm turning off Touch ID for sending transactions."
        case .opticID: return "Confirm turning off Optic ID for sending transactions."
        case .none:    return "Confirm turning off biometric authentication for sending transactions."
        }
    }

    /// Reason when authorizing "Turn Passcode Off" with biometrics.
    var turnOffPasscodeReason: LocalizedStringResource {
        switch self {
        case .faceID:  return "Confirm turning off your Aperture passcode with Face ID."
        case .touchID: return "Confirm turning off your Aperture passcode with Touch ID."
        case .opticID: return "Confirm turning off your Aperture passcode with Optic ID."
        case .none:    return "Confirm turning off your Aperture passcode."
        }
    }

    /// Reason when authorizing "Change Passcode" with biometrics.
    var changePasscodeReason: LocalizedStringResource {
        switch self {
        case .faceID:  return "Confirm changing your Aperture passcode with Face ID."
        case .touchID: return "Confirm changing your Aperture passcode with Touch ID."
        case .opticID: return "Confirm changing your Aperture passcode with Optic ID."
        case .none:    return "Confirm changing your Aperture passcode."
        }
    }

    var reenrollmentReason: LocalizedStringResource {
        switch self {
        case .faceID:  return "Confirm your new Face ID enrollment."
        case .touchID: return "Confirm your new Touch ID enrollment."
        case .opticID: return "Confirm your new Optic ID enrollment."
        case .none:    return "Confirm your biometric enrollment."
        }
    }

    var enableTitle: String {
        String(format: String.apertureLocalized("Enable %@"), displayName)
    }

    var unlockActionTitle: String {
        String(format: String.apertureLocalized("Use %@"), displayName)
    }

    var promptDescription: String {
        switch self {
        case .faceID:
            return String.apertureLocalized("Unlock Aperture and confirm transactions with a glance — without typing your PIN every time.")
        case .touchID:
            return String.apertureLocalized("Unlock Aperture and confirm transactions with your fingerprint — without typing your PIN every time.")
        case .opticID:
            return String.apertureLocalized("Unlock Aperture and confirm transactions with Optic ID — without typing your PIN every time.")
        case .none:
            return String.apertureLocalized("Unlock Aperture and confirm transactions with device biometrics — without typing your PIN every time.")
        }
    }
}
