import Foundation

/// `SVGSanitizer` accepts user-supplied SVG text, strips every documented
/// active-content vector, and returns a passive-markup substring safe to
/// hand to `WKWebView` for rendering inside the wallet-avatar disc.
///
/// **Why this exists.** Per the 2026-06-09 v3 design handoff's Upload
/// tab: the user can pick their own `.svg` file as a wallet identity
/// mark. Raw SVG can carry `<script>`, `<foreignObject>` (which can
/// embed HTML), `on*` event handlers, and `href` / `xlink:href`
/// attributes pointing at remote resources or `javascript:` URLs. None
/// of those are appropriate for a passive identity glyph. The sanitizer
/// removes them; what remains is shape + path + fill markup that
/// `WKWebView` can render with no script context at all.
///
/// **Rule #16 (security surfaces convey safety deliberately).** The
/// sanitizer is honest: it strips the documented vectors below, and it
/// rejects what it cannot sanitize. It does NOT pretend to "block all
/// malicious SVG" — passive SVG attack surfaces (e.g. complex filter
/// chains designed to hang the rasterizer) are out of scope. What the
/// sanitizer is is a small, audit-by-eye filter against the surfaces
/// the design handoff specifically calls out, matched against the JS
/// reference engine `sanitizeSvg(...)` verbatim.
///
/// **Rule #3 (native-only).** Pure `Foundation` + `NSRegularExpression`.
/// No third-party SVG library, no XML parser dependency. `String`-level
/// regex matches the JS reference's regex shape so a future audit can
/// re-read the JS and confirm parity.
///
/// **Rule #5 (typed throws).** Errors are an enum so the picker view can
/// branch on them and surface a clear message to the user.
///
/// ### The 14 documented sanitization steps (in order)
///
/// 1. **Byte-size precheck.** Reject if the UTF-8 byte count of the
///    input exceeds `maxBytes` (50 KB ceiling per the brief). The
///    ceiling protects against parser pathologies AND against a user
///    bundling a megabyte-scale SVG that would balloon the Keychain
///    manifest on `WalletManifestStore.sync(...)`.
/// 2. **Strip XML prolog** — `<?xml ... ?>` blocks. These carry no
///    visual content; only encoding declarations that `WKWebView`
///    can already infer.
/// 3. **Strip DOCTYPE** — `<!DOCTYPE ... >` blocks. DOCTYPE references
///    to remote DTDs were a classic billion-laughs attack vector; we
///    drop the whole declaration regardless.
/// 4. **Strip paired `<script>...</script>` blocks.** The single
///    biggest active-content surface in SVG. WKWebView would run it.
/// 5. **Strip paired `<foreignObject>...</foreignObject>` blocks.**
///    Embeds HTML inside SVG, which drags HTML's full attack surface
///    back into the renderer.
/// 6. **Strip double-quoted `on*` event handlers** — `onclick="..."`,
///    `onload="..."`, etc. Passive identity content doesn't fire events.
/// 7. **Strip single-quoted `on*` event handlers** — same as #6, single
///    quotes. (The JS reference splits these into two regexes; we mirror.)
/// 8. **Neutralize remote / `javascript:` `href` attributes.** Any
///    `href` / `xlink:href` whose value starts with `http://`,
///    `https://`, or `javascript:` is rewritten to `#`. We keep the
///    attribute syntactically valid so structural elements aren't
///    broken; we discard the value.
/// 9. **Strip self-closing / unpaired `<script ...>` tags** (and stray
///    `</script>` close tags). Step 4 only matches the PAIRED form —
///    `<script src="..."/>` or a dangling open tag would survive it.
/// 10. **Strip self-closing / unpaired `<foreignObject ...>` tags**
///    (and stray `</foreignObject>` close tags) — same gap as step 9
///    for step 5's paired-form regex.
/// 11. **Remove `url(...)` references** across the whole document. CSS
///    `url()` (in `style` attributes, `<style>` blocks, or
///    presentation attributes like `fill`) can fetch remote resources
///    — an exfiltration / tracking beacon vector. This also removes
///    internal `url(#id)` gradient references; a flat-rendered glyph
///    is the accepted cost of closing the channel.
/// 12. **Remove `expression(...)`** — legacy CSS expression() script
///    injection; no legitimate use in an identity glyph.
/// 13. **Neutralize `javascript:` and `data:` schemes inside
///    `href` / `xlink:href` / `src` / `style` attribute values** —
///    the scheme token is replaced with `#` wherever it appears in
///    the value, not only at the start (catches whitespace /
///    entity-obfuscated forms that step 8's prefix match misses,
///    and `data:` documents that can smuggle nested active content).
/// 14. **Extract the first `<svg ... </svg>` substring**, trim
///    whitespace, return. If no `<svg>` tag is present in what remains,
///    throw `.notSVG`. If extraction succeeds but yields an empty
///    string after trim, throw `.sanitizedToEmpty`.
///
/// ### Steps that are intentionally NOT done
///
/// - **No tag whitelist.** The brief's reference engine doesn't whitelist
///   (it strips and lets the renderer accept the rest), so neither do
///   we. A future hardening pass can add one if specific vectors emerge.
/// - **No full CSS sanitization.** Inline `style="..."` survives apart
///   from the `url(...)` / `expression(...)` / scheme passes above;
///   other WebKit-supported CSS (filters, transforms) is out-of-scope
///   here. The brief explicitly leaves the rest to the renderer's CSP.
public enum SVGSanitizer {

    /// 50 KB byte ceiling per the v3 brief. UTF-8 bytes, not character
    /// count — same metric the writer code will see when persisting
    /// the string.
    public static let maxBytes: Int = 50 * 1024

    /// Typed errors surfaced to the picker view. The picker maps each
    /// case to a localized inline message under the upload button.
    public enum SanitizeError: Error, Sendable, Equatable {
        /// The input does not contain a recognizable `<svg>` element.
        case notSVG
        /// The input exceeded `maxBytes`. `actualBytes` exposes the
        /// caller's reading; `maxBytes` is the ceiling for context.
        case tooLarge(actualBytes: Int, maxBytes: Int)
        /// After stripping, what remained was empty. Rare — typically
        /// means the file was a `<script>`-only payload or a comment.
        case sanitizedToEmpty
    }

    /// Run the 14 sanitization steps in order. Throws on every failure
    /// mode; returns the cleaned `<svg>...</svg>` substring on success.
    ///
    /// - parameter text: raw `String` decoded from the user-selected
    ///   file's contents.
    public static func sanitize(_ text: String) throws -> String {
        // Step 1 — size precheck.
        let bytes = text.utf8.count
        guard bytes <= maxBytes else {
            throw SanitizeError.tooLarge(actualBytes: bytes, maxBytes: maxBytes)
        }

        // Steps 2–8 — successive regex passes. Each replaces matches
        // with the empty string or, for the href rewrite, a neutral
        // fragment.
        var s = text

        // Step 2 — XML prolog.
        s = stripAll(in: s, pattern: #"<\?xml[\s\S]*?\?>"#)
        // Step 3 — DOCTYPE.
        s = stripAll(in: s, pattern: #"<!DOCTYPE[\s\S]*?>"#)
        // Step 4 — script blocks.
        s = stripAll(in: s, pattern: #"<script[\s\S]*?</script>"#)
        // Step 5 — foreignObject blocks.
        s = stripAll(in: s, pattern: #"<foreignObject[\s\S]*?</foreignObject>"#)
        // Step 6 — on* event handlers (double-quoted).
        s = stripAll(in: s, pattern: #"\son\w+="[^"]*""#)
        // Step 7 — on* event handlers (single-quoted).
        s = stripAll(in: s, pattern: #"\son\w+='[^']*'"#)
        // Step 8 — neutralize remote / javascript href attributes. The
        // JS reference rewrites `href="https://..."` to `href="#"` and
        // `xlink:href='https://...'` to `xlink:href='#'`. We do the
        // same in two regexes (one per attribute name × one per quote
        // style ≈ four passes) so the replacement preserves the
        // attribute's quote style.
        s = neutralizeHrefs(in: s)

        // Step 9 — self-closing / unpaired script tags (the paired-form
        // regex in step 4 misses `<script src="..."/>` and dangling
        // open tags), plus stray close tags.
        s = stripAll(in: s, pattern: #"<script\b[^>]*/?>"#)
        s = stripAll(in: s, pattern: #"</script\s*>"#)
        // Step 10 — self-closing / unpaired foreignObject tags (same
        // paired-form gap as step 9, for step 5's regex).
        s = stripAll(in: s, pattern: #"<foreignObject\b[^>]*/?>"#)
        s = stripAll(in: s, pattern: #"</foreignObject\s*>"#)
        // Step 11 — CSS url(...) references, document-wide. Remote
        // fetch / exfiltration channel; internal `url(#id)` gradient
        // refs are an accepted casualty.
        s = stripAll(in: s, pattern: #"url\s*\([^)]*\)"#)
        // Step 12 — legacy CSS expression(...) script injection.
        s = stripAll(in: s, pattern: #"expression\s*\([^)]*\)"#)
        // Step 13 — javascript:/data: schemes anywhere inside
        // href / xlink:href / src / style attribute values → `#`.
        s = neutralizeDangerousSchemes(in: s)

        // Step 14 — extract first <svg> ... </svg> substring.
        guard let svgRange = firstSVGRange(in: s) else {
            throw SanitizeError.notSVG
        }
        let extracted = String(s[svgRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extracted.isEmpty else { throw SanitizeError.sanitizedToEmpty }
        return extracted
    }

    // MARK: - Regex helpers
    //
    // `NSRegularExpression` is the system primitive; per Rule #3 we
    // don't pull a Swift-regex DSL. The two helpers below wrap the
    // common shapes the steps above call.

    /// Replace every match of `pattern` (case-insensitive,
    /// dot-matches-newlines via the `[\s\S]` idiom used in the JS
    /// reference) with the empty string. Returns the input unchanged
    /// if the pattern fails to compile (defensive only; the inline
    /// patterns above are static and known-valid).
    private static func stripAll(in input: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    /// Rewrite every `href` / `xlink:href` attribute whose value starts
    /// with `http://`, `https://`, or `javascript:` to `="#"`. Preserves
    /// the original attribute name and quote style so the SVG remains
    /// syntactically valid.
    ///
    /// We run four passes (two attribute names × two quote styles)
    /// instead of one combined regex — the four passes are tiny on
    /// 50 KB max input, and keeping them separate lets each pattern
    /// stay readable. The JS reference uses one combined pattern; the
    /// outcome is identical.
    private static func neutralizeHrefs(in input: String) -> String {
        var out = input
        let attributes = ["href", "xlink:href"]
        let schemes = "(?:https?:|javascript:)"
        for attr in attributes {
            // Double-quoted.
            let doublePattern =
                "(\(attr))\\s*=\\s*\"\\s*\(schemes)[^\"]*\""
            out = replaceAll(
                in: out,
                pattern: doublePattern,
                template: "$1=\"#\""
            )
            // Single-quoted.
            let singlePattern =
                "(\(attr))\\s*=\\s*'\\s*\(schemes)[^']*'"
            out = replaceAll(
                in: out,
                pattern: singlePattern,
                template: "$1='#'"
            )
        }
        return out
    }

    /// Step 13 — replace every `javascript:` / `data:` scheme token
    /// that appears INSIDE an `href` / `xlink:href` / `src` / `style`
    /// attribute value with `#`, wherever in the value it sits (not
    /// only at the start — step 8 already handles the prefix case for
    /// hrefs). Two patterns, one per quote style; each pattern anchors
    /// at the attribute name, so a value carrying multiple scheme
    /// tokens needs multiple passes — we loop to a fixpoint. The loop
    /// terminates because every pass strictly removes at least one
    /// scheme token and the `#` replacement can never recombine into
    /// a new `javascript:` / `data:` token; the iteration cap is a
    /// defensive backstop, after which the remaining (at most a
    /// handful of) tokens are inert fragments inside already-
    /// neutralized values.
    private static func neutralizeDangerousSchemes(in input: String) -> String {
        let attrs = "(?:href|xlink:href|src|style)"
        let schemes = #"(?:javascript|data)\s*:"#
        let doublePattern = "(\(attrs)\\s*=\\s*\"[^\"]*?)\(schemes)"
        let singlePattern = "(\(attrs)\\s*=\\s*'[^']*?)\(schemes)"
        var out = input
        for _ in 0..<32 {
            var next = replaceAll(in: out, pattern: doublePattern, template: "$1#")
            next = replaceAll(in: next, pattern: singlePattern, template: "$1#")
            if next == out { break }
            out = next
        }
        return out
    }

    /// Wrap `NSRegularExpression.stringByReplacingMatches(...)` for the
    /// href rewrite. Distinct from `stripAll` only because it threads a
    /// non-empty template.
    private static func replaceAll(
        in input: String,
        pattern: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    /// Locate the first `<svg ... </svg>` substring (inclusive of both
    /// tags). Returns the matching `Range<String.Index>` or `nil` if
    /// no `<svg>` tag is present.
    ///
    /// `[\s\S]` (any character incl. newlines) inside the body keeps
    /// the JS reference's behavior — the user's SVG can span hundreds
    /// of lines and we want the whole element.
    private static func firstSVGRange(in input: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<svg[\s\S]*</svg>"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let nsRange = NSRange(input.startIndex..., in: input)
        guard
            let match = regex.firstMatch(in: input, options: [], range: nsRange),
            let range = Range(match.range, in: input)
        else { return nil }
        return range
    }
}
