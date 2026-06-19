import SwiftUI

/// The shared seed-phrase grid (2026-06-20 recovery-phrase handoff: "Build
/// it as a shared component reused by Recovery Phrase, Export, and Manual
/// Backup — not a per-screen copy"). One grouped rounded container, two
/// columns, tabular zero-padded index numbers, hairline row/column
/// dividers, monospaced words. Forced LTR so the 1→N reading order never
/// flips in an RTL locale.
struct PhraseGrid: View {
    let words: [String]

    var body: some View {
        let rowsCount = (words.count + 1) / 2
        VStack(spacing: 0) {
            ForEach(0..<rowsCount, id: \.self) { r in
                HStack(spacing: 0) {
                    cell(index: r)
                    Rectangle().fill(UniColors.Separator.regular).frame(width: 1)
                    cell(index: r + rowsCount)
                }
                if r < rowsCount - 1 {
                    Rectangle().fill(UniColors.Separator.regular).frame(height: 1)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private func cell(index: Int) -> some View {
        if index < words.count {
            HStack(spacing: UniSpacing.xs) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 13, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .frame(width: 24, alignment: .leading)
                Text(words[index])
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Odd word count — keep the grid square with an empty cell.
            Color.clear.frame(maxWidth: .infinity)
        }
    }
}

/// Tap-to-reveal blur gate for a secret (phrase / key). Blurs its content
/// until an explicit tap, re-blurs when the app backgrounds. Reduced motion
/// shows the final state with no animated lift. Mirrors the Export flow's
/// gate so every secret surface reveals the same way.
struct PhraseRevealGate<Content: View>: View {
    @Binding var revealed: Bool
    @ViewBuilder var content: Content

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content
                .blur(radius: revealed ? 0 : 18)
                .allowsHitTesting(revealed)

            if !revealed {
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: UniSpacing.s) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 26, weight: .regular))
                                .foregroundStyle(UniColors.Icon.secondary)
                                .frame(width: 56, height: 56)
                                .background(Circle().fill(UniColors.Background.secondary))
                            Text("Tap to reveal")
                                .font(UniTypography.bodyEmphasized)
                                .foregroundStyle(UniColors.Text.primary)
                            Text("Make sure no one is watching")
                                .font(UniTypography.footnote)
                                .foregroundStyle(UniColors.Text.secondary)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
                    .onTapGesture { reveal() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text("Tap to reveal"))
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { revealed = false }
        }
    }

    private func reveal() {
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        if reduceMotion {
            revealed = true
        } else {
            withAnimation(.easeOut(duration: 0.25)) { revealed = true }
        }
    }
}
