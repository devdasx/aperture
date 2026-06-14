import SwiftUI

// MARK: - Send v2 material
//
// The shared visual material every Send v2 screen composes from, per the
// `design_handoff_send_v2/README.md` "The material — liquid glass rules"
// table. Built once here so the flow reads as one system (Rule #2 §B —
// see the system, not the screen) and a future re-skin touches one file.
//
// Native-only (Rule #3): glass cards use iOS 26 `.glassEffect()` — the
// honest expression of the handoff's `rgba(255,255,255,.58)` + blur +
// specular, supplying translucency + specular + motion for free — with a
// Reduce-Transparency solid fallback (`UniColors.Send.cardSolidFallback`).
// Every color is a `UniColors` role (Rule #4); every meaningful glyph is
// an SF Symbol (Rule #7). The only shapes are structural (Rule #7
// exception): rounded card containers, chip capsules, badge rings.

// MARK: - Bloom background

/// The soft bloom screen background — *"never pure white"*. A base
/// gradient (`#F2F3F6 → #E8EAEE`, appearance-adaptive via the
/// `SendBloomBase*` colorsets) under two faint radial tints: cool
/// blue-gray top-left, warm violet bottom-right. The poisoning
/// interstitial passes `danger: true` to add a third red tint at the top
/// (the handoff's red-tinted bloom for the full-attention guard).
///
/// Reduce Transparency keeps the base gradient (it carries no
/// translucency — it's an opaque fill) but drops the radial blooms, which
/// read as decorative under that setting.
struct SendBloomBackground: View {
    /// Adds the red attention tint at the top (poisoning guard / cancel
    /// confirm). Default off.
    var danger: Bool = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [UniColors.Send.bloomBaseTop, UniColors.Send.bloomBaseBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            if !reduceTransparency {
                // Cool blue-gray, top-left (radial 90% 50% at 18% −4%).
                RadialGradient(
                    colors: [UniColors.Send.bloomCool, UniColors.Send.bloomCool.opacity(0)],
                    center: UnitPoint(x: 0.18, y: -0.04),
                    startRadius: 0,
                    endRadius: 460
                )
                // Warm violet, bottom-right (radial 80% 44% at 92% 104%).
                RadialGradient(
                    colors: [UniColors.Send.bloomWarm, UniColors.Send.bloomWarm.opacity(0)],
                    center: UnitPoint(x: 0.92, y: 1.04),
                    startRadius: 0,
                    endRadius: 420
                )
                if danger {
                    // Red attention tint, top-center (radial 110% 60% at 50% −8%).
                    RadialGradient(
                        colors: [UniColors.Send.bloomDanger, UniColors.Send.bloomDanger.opacity(0)],
                        center: UnitPoint(x: 0.5, y: -0.08),
                        startRadius: 0,
                        endRadius: 480
                    )
                    .animation(.easeOut(duration: 0.4), value: danger)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass card

/// A glass card on the bloom — the handoff's default glass surface
/// (`rgba(255,255,255,.58)` + blur + a top specular edge, radius 20).
///
/// The native iOS 26 `.glassEffect(.regular, in:)` supplies translucency
/// + specular + motion (Rule #3 — never `.ultraThinMaterial` as a glass
/// substitute). A top-edge specular stroke (`UniColors.Send.cardSpecular`)
/// adds the handoff's `inset 0 1px 0 rgba(255,255,255,.65)` highlight.
/// Under Reduce Transparency the surface falls back to an opaque solid
/// card with a hairline border (the handoff's explicit fallback).
struct SendGlassCard<Content: View>: View {
    var padding: CGFloat = UniSpacing.m
    var cornerRadius: CGFloat = UniRadius.xl   // 22 ≈ the handoff's r20–22
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content()
            .padding(padding)
            .modifier(SendGlassSurface(cornerRadius: cornerRadius, reduceTransparency: reduceTransparency))
            .containerShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The glass (or solid-fallback) surface modifier, factored out so chips
/// / pills / cards share one truth. Applies `.glassEffect` + a specular
/// top edge, or the opaque fallback under Reduce Transparency.
struct SendGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(UniColors.Send.cardSolidFallback)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(UniColors.Send.cardHairline, lineWidth: 0.5)
                )
        } else {
            content
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .overlay(
                    // Top-edge specular highlight (handoff inset highlight).
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [UniColors.Send.cardSpecular, UniColors.Send.cardSpecular.opacity(0)],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1
                        )
                )
        }
    }
}

// MARK: - Chip

/// A small glass / dark-glass pill — Paste / Scan / 25 / 50 / Max / chain
/// filter / fee preset. Selected chips use dark glass (the handoff:
/// *"selected = dark glass"*); unselected use the regular glass surface.
/// Carries its own `.contentShape(Capsule())` so taps land across the
/// painted glass (the M-002/Rule #19 hit-test invariant).
struct SendChip: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var isSelected: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var tapTick: Int = 0

    var body: some View {
        Button {
            tapTick &+= 1
            action()
        } label: {
            HStack(spacing: UniSpacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(UniTypography.subheadlineEmphasized)
            }
            .foregroundStyle(isSelected ? UniColors.Send.onDarkGlass : UniColors.Text.primary)
            .padding(.horizontal, UniSpacing.m)
            .frame(height: 44)
            .modifier(ChipSurface(isSelected: isSelected, reduceTransparency: reduceTransparency))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: tapTick)
    }

    private struct ChipSurface: ViewModifier {
        let isSelected: Bool
        let reduceTransparency: Bool

        func body(content: Content) -> some View {
            if isSelected {
                content.background(Capsule().fill(UniColors.Send.darkGlass))
            } else if reduceTransparency {
                content
                    .background(Capsule().fill(UniColors.Send.cardSolidFallback))
                    .overlay(Capsule().stroke(UniColors.Send.cardHairline, lineWidth: 0.5))
            } else {
                content.glassEffect(.regular, in: .capsule)
            }
        }
    }
}

// MARK: - Detail row (inside a glass card)

/// A `key — value` row inside a glass detail card. The value defaults to
/// LTR + tabular so addresses / amounts / hashes read correctly in any
/// locale (Rule #11 display-content carve-out). The trailing slot is a
/// builder so rows can carry a badge, an Edit affordance, or plain text.
struct SendDetailRow<Trailing: View>: View {
    let key: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            trailing()
        }
        .padding(.vertical, UniSpacing.s)
    }
}

// MARK: - Section label

/// A quiet uppercase section caption (Recents / Address book / After this
/// send) above a glass section, in the calm restrained register.
struct SendSectionLabel: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(UniTypography.caption1.weight(.semibold))
            .foregroundStyle(UniColors.Text.tertiary)
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.leading, UniSpacing.xs)
    }
}
