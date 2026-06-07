import SwiftUI

/// Unified button component. All variants wrap native `Button` + iOS 26 system
/// styles (`.buttonStyle(.glass / .glassProminent / .plain)`).
///
/// Per `CLAUDE.md` Rule #3, never hand-roll a button background — use this.
///
/// ### Haptics
///
/// Per `CLAUDE.md` Rule #10 Part E, each variant fires a default semantic
/// haptic on tap — no caller responsibility:
///
/// | Variant         | Haptic                          |
/// |-----------------|---------------------------------|
/// | `.primary`      | `.contextualImpact(.commit)`    |
/// | `.secondary`    | `.selection`                    |
/// | `.destructive`  | `.warning`                      |
/// | `.tertiary`     | none                            |
///
/// The haptic is fired declaratively via `.uniHaptic(_:trigger:)`, which
/// honors the user's `@AppStorage("hapticFeedbackEnabled")` preference and
/// the system-level "System Haptics" + "Reduce Motion" settings.
struct UniButton: View {
    enum Variant {
        /// High-emphasis primary action. Liquid Glass prominent + accent tint.
        case primary
        /// Standard alternative action. Liquid Glass with neutral tint.
        case secondary
        /// Dangerous action (delete, remove, sign out). Glass prominent + red.
        case destructive
        /// Inline text button (links, "Skip", "Sign in"). No glass surface.
        case tertiary

        /// Default haptic fired on tap. `nil` means silent (`.tertiary`).
        fileprivate var defaultHaptic: UniHaptic? {
            switch self {
            case .primary:     return .contextualImpact(.commit)
            case .secondary:   return .selection
            case .destructive: return .warning
            case .tertiary:    return nil
            }
        }
    }

    /// `LocalizedStringKey` so call-site literals auto-localize through the
    /// String Catalog (Rule #9). For a runtime, non-localizable label, build
    /// a `Button` inline instead.
    let title: LocalizedStringKey
    let variant: Variant
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    /// Trigger counter for the variant's default haptic. Incremented inside
    /// the action wrapper; the `.uniHaptic(...)` modifier observes the
    /// change and fires the native feedback (if the user has haptics on).
    @State private var tapCount: Int = 0

    var body: some View {
        buttonBody
            .modifier(HapticBinding(variant: variant, trigger: tapCount))
    }

    @ViewBuilder
    private var buttonBody: some View {
        Button {
            tapCount &+= 1
            action()
        } label: {
            label
        }
        .modifier(VariantStyle(variant: variant))
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var label: some View {
        HStack(spacing: UniSpacing.xs) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
            }
            Text(title)
                .font(UniTypography.buttonLabel)
        }
        .frame(maxWidth: variant == .tertiary ? nil : .infinity)
        .frame(height: variant == .tertiary ? nil : 47)
    }

    private struct VariantStyle: ViewModifier {
        let variant: Variant

        @ViewBuilder
        func body(content: Content) -> some View {
            switch variant {
            case .primary:
                content
                    .buttonStyle(.glassProminent)
                    .tint(UniColors.Button.primaryTint)
            case .secondary:
                content
                    .buttonStyle(.glass)
                    .tint(UniColors.Button.secondaryTint)
            case .destructive:
                content
                    .buttonStyle(.glassProminent)
                    .tint(UniColors.Button.destructiveTint)
            case .tertiary:
                content
                    .buttonStyle(.plain)
                    .foregroundStyle(UniColors.Button.tertiaryLabel)
            }
        }
    }

    /// Attaches the variant's default haptic to the button. `.tertiary`
    /// is silent — we skip the modifier rather than wire a no-op.
    private struct HapticBinding: ViewModifier {
        let variant: Variant
        let trigger: Int

        @ViewBuilder
        func body(content: Content) -> some View {
            if let haptic = variant.defaultHaptic {
                content.uniHaptic(haptic, trigger: trigger)
            } else {
                content
            }
        }
    }
}
