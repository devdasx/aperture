import SwiftUI

/// Status badge — small pill conveying state (success / warning / error / info / neutral).
struct UniBadge: View {
    enum Kind {
        case success, warning, error, info, neutral
    }

    let text: LocalizedStringKey
    let kind: Kind
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: UniSpacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .regular))
            }
            Text(text)
                .font(UniTypography.caption2.weight(.semibold))
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, UniSpacing.xs)
        .padding(.vertical, UniSpacing.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(palette.background)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(palette.stroke, lineWidth: 0.5)
        )
    }

    private var palette: (background: Color, foreground: Color, stroke: Color) {
        switch kind {
        case .success:
            return (UniColors.Badge.Success.background, UniColors.Badge.Success.foreground, UniColors.Badge.Success.stroke)
        case .warning:
            return (UniColors.Badge.Warning.background, UniColors.Badge.Warning.foreground, UniColors.Badge.Warning.stroke)
        case .error:
            return (UniColors.Badge.Error.background, UniColors.Badge.Error.foreground, UniColors.Badge.Error.stroke)
        case .info:
            return (UniColors.Badge.Info.background, UniColors.Badge.Info.foreground, UniColors.Badge.Info.stroke)
        case .neutral:
            return (UniColors.Badge.Neutral.background, UniColors.Badge.Neutral.foreground, UniColors.Badge.Neutral.stroke)
        }
    }
}
