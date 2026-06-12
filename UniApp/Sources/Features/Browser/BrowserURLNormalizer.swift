import Foundation

/// Resolves what the user typed in the URL bar into a real `URL`.
/// Mirrors mobile Safari's smart URL bar:
///
/// - **A real URL** (`https://app.uniswap.org` / `app.uniswap.org`):
///   parse and use directly. Scheme defaults to `https://` when
///   missing.
/// - **A bare hostname** (`uniswap.org`, `foo.eth`): treated as
///   a URL with `https://` prepended.
/// - **A search term** (`uniswap`, `how to bridge to base`): handed
///   off to Google's `/search?q=…` endpoint.
///
/// **Why Google, not the user's chosen engine.** Today Aperture has
/// no engine-preference UI. Google is the iOS Safari default and
/// the most familiar search surface; a future Settings → Browser →
/// Search engine row will switch to DuckDuckGo / Brave / Kagi.
///
/// **No telemetry.** The search is a plain GET request — Aperture
/// doesn't intermediate, doesn't tracking-fingerprint, doesn't
/// add a referrer header on top of what `WKWebView` ships by
/// default. The user's query reaches Google the same way it would
/// from mobile Safari.
///
/// **Per Rule #3** — pure stdlib. No third-party URL parser.
enum BrowserURLNormalizer {

    /// Decide whether the input is a navigable destination (`.url`)
    /// or a search query (`.search`). Pure function — callers should
    /// pass the trimmed input.
    enum Resolution: Equatable {
        case url(URL)
        case search(URL, query: String)
        case empty
    }

    /// Resolve `raw` to a destination. Leading/trailing whitespace
    /// is trimmed before classification.
    static func resolve(_ raw: String) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Looks like a real URL — has a scheme.
        if let scheme = scheme(of: trimmed),
           ["http", "https", "ftp"].contains(scheme.lowercased()) {
            if let url = URL(string: trimmed) {
                return .url(url)
            }
        }

        // Looks like a host — contains a `.` and no spaces and the
        // first segment isn't obviously English.
        if isPlausibleHost(trimmed) {
            if let url = URL(string: "https://\(trimmed)") {
                return .url(url)
            }
        }

        // Treat as search query.
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            return .search(url, query: trimmed)
        }
        return .empty
    }

    /// Extract the URL scheme if present (`https`, `http`, `wc`,
    /// `aperture`, …). Returns `nil` when the string has no `:` or
    /// the prefix doesn't look like a scheme.
    private static func scheme(of raw: String) -> String? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let prefix = raw[..<colon]
        // Schemes are alpha + alphanumeric. RFC 3986.
        guard !prefix.isEmpty else { return nil }
        let first = prefix.first!
        guard first.isLetter else { return nil }
        for ch in prefix.dropFirst() {
            guard ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == "." else { return nil }
        }
        return String(prefix)
    }

    /// Heuristic for "looks like a hostname." Contains a `.`, no
    /// spaces, no `?`, has at least one alpha character after the
    /// last `.` (the TLD).
    private static func isPlausibleHost(_ raw: String) -> Bool {
        guard raw.contains("."), !raw.contains(" "), !raw.contains("?") else { return false }
        let parts = raw.split(separator: ".")
        guard parts.count >= 2 else { return false }
        guard let tld = parts.last else { return false }
        return tld.allSatisfy { $0.isLetter || $0.isNumber }
            && tld.contains(where: { $0.isLetter })
    }

    /// Strip the URL down to its bare host for display. Hides the
    /// scheme and the path so the user reads the canonical "where
    /// am I" string.
    static func displayHost(for url: URL) -> String {
        url.host ?? url.absoluteString
    }
}
