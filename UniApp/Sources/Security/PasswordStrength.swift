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

    /// Estimate strength for `password`.
    static func estimate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return PasswordStrength(score: 0, bits: 0) }

        var pool = 0
        if password.contains(where: { $0.isLowercase }) { pool += 26 }
        if password.contains(where: { $0.isUppercase }) { pool += 26 }
        if password.contains(where: { $0.isNumber }) { pool += 10 }
        // Anything not a letter/number — symbols, punctuation, whitespace.
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
        pool = max(pool, 1)

        let length = Double(password.count)
        // Variety factor: ratio of unique characters to total, floored so a
        // long but repetitive password ("aaaaaaaaaa") doesn't read as strong.
        let unique = Double(Set(password).count)
        let variety = max(0.35, unique / length)

        let bits = length * log2(Double(pool)) * variety

        let score: Int
        switch bits {
        case ..<30:        score = 1   // any non-empty password is at least "weak"
        case 30..<50:      score = 1
        case 50..<70:      score = 2
        case 70..<100:     score = 3
        default:           score = 4
        }
        // Hard length floor: nothing under 8 characters reads above "weak".
        let floored = password.count < 8 ? min(score, 1) : score
        return PasswordStrength(score: floored, bits: bits)
    }
}
