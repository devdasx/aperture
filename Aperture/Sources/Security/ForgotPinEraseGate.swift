import Foundation

/// P1-010: lock-screen / Forgot-PIN erase must never unlock unless the
/// factory wipe fully cleared spendable secrets.
///
/// Pure policy — no UI, no side effects. `AppLockView.eraseEverything`
/// calls this after `FactoryReset.performFullWipe` so a failed or
/// incomplete wipe cannot leave a partial DB + unlocked UI.
enum ForgotPinEraseGate {

    enum Outcome: Equatable, Sendable {
        /// Wipe succeeded and no residual wallets/secrets/PIN remain.
        case unlock
        /// Stay on the lock overlay; user must retry or recover offline.
        case stayLocked(reason: StayLockedReason)
    }

    enum StayLockedReason: Equatable, Sendable {
        /// `performFullWipe` threw (transaction failed or incomplete).
        case wipeFailed
        /// Wipe returned without throw but residual secrets still present.
        case residualSecrets
    }

    /// Decide whether the lock overlay may dismiss after an erase attempt.
    ///
    /// - Parameters:
    ///   - wipeSucceeded: `true` only when `FactoryReset.performFullWipe`
    ///     completed without throwing.
    ///   - residualSecrets: `true` when wallets, `wallet_secrets`, or PIN
    ///     material still exist (see `FactoryReset.hasResidualSpendableSecrets`).
    static func outcome(wipeSucceeded: Bool, residualSecrets: Bool) -> Outcome {
        guard wipeSucceeded else { return .stayLocked(reason: .wipeFailed) }
        guard !residualSecrets else { return .stayLocked(reason: .residualSecrets) }
        return .unlock
    }
}
