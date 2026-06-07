import Foundation

/// String edit-distance helpers used by the mnemonic-import advice
/// sheet to suggest the closest BIP-39 wordlist matches when the user
/// types an invalid word.
///
/// Implementation note (Rule #3 — native-only): pure-Swift Levenshtein
/// with an early-exit when the running cost exceeds the threshold.
/// O(n × m) worst case (n = candidate length, m = query length) but
/// the early-exit and the prefilter (candidates pre-filtered by
/// `abs(length difference) ≤ 3`) keep practical runs under 200
/// candidates from the 2048-word list — sub-millisecond on device.
extension String {

    /// Classic Levenshtein edit distance. Returns `Int.max` if the
    /// running distance exceeds `threshold` at any point (early exit).
    /// Case-insensitive — both sides are lowercased before comparison.
    func levenshteinDistance(to other: String, threshold: Int = Int.max) -> Int {
        let a = Array(self.lowercased())
        let b = Array(other.lowercased())
        let n = a.count
        let m = b.count

        if n == 0 { return m }
        if m == 0 { return n }
        if abs(n - m) > threshold { return Int.max }

        // Two-row rolling DP.
        var previous = Array(0...m)
        var current = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                let deletion = previous[j] + 1
                let insertion = current[j - 1] + 1
                let substitution = previous[j - 1] + cost
                current[j] = Swift.min(Swift.min(deletion, insertion), substitution)
                if current[j] < rowMinimum { rowMinimum = current[j] }
            }
            // Early-exit: if every cell in this row already exceeds
            // the threshold, no completion can be within threshold.
            if rowMinimum > threshold { return Int.max }
            swap(&previous, &current)
        }
        return previous[m]
    }

    /// Top-K closest BIP-39 wordlist matches for `self`, sorted by
    /// ascending edit distance. Filters out matches with edit distance
    /// greater than `maxDistance` (default 3 — covers single-letter
    /// typos, transpositions, missing letters, and small swaps).
    ///
    /// Returns at most `topK` entries. May return fewer (or zero) if
    /// the wordlist has no candidates within `maxDistance`.
    func bip39Suggestions(topK: Int = 3, maxDistance: Int = 3) -> [(word: String, distance: Int)] {
        let query = self.lowercased()
        let candidates = BIP39Wordlist.english
            .lazy
            .filter { abs($0.count - query.count) <= maxDistance }
            .map { word -> (word: String, distance: Int) in
                (word, query.levenshteinDistance(to: word, threshold: maxDistance))
            }
            .filter { $0.distance <= maxDistance }
            .sorted { $0.distance < $1.distance }
        return Array(candidates.prefix(topK))
    }
}
