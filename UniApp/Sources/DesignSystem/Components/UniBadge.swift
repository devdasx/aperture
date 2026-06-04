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
                    .font(.system(size: 11, weight: .semibold))
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
            return (UniColors.Status.successBackground, UniColors.Status.successForeground, UniColors.Status.successStroke)
        case .warning:
            return (UniColors.Status.warningBackground, UniColors.Status.warningForeground, UniColors.Status.warningStroke)
        case .error:
            return (UniColors.Status.errorBackground, UniColors.Status.errorForeground, UniColors.Status.errorStroke)
        case .info:
            return (UniColors.Status.infoBackground, UniColors.Status.infoForeground, UniColors.Status.infoStroke)
        case .neutral:
            return (UniColors.Status.neutralBackground, UniColors.Status.neutralForeground, UniColors.Status.neutralStroke)
        }
    }
}
