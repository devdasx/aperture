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
/// **Design — visual register**: rounded `UniColors.Input.background`
/// fill (`UniRadius.textField`), horizontal padding `UniSpacing.mPlus`,
/// vertical padding `UniSpacing.m`, `UniTypography.body`. Eye toggle (when
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

    var font: Font = UniTypography.body
    var textAlignment: TextAlignment = .leading
    var directionPolicy: TextDirection.Policy = .automatic
    var isSecure: Bool = false
    var showsRevealToggle: Bool = false
    var axis: Axis = .horizontal
    var lineLimit: Int? = nil
    /// Corner radius of the field's fill. Defaults to the standard input
    /// radius; callers can soften it (e.g. the Send recipient field uses
    /// `UniRadius.xxxl`).
    var cornerRadius: CGFloat = UniRadius.textField
    /// The field's fill surface. Defaults to `UniColors.Input.background`
    /// (the standard rounded-input look). Pass `Color.clear` when the field
    /// lives inside a container that already owns the surface — e.g. the
    /// Send recipient list's inset-grouped `UniCard`, where each field is a
    /// PLAIN row inside one connected container (no per-field pill). The
    /// fill is a `UniColors` role at the call site, never a literal except
    /// `Color.clear` (Rule #4 permits `.clear` everywhere). Token-typed.
    var fill: Color = UniColors.Input.background
    /// Vertical padding inside the field's fill. Defaults to `UniSpacing.m`
    /// (the standard input height). Callers can tighten it for a more
    /// compact field — the Send recipient field passes `UniSpacing.xs` so
    /// its EMPTY single-line state reads compact, while still growing to
    /// show a full pasted address (the `axis: .vertical` growth is
    /// unaffected). Token-typed; never a raw literal (Rule #4).
    var verticalPadding: CGFloat = UniSpacing.m
    /// Set false for fields that live inside a larger native row/card shell
    /// and should inherit that parent surface instead of drawing their own
    /// rounded filled text-box chrome.
    var showsChrome: Bool = true
    var reservesSpace: Bool = false
    var contentType: UITextContentType? = nil
    var keyboardType: UIKeyboardType = .default
    var minHeight: CGFloat? = nil
    var autocapitalization: TextInputAutocapitalization = .never
    var disablesAutocorrection: Bool = true
    var onSubmitAction: (() -> Void)? = nil

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

    /// Optional BOOLEAN focus passthrough so a parent can both observe and
    /// drive the field's focus with a simple `@FocusState<Bool>`. Used by
    /// numeric (`.decimalPad`) sites that need to attach the
    /// `.numericDoneToolbar(_:)` accessory — the decimal pad has no Return
    /// key, so the parent owns a `Bool` focus state, binds it here, and the
    /// toolbar's Done button flips it false to dismiss. Independent of the
    /// private `isFieldFocused` and the optional `focusBinding<UUID?>`;
    /// SwiftUI permits multiple `.focused` modifiers tracking distinct
    /// states against the same first responder. Nil for every existing call
    /// site, so they're untouched.
    var boolFocusBinding: FocusState<Bool>.Binding? = nil

    @State private var isRevealed: Bool = false
    @FocusState private var isFieldFocused: Bool
    @Environment(\.layoutDirection) private var ambientDirection
    @Environment(\.isEnabled) private var isEnabled

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
                .modifier(ExternalBoolFocusModifier(binding: boolFocusBinding))
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(disablesAutocorrection)
                .keyboardType(keyboardType)
                .textContentType(contentType)
                .font(font)
                .foregroundStyle(isEnabled ? UniColors.Input.text : UniColors.Input.disabledText)
                .modifier(LineLimitModifier(limit: lineLimit, reservesSpace: reservesSpace))
                .padding(.horizontal, UniSpacing.mPlus)
                .padding(.vertical, verticalPadding)
                .padding(.trailing, (showsRevealToggle && isSecure) ? 40 : 0)
                .frame(minHeight: resolvedMinHeight)
                .background(inputChrome)
                .tint(UniColors.Tint.accent)
                .multilineTextAlignment(textAlignment)
                // Single-line: Return key reads as "Done" and fires
                // `.onSubmit { ... }` natively. `.submitLabel(.done)` is
                // applied unconditionally — on multi-line the modifier
                // is a no-op (iOS forces Return = newline glyph there).
                .submitLabel(.done)
                .onSubmit {
                    isFieldFocused = false
                    onSubmitAction?()
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
                        onSubmitAction?()
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
                .foregroundStyle(UniColors.Input.revealIcon)
                .padding(.horizontal, UniSpacing.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var inputChrome: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(inputFill)
    }

    private var inputFill: Color {
        guard showsChrome else { return fill }
        guard isEnabled else { return UniColors.Input.disabledBackground }
        return isFieldFocused ? UniColors.Input.focusedBackground : fill
    }

    private var resolvedMinHeight: CGFloat? {
        minHeight ?? (showsChrome ? UniSpacing.xxxl : nil)
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

// MARK: - Unified text area

/// Multiline companion to `UniTextField` for paste-heavy inputs that must
/// preserve line breaks, such as watch-only address lists. It shares the
/// same color, radius, padding, focus, and direction behavior as the
/// single-line primitive, but keeps interior pasted newlines intact.
struct UniTextArea: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var directionPolicy: TextDirection.Policy = .automatic
    var font: Font = UniTypography.body
    var minHeight: CGFloat = 140
    var cornerRadius: CGFloat = UniRadius.textField
    var fill: Color = UniColors.Input.background
    var verticalPadding: CGFloat = UniSpacing.m
    var horizontalPadding: CGFloat = UniSpacing.mPlus
    var autocapitalization: TextInputAutocapitalization = .never
    var disablesAutocorrection: Bool = true
    var onReturnKey: ((String) -> Void)? = nil

    @FocusState private var isFieldFocused: Bool
    @Environment(\.layoutDirection) private var ambientDirection
    @Environment(\.isEnabled) private var isEnabled
    @State private var detectedDirection: LayoutDirection?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(UniColors.Input.placeholder)
                    .padding(.horizontal, horizontalPadding + UniSpacing.xxs)
                    .padding(.vertical, verticalPadding + UniSpacing.xs)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .focused($isFieldFocused)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(disablesAutocorrection)
                .font(font)
                .foregroundStyle(isEnabled ? UniColors.Input.text : UniColors.Input.disabledText)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, horizontalPadding - UniSpacing.xxs)
                .padding(.vertical, verticalPadding)
                .frame(minHeight: minHeight)
                .background(inputChrome)
                .tint(UniColors.Tint.accent)
                .multilineTextAlignment(.leading)
                .onChange(of: text) { oldValue, newValue in
                    if let onReturnKey,
                       newValue.count == oldValue.count + 1,
                       newValue.filter(\.isNewline).count == oldValue.filter(\.isNewline).count + 1 {
                        text = oldValue
                        isFieldFocused = false
                        onReturnKey(oldValue)
                        return
                    }
                    if directionPolicy == .automatic {
                        detectedDirection = TextDirection.detect(in: newValue)
                    }
                }
                .onAppear {
                    if directionPolicy == .automatic {
                        detectedDirection = TextDirection.detect(in: text)
                    }
                }
        }
        .modifier(DirectionOverride(direction: resolvedDirection))
    }

    private var inputChrome: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isEnabled ? (isFieldFocused ? UniColors.Input.focusedBackground : fill) : UniColors.Input.disabledBackground)
    }

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

/// Applies the OPTIONAL external `.focused(_:)` Bool binding only when a
/// parent supplied one — used by `.decimalPad` numeric sites that drive a
/// `@FocusState<Bool>` to attach `.numericDoneToolbar(_:)`. Additive and
/// independent of the always-applied private `.focused($isFieldFocused)`.
private struct ExternalBoolFocusModifier: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
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

// MARK: - Numeric keyboard "Done" toolbar

/// The standard native dismiss affordance for `.decimalPad` / `.numberPad`
/// keyboards, which carry no Return key. Adds a keyboard accessory bar with
/// a trailing **Done** button that resigns the field's focus.
///
/// **Rule #3 — native-only.** This is the system `ToolbarItemGroup(placement:
/// .keyboard)` accessory, the canonical iOS pattern for dismissing a
/// number-pad. It is the single shared home so every decimal field (Send
/// amount, custom slippage, Send hero + per-recipient) gets the identical
/// affordance rather than each re-rolling its own bar.
///
/// **Usage.** Apply to the view that owns the `@FocusState` driving the
/// field, passing the same binding the field's `.focused(_:)` uses:
/// ```swift
/// SomeNumericField(text: $text, focused: $amountFocused)
///     .numericDoneToolbar($amountFocused)
/// ```
/// The bar is only visible while the bound field holds focus — iOS shows the
/// `.keyboard` toolbar with the keyboard and hides it on dismissal.
extension View {
    func numericDoneToolbar(_ focus: FocusState<Bool>.Binding) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = false }
                    .fontWeight(.semibold)
            }
        }
    }
}
