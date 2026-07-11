import SwiftUI

/// The shared seed-phrase grid (2026-06-20 recovery-phrase handoff: "Build
/// it as a shared component reused by Recovery Phrase, Export, and Manual
/// Backup — not a per-screen copy"). One grouped rounded container, two
/// columns, tabular zero-padded index numbers, and hairline row/column
/// dividers. Words use the system font; the grid is forced LTR so the
/// 1→N reading order never flips in an RTL locale.
struct PhraseGrid: View {
    let words: [String]

    var body: some View {
        let rowsCount = (words.count + 1) / 2
        VStack(spacing: 0) {
            ForEach(0..<rowsCount, id: \.self) { r in
                HStack(spacing: 0) {
                    cell(index: r)
                    Rectangle().fill(UniColors.SeedGrid.hairline).frame(width: 1)
                    cell(index: r + rowsCount)
                }
                if r < rowsCount - 1 {
                    Rectangle().fill(UniColors.SeedGrid.hairline).frame(height: 1)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.SeedGrid.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .stroke(UniColors.SeedGrid.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private func cell(index: Int) -> some View {
        if index < words.count {
            HStack(spacing: UniSpacing.xs) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 13, weight: .regular, design: .default).monospacedDigit())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .frame(width: 24, alignment: .leading)
                Text(words[index])
                    .font(UniTypography.body)
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
