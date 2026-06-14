import SwiftUI

/// **The v2 commit gesture — slide to send.** A glass track with a dark
/// knob (the handoff: *"Slide to send glass track with dark knob"*). It
/// supersedes v1's `SendSwipeToCommit` for the v2 Review; both are bespoke
/// (Rule #19's explicit carve-out — the commit must feel *physical*).
///
/// **Material (handoff).** The track is the glass surface on the bloom; the
/// knob is dark glass (`UniColors.Send.darkGlass`) carrying an
/// `arrow.up.right` send glyph that settles to the iris on commit. A label
/// floats on the unfilled track and fades as the knob advances.
///
/// **Haptics (handoff §Haptics).**
/// - knob crosses 90% → `impactLight` (once per crossing)
/// - slide completes (commit) → `sendWhoosh` (at knob settle, before
///   biometric)
/// All fire through `UniHapticEngine` / `.uniHaptic`, never raw generators.
///
/// **Accessibility / Reduce Motion.** A long-press-to-confirm fallback is
/// always available; under Reduce Motion the track copy names the
/// long-press path. The control presents as a single activatable button so
/// VoiceOver / Switch Control commit with one activation.
struct SendV2SlideToSend: View {
    /// Fires once when the user commits (drag past threshold OR long-press
    /// confirm). The parent runs the biometric prompt then `send()`.
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var hasCommitted: Bool = false

    @State private var nearEndTick: Int = 0
    @State private var crossedNearEnd: Bool = false
    @State private var commitTick: Int = 0

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
                fill(progress: progress)
                trackLabel(progress: progress)
                knob
                    .offset(x: knobInset + dragOffset)
                    .gesture(dragGesture(maxOffset: maxOffset, progress: progress))
            }
            .frame(height: trackHeight)
            .onLongPressGesture(minimumDuration: 0.45) {
                commit(maxOffset: maxOffset)
            }
        }
        .frame(height: trackHeight)
        .uniHaptic(.contextualImpact(.whisper), trigger: nearEndTick)   // 90% crossing → impactLight
        .uniHapticSignature(.sendWhoosh, trigger: commitTick)            // commit → sendWhoosh
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Slide to send"))
        .accessibilityHint(Text("Double-tap and hold to confirm sending"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { commit(maxOffset: 1) }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var track: some View {
        if reduceTransparency {
            Capsule()
                .fill(UniColors.Send.cardSolidFallback)
                .overlay(Capsule().stroke(UniColors.Send.cardHairline, lineWidth: 0.5))
        } else {
            Capsule()
                .fill(Color.clear)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private func fill(progress: CGFloat) -> some View {
        // Dark-glass fill that follows the knob — the track darkening as
        // money is pushed out.
        Capsule()
            .fill(UniColors.Send.darkGlass.opacity(0.10 + 0.14 * Double(progress)))
            .frame(width: max(knobSize + knobInset * 2, knobInset * 2 + knobSize + dragOffset))
            .opacity(isDragging || progress > 0 ? 1 : 0)
    }

    private func trackLabel(progress: CGFloat) -> some View {
        HStack {
            Spacer()
            Text(reduceMotion ? "Press and hold to send" : "Slide to send")
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer()
        }
        .opacity(1 - Double(min(1, progress * 1.4)))
        .allowsHitTesting(false)
    }

    private var knob: some View {
        Circle()
            .fill(UniColors.Send.darkGlass)
            .frame(width: knobSize, height: knobSize)
            .overlay {
                if hasCommitted {
                    ApertureIrisView(ringColor: UniColors.Send.onDarkGlass)
                        .frame(width: knobSize * 0.5, height: knobSize * 0.5)
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(UniColors.Send.onDarkGlass)
                        .flipsForRightToLeftLayoutDirection(false)
                }
            }
            .shadow(color: UniColors.Send.knobShadow, radius: 8, y: 4)
    }

    // MARK: - Gesture

    private func dragGesture(maxOffset: CGFloat, progress: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !hasCommitted else { return }
                if !isDragging { isDragging = true }
                let dx = layoutDirection == .rightToLeft ? -value.translation.width : value.translation.width
                let next = min(maxOffset, max(0, dx))
                dragOffset = next
                let p = maxOffset > 0 ? next / maxOffset : 0
                if p >= 0.9, !crossedNearEnd {
                    crossedNearEnd = true
                    nearEndTick &+= 1
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
        commitTick &+= 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragOffset = max(0, maxOffset)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            onCommit()
        }
    }
}
