import SwiftUI

struct ApertureTipCard: View {
    let title: String
    let message: String
    let systemImage: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(UniColors.Brand.mark)
                .frame(width: 28, height: 28)
                .background(UniColors.Brand.mark.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(message)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: UniSpacing.s)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(UniColors.Text.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background, in: RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .stroke(UniColors.Stroke.regular, lineWidth: 1)
        }
    }
}
