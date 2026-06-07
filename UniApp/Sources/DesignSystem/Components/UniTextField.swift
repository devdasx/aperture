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
    static func detect(in text: String) -> LayoutDirection? {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if isStrongRTL(v) { return .rightToLeft }
            if isStrongLTR(v) { return .leftToRight }
        }
        return nil
    }

    private static func isStrongRTL(_ v: UInt32) -> Bool {
        // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, etc.
        if (0x0590...0x08FF).contains(v) { return true }
        // Hebrew presentation forms.
        if (0xFB1D...0xFB4F).contains(v) { return true }
        // Arabic presentation forms A + B.
        if (0xFB50...0xFDFF).contains(v) { return true }
        if (0xFE70...0xFEFF).contains(v) { return true }
        return false
    }

    private static func isStrongLTR(_ v: UInt32) -> Bool {
        if (0x0041...0x005A).contains(v) { return true }  // A-Z
        if (0x0061...0x007A).contains(v) { return true }  // a-z
        if (0x00C0...0x024F).contains(v) { return true }  // Latin Extended
        if (0x0370...0x03FF).contains(v) { return true }  // Greek
        if (0x0400...0x04FF).contains(v) { return true }  // Cyrillic
        if (0x0900...0x097F).contains(v) { return true }  // Devanagari
        if (0x4E00...0x9FFF).contains(v) { return true }  // CJK Unified
        if (0x3040...0x30FF).contains(v) { return true }  // Hiragana + Katakana
        if (0xAC00...0xD7AF).contains(v) { return true }  // Hangul Syllables
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
struct UniTextField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var directionPolicy: TextDirection.Policy = .automatic
    var isSecure: Bool = false
    var showsRevealToggle: Bool = false
    var axis: Axis = .horizontal
    var lineLimit: Int? = nil
    var reservesSpace: Bool = false
    var contentType: UITextContentType? = nil
    var keyboardType: UIKeyboardType = .default
    var minHeight: CGFloat? = nil
    var autocapitalization: TextInputAutocapitalization = .never
    var disablesAutocorrection: Bool = true

    @State private var isRevealed: Bool = false
    @FocusState private var isFieldFocused: Bool
    @Environment(\.layoutDirection) private var ambientDirection

    var body: some View {
        ZStack(alignment: .trailing) {
            inputControl
                .focused($isFieldFocused)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(disablesAutocorrection)
                .keyboardType(keyboardType)
                .textContentType(contentType)
                .font(UniTypography.body)
                .modifier(LineLimitModifier(limit: lineLimit, reservesSpace: reservesSpace))
                .padding(.horizontal, UniSpacing.m)
                .padding(.vertical, UniSpacing.s)
                .padding(.trailing, (showsRevealToggle && isSecure) ? 40 : 0)
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
                .modifier(DirectionOverride(direction: resolvedDirection))
                .multilineTextAlignment(.leading)

            if showsRevealToggle && isSecure {
                revealButton
            }
        }
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

    private var resolvedDirection: LayoutDirection? {
        TextDirection.resolve(
            policy: directionPolicy,
            text: text,
            ambient: ambientDirection
        )
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
