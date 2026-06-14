import SwiftUI
import UIKit

// MARK: - Text direction resolution

/// Resolves the layout direction of a text-bearing control from its content,
/// per the Unicode BiDi algorithm's "first strong directional character"
/// rule. Used by `UniTextField` (and by the two special TextEditor sites
/// that do their own overlay rendering — `MnemonicEntryView` and
/// `WatchOnlyEntryView`) to make a single field flip cleanly between LTR
/// and RTL based on what the user is typing, regardless of the app's
/// ambient locale.
///
/// **Rule #11 — direction overrides on text-bearing controls.** Rule #11
/// forbids `\.environment(\.layoutDirection, ...)` overrides outside the
/// app root, with a per-`Text` exception. `UniTextField` is a content-
/// bearing primitive analogous to `Text`; its direction override is the
/// same exception applied to interactive text controls. The override
/// lives on the smallest possible subtree (the field's own view body),
/// never on the parent flow.
enum TextDirection {
    enum Policy {
        /// Detect from content's first strong directional character; fall
        /// back to `fallback` for empty / direction-neutral content.
        case automatic
        /// Force left-to-right. Right for technical content that is
        /// always LTR-shaped: addresses, hex keys, extended public keys,
        /// BIP-39 words, transaction IDs.
        case forceLTR
        /// Follow the app's ambient locale without overriding.
        case ambient
    }

    /// Resolves the effective `LayoutDirection` to apply to a text-bearing
    /// control. Returns `nil` for `.ambient` so the caller can choose to
    /// skip the `.environment(...)` modifier entirely and let the parent
    /// flow propagate naturally.
    static func resolve(
        policy: Policy,
        text: String,
        ambient: LayoutDirection
    ) -> LayoutDirection? {
        switch policy {
        case .ambient:
            return nil
        case .forceLTR:
            return .leftToRight
        case .automatic:
            return detect(in: text) ?? ambient
        }
    }

    /// First strong directional character heuristic. Returns `nil` for
    /// empty or fully direction-neutral content (digits + punctuation
    /// + whitespace only) so callers can fall back to ambient.
    ///
    /// Strong-RTL is the closed set (the app ships exactly four RTL
    /// locales: ar, fa, ur, he — all covered by the ranges below);
    /// every *other* letter is treated as strong-LTR via ICU's
    /// `Alphabetic` scalar property. An earlier version enumerated
    /// LTR scripts by hand and silently missed Thai, Bengali, Tamil,
    /// Telugu, Malayalam, Gurmukhi, … — all shipped locales — so
    /// `.automatic` fields fell back to ambient for them. Inverting
    /// the check makes the detector robust for all 50 languages.
    static func detect(in text: String) -> LayoutDirection? {
        for scalar in text.unicodeScalars {
            if isStrongRTL(scalar.value) { return .rightToLeft }
            // Any other letter is strong-LTR for our purposes — every
            // non-RTL script the app ships classifies its letters as
            // BiDi class L. Digits, punctuation, whitespace, and
            // symbols are weak/neutral: keep scanning.
            if scalar.properties.isAlphabetic { return .leftToRight }
        }
        return nil
    }

    private static func isStrongRTL(_ v: UInt32) -> Bool {
        // Arabic-Indic digits (U+0660–0669) and extended Arabic-Indic
        // digits (U+06F0–06F9) are BiDi class AN (weak), not strong-RTL
        // — carve them out of the blanket Arabic-block range below.
        if (0x0660...0x0669).contains(v) { return false }
        if (0x06F0...0x06F9).contains(v) { return false }
        // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, etc.
        if (0x0590...0x08FF).contains(v) { return true }
        // Hebrew presentation forms.
        if (0xFB1D...0xFB4F).contains(v) { return true }
        // Arabic presentation forms A + B.
        if (0xFB50...0xFDFF).contains(v) { return true }
        if (0xFE70...0xFEFF).contains(v) { return true }
        return false
    }
}

// MARK: - Unified text field

/// Single canonical text input primitive for UniApp. Wraps `TextField`
/// (single-line or vertical-axis multi-line) and `SecureField` behind one
/// API with one visual register, an optional eye-toggle for secure entry,
/// and content-aware RTL/LTR direction resolution.
///
/// **Design — visual register**: rounded `UniColors.Background.secondary`
/// fill (`UniRadius.m`), horizontal padding `UniSpacing.m`, vertical
/// padding `UniSpacing.s`, `UniTypography.body`. Eye toggle (when
/// `showsRevealToggle` is true) sits at the field's trailing edge —
/// trailing flips with the resolved layout direction so the eye always
/// lands on the visual end of the field regardless of script.
///
/// **Direction policy**: `.automatic` is the default. Set `.forceLTR` for
/// addresses, hex keys, xpub/ypub/zpub, BIP-39 phrases — content that is
/// always LTR-shaped regardless of the app's locale. Set `.ambient` to
/// follow the app's locale unchanged (rare; usually the wrong choice for
/// any field that accepts free-form user-script text).
///
/// **Submit contract (Enter = dismiss keyboard, never newline).** The
/// Return / Enter key dismisses the keyboard on every variant of this
/// primitive — single-line and multi-line. Single-line uses the native
/// `.onSubmit { ... }` path. Multi-line (`axis: .vertical`) cannot use
/// `.onSubmit` — iOS treats Enter as a literal newline insertion on
/// `TextField(axis: .vertical)` / `TextEditor`, so `.onSubmit` never
/// fires. Instead `.onChange(of: text)` strips EVERY newline character
/// (`\n`, `\r`, `\r\n`, Unicode separators) the instant one appears and
/// resigns focus. This is exhaustive (not a fragile trailing-diff match)
/// and safe because the multi-line `UniTextField` only ever holds
/// newline-free content — a recipient address, a contract / mint
/// address, a revealed private key, an extended public key. See
/// `CLAUDE.md` Rule #19 §D for the canonical-primitive extension
/// protocol this contract follows.
struct UniTextField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var directionPolicy: TextDirection.Policy = .automatic
    var isSecure: Bool = false
    var showsRevealToggle: Bool = false
    var axis: Axis = .horizontal
    var lineLimit: Int? = nil
    /// Corner radius of the field's fill. Defaults to the standard input
    /// radius; callers can soften it (e.g. the Send recipient field uses
    /// `UniRadius.xxxl`).
    var cornerRadius: CGFloat = UniRadius.m
    /// The field's fill surface. Defaults to `UniColors.Background.secondary`
    /// (the standard rounded-input look). Pass `Color.clear` when the field
    /// lives inside a container that already owns the surface — e.g. the
    /// Send recipient list's inset-grouped `UniCard`, where each field is a
    /// PLAIN row inside one connected container (no per-field pill). The
    /// fill is a `UniColors` role at the call site, never a literal except
    /// `Color.clear` (Rule #4 permits `.clear` everywhere). Token-typed.
    var fill: Color = UniColors.Background.secondary
    /// Vertical padding inside the field's fill. Defaults to `UniSpacing.s`
    /// (the standard input height). Callers can tighten it for a more
    /// compact field — the Send recipient field passes `UniSpacing.xs` so
    /// its EMPTY single-line state reads compact, while still growing to
    /// show a full pasted address (the `axis: .vertical` growth is
    /// unaffected). Token-typed; never a raw literal (Rule #4).
    var verticalPadding: CGFloat = UniSpacing.s
    var reservesSpace: Bool = false
    var contentType: UITextContentType? = nil
    var keyboardType: UIKeyboardType = .default
    var minHeight: CGFloat? = nil
    var autocapitalization: TextInputAutocapitalization = .never
    var disablesAutocorrection: Bool = true

    /// Optional EXTERNAL focus passthrough so a parent can track which
    /// field (by identity) is currently focused — used by the Send
    /// recipient list to prune an emptied, unfocused field on focus
    /// change. When both `focusBinding` and `focusValue` are provided,
    /// the field also reports its focus identity up to the parent's
    /// `@FocusState`. This coexists with the private `isFieldFocused`
    /// (which drives the Enter-dismiss contract) — the two focus
    /// modifiers are independent and both observe the same first
    /// responder. Nil for the 6 call sites that don't need identity
    /// tracking, so they're untouched.
    var focusBinding: FocusState<UUID?>.Binding? = nil
    var focusValue: UUID? = nil

    @State private var isRevealed: Bool = false
    @FocusState private var isFieldFocused: Bool
    @Environment(\.layoutDirection) private var ambientDirection

    /// Memoized result of the `.automatic` policy's first-strong-
    /// character scan. Recomputed only when the text changes (and once
    /// on appear) instead of on every body evaluation — the scan walks
    /// the buffer's unicode scalars, which is wasteful to repeat per
    /// render. `nil` means "no strong directional character found";
    /// the resolver then falls back to the ambient direction. Unused
    /// for `.forceLTR` / `.ambient`, which resolve without scanning.
    @State private var detectedDirection: LayoutDirection?

    var body: some View {
        ZStack(alignment: .trailing) {
            inputControl
                .focused($isFieldFocused)
                .modifier(ExternalFocusModifier(binding: focusBinding, value: focusValue))
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(disablesAutocorrection)
                .keyboardType(keyboardType)
                .textContentType(contentType)
                .font(UniTypography.body)
                .modifier(LineLimitModifier(limit: lineLimit, reservesSpace: reservesSpace))
                .padding(.horizontal, UniSpacing.m)
                .padding(.vertical, verticalPadding)
                .padding(.trailing, (showsRevealToggle && isSecure) ? 40 : 0)
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fill)
                )
                .multilineTextAlignment(.leading)
                // Single-line: Return key reads as "Done" and fires
                // `.onSubmit { ... }` natively. `.submitLabel(.done)` is
                // applied unconditionally — on multi-line the modifier
                // is a no-op (iOS forces Return = newline glyph there).
                .submitLabel(.done)
                .onSubmit {
                    isFieldFocused = false
                }
                // Multi-line: iOS inserts a newline char on Enter and
                // does NOT fire `.onSubmit`. The Return key (or a pasted
                // newline) must dismiss the keyboard, never insert a line
                // break. The multi-line `UniTextField` only ever holds
                // content that legitimately contains NO newlines — a
                // recipient address, a contract / mint address, a revealed
                // private key, an extended public key — so the robust,
                // correct behavior is to strip EVERY newline character
                // (`\n`, `\r`, `\r\n`, Unicode line/paragraph separators)
                // the instant one appears and resign focus.
                //
                // The prior implementation matched only the exact diff
                // `newValue == oldValue + "\n"` — a single `\n` appended
                // at the very END of the buffer. A mid-buffer Enter, a
                // `\r` / `\r\n`, or any inexact diff slipped through and
                // left a visible line break (the user-reported bug).
                // Stripping via `\.isNewline` (which covers the whole
                // Unicode newline set) is exhaustive and safe here.
                //
                // Single-line fields never receive a newline in `text`
                // (Return fires `.onSubmit` instead), so this branch only
                // ever affects the multi-line (`axis: .vertical`) controls.
                .onChange(of: text) { _, newValue in
                    if newValue.contains(where: \.isNewline) {
                        text = newValue.filter { !$0.isNewline }
                        isFieldFocused = false
                        return
                    }
                    // Fix #8 memoization — re-run the direction scan
                    // only when the text actually changed (not on
                    // every body evaluation).
                    if directionPolicy == .automatic {
                        detectedDirection = TextDirection.detect(in: newValue)
                    }
                }
                .onAppear {
                    if directionPolicy == .automatic {
                        detectedDirection = TextDirection.detect(in: text)
                    }
                }

            if showsRevealToggle && isSecure {
                revealButton
            }
        }
        // One coordinate system for the whole field: the direction
        // override wraps the ZStack so its `.trailing` alignment, the
        // reveal-eye clearance `.padding(.trailing, …)`, and the input
        // control all resolve against the SAME resolved direction.
        // When the override wrapped only `inputControl`, the eye
        // anchored to the AMBIENT trailing edge while the 40pt gap
        // followed the resolved direction — in an RTL locale with
        // `.forceLTR` (private-key import) the eye overlapped the
        // start of the secure text and the gap sat unused.
        .modifier(DirectionOverride(direction: resolvedDirection))
    }

    // MARK: - Input control variant

    @ViewBuilder
    private var inputControl: some View {
        if isSecure && !isRevealed {
            SecureField(placeholder, text: $text)
        } else if axis == .vertical {
            TextField(placeholder, text: $text, axis: .vertical)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    // MARK: - Reveal button

    private var revealButton: some View {
        Button {
            isRevealed.toggle()
            isFieldFocused = true
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .padding(.horizontal, UniSpacing.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Direction resolution

    /// Resolves without scanning: `.ambient` and `.forceLTR` are
    /// constant-time, and `.automatic` reads the memoized
    /// `detectedDirection` (updated in `.onChange(of: text)` /
    /// `.onAppear`) rather than re-walking the buffer's scalars on
    /// every body evaluation.
    private var resolvedDirection: LayoutDirection? {
        switch directionPolicy {
        case .ambient:
            return nil
        case .forceLTR:
            return .leftToRight
        case .automatic:
            return detectedDirection ?? ambientDirection
        }
    }
}

// MARK: - Modifiers

private struct DirectionOverride: ViewModifier {
    let direction: LayoutDirection?

    func body(content: Content) -> some View {
        if let direction {
            content.environment(\.layoutDirection, direction)
        } else {
            content
        }
    }
}

/// Applies the OPTIONAL external `.focused(_:equals:)` only when a parent
/// supplied both a binding and an identity value. This is additive — the
/// private `.focused($isFieldFocused)` (which drives the Enter-dismiss
/// contract) is always applied; this second modifier reports the field's
/// focus identity up to the parent's `@FocusState<UUID?>`. SwiftUI
/// supports multiple independent `.focused` modifiers on one view, each
/// tracking a different FocusState — both observe the same first responder.
private struct ExternalFocusModifier: ViewModifier {
    let binding: FocusState<UUID?>.Binding?
    let value: UUID?

    func body(content: Content) -> some View {
        if let binding, let value {
            content.focused(binding, equals: value)
        } else {
            content
        }
    }
}

private struct LineLimitModifier: ViewModifier {
    let limit: Int?
    let reservesSpace: Bool

    func body(content: Content) -> some View {
        if let limit {
            content.lineLimit(limit, reservesSpace: reservesSpace)
        } else {
            content
        }
    }
}
