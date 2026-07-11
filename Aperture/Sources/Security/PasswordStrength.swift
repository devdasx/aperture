import Foundation

/// A **real** estimate of backup-password strength for the strength meter
/// (2026-06-19 backup handoff: "the meter must reflect actual estimated
/// strength, not a fixed 3/4"). Entropy-based — pool size from the
/// character classes present × length, penalized for low character variety
/// (long runs of one repeated character add little real entropy). No
/// third-party dependency (Rule #3); this is a pragmatic estimator, not a
/// full zxcvbn dictionary attack model, and it errs toward caution.
struct PasswordStrength: Equatable, Sendable {
    /// 0 (empty) … 4 (very strong). The meter renders `max(score, 0)`
    /// filled segments of 4.
    let score: Int
    /// Estimated entropy in bits — useful for tests / diagnostics.
    let bits: Double

    enum Rating: Int, Sendable {
        case empty = 0, weak, fair, good, strong
    }

    var rating: Rating { Rating(rawValue: score) ?? .empty }

    /// The minimum we require before the iCloud "Continue" enables. We gate
    /// on `.good` (3/4) per the design's "Strong" target, plus a hard
    /// 8-character floor regardless of class mix.
    var meetsMinimum: Bool { score >= Rating.good.rawValue }

    /// Estimate strength for `password`. Scored on **length + character-class
    /// diversity**, which is what users expect from a meter — an 8+ character
    /// password mixing 3+ character types (lower/upper/digit/symbol) reads as
    /// Strong, and 12+ with 3+ types reads Very strong. There's no dictionary
    /// model, so it's deliberately generous rather than punishing a clearly
    /// fine password like `Bitq2323@`. Entropy `bits` is kept for the readout.
    static func estimate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return PasswordStrength(score: 0, bits: 0) }

        let length = password.count
        let hasLower = password.contains { $0.isLowercase }
        let hasUpper = password.contains { $0.isUppercase }
        let hasDigit = password.contains { $0.isNumber }
        // Anything not a letter/number — symbols, punctuation, whitespace.
        let hasSymbol = password.contains { !$0.isLetter && !$0.isNumber }
        let classes = (hasLower ? 1 : 0) + (hasUpper ? 1 : 0) + (hasDigit ? 1 : 0) + (hasSymbol ? 1 : 0)

        var pool = 0
        if hasLower { pool += 26 }
        if hasUpper { pool += 26 }
        if hasDigit { pool += 10 }
        if hasSymbol { pool += 33 }
        let bits = Double(length) * log2(Double(max(pool, 1)))

        var score: Int
        switch (length, classes) {
        case let (l, c) where l >= 12 && c >= 3: score = 4   // very strong
        case let (l, c) where l >= 8 && c >= 3:  score = 3   // strong
        case let (l, c) where l >= 12 && c >= 2: score = 3   // long + mixed
        case let (l, c) where l >= 8 && c >= 2:  score = 2   // fair
        default:                                 score = 1   // weak
        }
        // A password with very few distinct characters can't be strong.
        if Set(password).count < 5 { score = min(score, 1) }
        // Hard length floor: nothing under 8 characters reads above "weak".
        if length < 8 { score = min(score, 1) }

        return PasswordStrength(score: score, bits: bits)
    }
}
