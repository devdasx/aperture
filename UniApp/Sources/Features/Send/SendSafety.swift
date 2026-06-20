import Foundation

/// **Money-safety checks for the Send recipient step**
/// (`design_handoff_send_v2` Flow A3 + D2). Pure, synchronous logic over
/// real data — no network, no fabrication:
///
/// - **Lookalike / address-poisoning** — a freshly pasted or scanned
///   address that mimics a known address's first + last characters but
///   differs in the middle. This is the classic *address-poisoning* attack:
///   an attacker sends a dust transaction from a vanity address crafted to
///   look like one the victim already transacts with, so that when the
///   victim later copies "their" address from transaction history they copy
///   the attacker's instead. We catch it by comparing a fresh paste against
///   the wallet's real recent recipients (and, later, saved contacts).
///
/// - **Wrong-network** — an address that is invalid for the chain being
///   sent on, but VALID on a *different* supported chain's address space, so
///   the recipient step can name the chain the user probably meant instead
///   of a bare "invalid address".
enum SendSafety {

    // MARK: - Lookalike (address poisoning)

    /// A known address that a freshly pasted value imitates.
    struct Lookalike: Equatable, Identifiable {
        /// The real address the wallet already knows (the safe one).
        let knownAddress: String
        /// The freshly pasted value that imitates it.
        let pastedAddress: String
        /// How many leading / trailing characters the two genuinely share
        /// (drives the compare-card highlighting — the matching ends are
        /// bold, the differing middle stands out).
        let sharedPrefix: Int
        let sharedSuffix: Int

        var id: String { knownAddress + "|" + pastedAddress }
    }

    /// Leading / trailing match window. An attacker crafts an address whose
    /// truncated display form (`0xAbcd…1234`) matches a real one; requiring
    /// a match of `window` characters on EACH end catches that while keeping
    /// random-collision false positives astronomically unlikely (a chance
    /// match of 6+6 hex characters is ~1 in 16^12).
    private static let window = 6

    private static func normalized(_ address: String, chain: SupportedChain) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return chain.family == .evm ? trimmed.lowercased() : trimmed
    }

    /// The known address `pasted` imitates, if any. `known` is the wallet's
    /// real set of addresses for this chain (recent recipients today; saved
    /// contacts once those exist). An exact match is NOT a lookalike — it's
    /// the user reusing a known-good address.
    static func lookalike(
        for pasted: String,
        among known: [String],
        chain: SupportedChain
    ) -> Lookalike? {
        let candidate = normalized(pasted, chain: chain)
        guard candidate.count >= window * 2 else { return nil }
        let candidatePrefix = candidate.prefix(window)
        let candidateSuffix = candidate.suffix(window)

        for rawKnown in known {
            let knownNorm = normalized(rawKnown, chain: chain)
            guard knownNorm != candidate, knownNorm.count >= window * 2 else { continue }
            if knownNorm.prefix(window) == candidatePrefix,
               knownNorm.suffix(window) == candidateSuffix {
                return Lookalike(
                    knownAddress: rawKnown,
                    pastedAddress: pasted,
                    sharedPrefix: sharedLeading(candidate, knownNorm),
                    sharedSuffix: sharedTrailing(candidate, knownNorm)
                )
            }
        }
        return nil
    }

    // MARK: - Wrong network

    /// The chain the pasted address actually belongs to, when it is invalid
    /// for `intendedChain` but valid on a DIFFERENT address space. Skips
    /// same-family chains (an EVM address is valid on every EVM chain — that
    /// is not a wrong-network mistake, just the shared EVM address space).
    /// Returns the first matching chain; the caller decides whether it can
    /// offer a switch.
    static func wrongNetwork(
        for pasted: String,
        intendedChain: SupportedChain
    ) -> SupportedChain? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !RecipientResolver.isValidAddress(trimmed, for: intendedChain) else { return nil }
        for chain in SupportedChain.allCases {
            guard chain != intendedChain, chain.family != intendedChain.family else { continue }
            if RecipientResolver.isValidAddress(trimmed, for: chain) {
                return chain
            }
        }
        return nil
    }

    // MARK: - Shared-end measurement (for the compare-card highlight)

    private static func sharedLeading(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            if x == y { count += 1 } else { break }
        }
        return count
    }

    private static func sharedTrailing(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a.reversed(), b.reversed()) {
            if x == y { count += 1 } else { break }
        }
        return count
    }
}
