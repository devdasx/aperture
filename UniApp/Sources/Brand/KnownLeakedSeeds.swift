import Foundation

/// Compiled-in registry of publicly-known recovery phrases and private
/// keys. Used by `MnemonicEntryView` and `PrivateKeyEntryView` to warn
/// the user when a phrase or key they're about to import is sitting in
/// public documentation, tutorials, or known scam reuse.
///
/// **Not an exhaustive scam database.** The intent is to catch the
/// obvious "tutorial seed" case — a user who copied a phrase from a
/// Hardhat config, a BIP-39 spec page, or a YouTube walkthrough and
/// genuinely didn't know it was public knowledge. Real adversarial
/// scams (a phrase someone *texted* the user) are caught by the
/// `ImportSecurityWarningSheet` ("Is this really your key?") per
/// Rule #18 + Rule #16.
///
/// **No network fetch (Rule #3).** The list is constant code.
/// Expansion happens by code edit; never by remote update.
///
/// **Comparison is normalized:**
/// - Mnemonics: lowercased + collapsed whitespace.
/// - Private keys: lowercased + stripped of `0x` prefix.
///
/// Sources for the v1 list:
/// - BIP-39 official test vectors
///   (`github.com/trezor/python-mnemonic/blob/master/vectors.json`)
/// - Hardhat default test mnemonic (hardhat.org docs)
/// - Anvil / Foundry default mnemonic (book.getfoundry.sh)
/// - Ethereum's documented "well-known" test keys
///
/// TODO: (T-032) Expand the blocklist over time as new tutorial seeds
/// surface — file open GitHub issues asking the community to flag
/// public mnemonics for inclusion.
enum KnownLeakedSeeds {

    /// Normalized form of every known-leaked mnemonic. Stored as a
    /// `Set<String>` so membership tests are O(1).
    static let leakedMnemonics: Set<String> = [
        // BIP-39 spec test vectors (12-word, the most-recognized in crypto).
        normalize("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"),
        normalize("legal winner thank year wave sausage worth useful legal winner thank yellow"),
        normalize("letter advice cage absurd amount doctor acoustic avoid letter advice cage above"),
        normalize("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong"),
        // BIP-39 spec test vectors (24-word).
        normalize("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"),
        normalize("legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"),
        normalize("letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"),
        normalize("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"),
        // Hardhat default — the most-used dev mnemonic in Ethereum.
        normalize("test test test test test test test test test test test junk"),
        // A widely-shared MetaMask/Ledger/Trezor demo seed.
        normalize("army van defense carry jealous true garbage claim echo media make crunch"),
    ]

    /// Normalized form of every known-leaked private key. Stored as a
    /// `Set<String>` so membership tests are O(1).
    static let leakedPrivateKeys: Set<String> = [
        // Ethereum "key = 1" — used in dozens of tutorials.
        "0000000000000000000000000000000000000000000000000000000000000001",
        // Hardhat default account #0 (most-funded testnet address on Earth).
        "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
        // Hardhat default account #1.
        "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        // Anvil / Foundry default account #2.
        "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
        // Ganache default mnemonic-derived #0 (historical, still seen).
        "4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d",
    ]

    /// Returns `true` if the given mnemonic words match a known-leaked
    /// phrase. Word comparison is case-insensitive and whitespace-
    /// normalized.
    static func isLeaked(mnemonic words: [String]) -> Bool {
        leakedMnemonics.contains(normalize(words.joined(separator: " ")))
    }

    /// Returns `true` if the given raw private key matches a
    /// known-leaked key. Comparison is case-insensitive and ignores
    /// `0x` prefix.
    static func isLeaked(privateKey raw: String) -> Bool {
        leakedPrivateKeys.contains(normalizeKey(raw))
    }

    // MARK: - Normalization

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizeKey(_ s: String) -> String {
        var k = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("0x") { k = String(k.dropFirst(2)) }
        return k
    }
}
