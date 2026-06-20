import SwiftUI

/// **Send v2 liquid-glass surface primitives** (`design_handoff_send_v2`).
///
/// The bloom page background, the glass card, the dark-glass pill button,
/// and the glass chip that every rebuilt Send-v2 screen composes from.
/// This file owns **layout + material only** — every colour is a
/// `UniColors.Send.*` role (Rule #4 §B keeps hex inside `UniColors`).
///
/// All three honour the user's accessibility settings: the bloom and the
/// glass collapse to flat, opaque, hairline-bordered surfaces under
/// **Reduce Transparency** (the handoff's documented fallback), and the
/// material samples the bloom behind it for the real iOS-26 glass look.

// MARK: - Bloom background

/// The Send v2 "quiet bloom" page background: a soft vertical base
/// gradient (`bloomBaseTop → bloomBaseBottom`, appearance-adaptive via the
/// asset-backed stops) with two faint radial tints — cool blue-gray from
/// the top-leading corner, warm violet from the bottom-trailing. Never a
/// flat white. Under Reduce Transparency it collapses to the flat base
/// colour so nothing shimmers.
struct SendBloomBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                UniColors.Send.bloomBaseBottom
            } else {
                ZStack {
                    LinearGradient(
                        colors: [UniColors.Send.bloomBaseTop, UniColors.Send.bloomBaseBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    GeometryReader { geo in
                        let reach = max(geo.size.width, geo.size.height)
                        ZStack {
                            RadialGradient(
                                colors: [UniColors.Send.bloomCool, .clear],
                                center: .topLeading, startRadius: 0, endRadius: reach * 0.95
                            )
                            RadialGradient(
                                colors: [UniColors.Send.bloomWarm, .clear],
                                center: .bottomTrailing, startRadius: 0, endRadius: reach * 0.95
                            )
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass card

/// A Send v2 liquid-glass card. iOS 26 `.regularMaterial` over the bloom,
/// a soft top specular edge, and a soft drop shadow. Under Reduce
/// Transparency it falls back to an opaque solid fill with a hairline
/// border. Layout-only; colours are `UniColors.Send.*` roles.
struct SendGlassCard<Content: View>: View {
    var cornerRadius: CGFloat
    var padding: CGFloat
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        cornerRadius: CGFloat = UniRadius.xl,
        padding: CGFloat = UniSpacing.m,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(specularEdge)
            .shadow(
                color: reduceTransparency ? .clear : UniColors.Send.cardShadow,
                radius: 22, x: 0, y: 12
            )
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(UniColors.Send.cardSolidFallback)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    private var specularEdge: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                reduceTransparency
                    ? AnyShapeStyle(UniColors.Send.cardHairline)
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [UniColors.Send.cardSpecular, .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    ),
                lineWidth: 1
            )
    }
}

// MARK: - Dark-glass primary button

/// The Send v2 **primary** action — a dark-glass pill (height 50–52,
/// capsule), near-white label. Used for non-commit primaries (Continue,
/// "Use the saved address"). The money-leaving commit itself uses the
/// dedicated slide-to-send control, not this button.
struct SendV2PrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isEnabled: Bool
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: UniSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(title)
                    .font(UniTypography.buttonLabel)
            }
            .foregroundStyle(isEnabled ? UniColors.Send.onDarkGlass : UniColors.Button.disabledLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isEnabled
                            ? AnyShapeStyle(UniColors.Send.darkGlass)
                            : AnyShapeStyle(UniColors.Button.disabledProminentFill)
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - Ghost (text) button

/// A bare Send v2 **ghost** action — text only, no chrome. Optional danger
/// tint for the deliberate "continue anyway" choices. Pairs under a
/// `SendV2PrimaryButton` as the quiet secondary path.
struct SendV2GhostButton: View {
    let title: LocalizedStringKey
    var isDanger: Bool
    let action: () -> Void

    init(_ title: LocalizedStringKey, isDanger: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isDanger = isDanger
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(UniTypography.buttonLabel)
                .foregroundStyle(isDanger ? UniColors.Send.negative : UniColors.Button.text)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
