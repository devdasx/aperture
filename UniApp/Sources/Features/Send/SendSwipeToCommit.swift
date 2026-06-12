import SwiftUI

/// **The signature commit gesture** — swipe the knob across the track to
/// send. Per the handoff this is a bespoke component, NOT a `UniButton`
/// (Rule #19's explicit carve-out): the commit must feel *physical* — you
/// push the money out — and it prevents accidental sends.
///
/// **Visual register (handoff "Design tokens").** Brand-Ink track
/// (`UniColors.Send.track`, `#0A0C10`), a white knob carrying the
/// Aperture iris, a "Swipe to send" label floating on the unfilled track,
/// and a fill that follows the knob. Pill radius (the handoff's 26–32pt;
/// the track is 64pt tall so a `Capsule()` reads as the pill).
///
/// **Haptics (Rule #10 + handoff).**
/// - drag start → `.contextualImpact(.tap)`
/// - knob crosses ~90% → `.contextualImpact(.whisper)` (one-shot)
/// - release past the commit threshold → `signature(.sendWhoosh)`
/// All fire through `UniHapticEngine` / `.uniHaptic`, never raw generators.
///
/// **Accessibility / Reduce Motion.** A long-press-to-confirm fallback is
/// always available (the handoff requirement). Under Reduce Motion the
/// knob still drags but the track copy names the long-press path, and the
/// whole control carries a button trait + activation action so VoiceOver
/// and Switch Control users commit with a single activation.
struct SendSwipeToCommit: View {
    /// Fires once when the user commits (drag past threshold OR
    /// long-press confirm). The parent advances to Authorize.
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    /// Current knob offset from the leading edge, in points.
    @State private var dragOffset: CGFloat = 0
    /// Whether a drag is in progress (drives the fill + label fade).
    @State private var isDragging: Bool = false
    /// True once committed — locks the control so a second drag can't
    /// double-fire.
    @State private var hasCommitted: Bool = false

    // Haptic triggers — incremented to fire the corresponding `.uniHaptic`.
    @State private var dragStartTick: Int = 0
    @State private var nearEndTick: Int = 0
    @State private var crossedNearEnd: Bool = false
    @State private var commitTick: Int = 0

    // Track geometry constants (tokens where the scale has them; the
    // knob inset + track height are component-intrinsic).
    private let trackHeight: CGFloat = 64
    private let knobInset: CGFloat = 6
    private var knobSize: CGFloat { trackHeight - knobInset * 2 }

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let maxOffset = max(0, trackWidth - knobSize - knobInset * 2)
            let progress = maxOffset > 0 ? min(1, max(0, dragOffset / maxOffset)) : 0

            ZStack(alignment: .leading) {
                track
                fill(progress: progress, trackWidth: trackWidth)
                trackLabel(progress: progress)
                knob
                    .offset(x: knobInset + dragOffset)
                    .gesture(dragGesture(maxOffset: maxOffset, progress: progress))
            }
            .frame(height: trackHeight)
            // Long-press anywhere on the track is the Reduce-Motion /
            // accessibility commit path (handoff requirement).
            .onLongPressGesture(minimumDuration: 0.45) {
                commit(maxOffset: maxOffset)
            }
        }
        .frame(height: trackHeight)
        // Haptic bindings (Rule #10 — declarative, preference-gated).
        .uniHaptic(.contextualImpact(.tap), trigger: dragStartTick)
        .uniHaptic(.contextualImpact(.whisper), trigger: nearEndTick)
        .uniHapticSignature(.sendWhoosh, trigger: commitTick)
        // VoiceOver / Switch Control: present as a single activatable
        // button so non-drag input can commit.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Swipe to send"))
        .accessibilityHint(Text("Double-tap and hold to confirm sending"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            // Provide max offset via a generous default — the action
            // path doesn't need exact geometry, just to fire the commit.
            commit(maxOffset: 1)
        }
    }

    // MARK: - Pieces

    private var track: some View {
        Capsule()
            .fill(UniColors.Send.track)
    }

    private func fill(progress: CGFloat, trackWidth: CGFloat) -> some View {
        // A subtle brightening fill that follows the knob — the handoff's
        // "fill that follows the knob". White at low opacity over the
        // Ink track reads as the surface lighting up as money leaves.
        Capsule()
            .fill(UniColors.Send.knob.opacity(0.08 + 0.10 * Double(progress)))
            .frame(width: max(knobSize + knobInset * 2, knobInset * 2 + knobSize + dragOffset))
            .opacity(isDragging || progress > 0 ? 1 : 0)
    }

    private func trackLabel(progress: CGFloat) -> some View {
        HStack {
            Spacer()
            Text(reduceMotion ? "Press and hold to send" : "Swipe to send")
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(UniColors.Send.trackLabel)
            Spacer()
        }
        // Fade the label out as the knob advances so it doesn't sit under
        // the knob at the end of the travel.
        .opacity(1 - Double(min(1, progress * 1.4)))
        .allowsHitTesting(false)
    }

    private var knob: some View {
        Circle()
            .fill(UniColors.Send.knob)
            .frame(width: knobSize, height: knobSize)
            .overlay {
                if hasCommitted {
                    // Settles to the iris once committed.
                    ApertureIrisView(ringColor: UniColors.Send.knobGlyph)
                        .frame(width: knobSize * 0.5, height: knobSize * 0.5)
                } else {
                    Image(systemName: layoutDirection == .rightToLeft ? "chevron.left" : "chevron.right")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(UniColors.Send.knobGlyph)
                }
            }
            .shadow(color: UniColors.Send.knobShadow, radius: 6, y: 3)
    }

    // MARK: - Gesture

    private func dragGesture(maxOffset: CGFloat, progress: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !hasCommitted else { return }
                if !isDragging {
                    isDragging = true
                    dragStartTick &+= 1   // → .tap
                }
                // Clamp travel to [0, maxOffset]. In RTL the drag reads
                // right-to-left, so invert the horizontal translation.
                let dx = layoutDirection == .rightToLeft ? -value.translation.width : value.translation.width
                let next = min(maxOffset, max(0, dx))
                dragOffset = next
                let p = maxOffset > 0 ? next / maxOffset : 0
                if p >= 0.9, !crossedNearEnd {
                    crossedNearEnd = true
                    nearEndTick &+= 1     // → .whisper at ~90%
                } else if p < 0.9 {
                    crossedNearEnd = false
                }
            }
            .onEnded { _ in
                guard !hasCommitted else { return }
                isDragging = false
                if progress >= 0.85 || dragOffset >= maxOffset * 0.85 {
                    commit(maxOffset: maxOffset)
                } else {
                    // Snap back — the user didn't push far enough.
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                        dragOffset = 0
                    }
                    crossedNearEnd = false
                }
            }
    }

    private func commit(maxOffset: CGFloat) {
        guard !hasCommitted else { return }
        hasCommitted = true
        commitTick &+= 1   // → signature .sendWhoosh
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragOffset = max(0, maxOffset)
        }
        // Let the whoosh + knob settle read before advancing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            onCommit()
        }
    }
}
