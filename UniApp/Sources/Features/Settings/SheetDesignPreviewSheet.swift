import SwiftUI

struct SheetDesignPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding = horizontalPadding(for: proxy.size.width)

            VStack(spacing: 0) {
                SheetDesignPreviewHero()
                    .frame(height: heroHeight(for: proxy.size))

                ScrollView {
                    content
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 38)
                        .padding(.bottom, 164)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SheetDesignPreviewActions {
                    dismiss()
                } secondaryAction: {
                    dismiss()
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 16)
                .background(Color.white)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(Color.white)
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.colorScheme, .light)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notification Summary")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.black)

            Text("Bundle non-urgent notifications and receive them in a summary at convenient times.")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 30) {
                SheetDesignPreviewFeatureRow(
                    symbol: "checkmark.circle",
                    tint: .red,
                    title: "Schedule Delivery",
                    details: "Choose when you’d like your notification summary to arrive."
                )

                SheetDesignPreviewFeatureRow(
                    symbol: "exclamationmark.bubble",
                    tint: .blue,
                    title: "Get What’s Important",
                    details: "Calls, direct messages, and Time Sensitive notifications will be delivered immediately, even for apps in your summary."
                )
            }
            .padding(.top, 38)
        }
    }

    private func heroHeight(for size: CGSize) -> CGFloat {
        min(max(size.height * 0.35, 300), 360)
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        min(max(width * 0.085, 32), 38)
    }
}

private struct SheetDesignPreviewHero: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBlue),
                    Color(uiColor: .systemTeal),
                    Color(uiColor: .systemGreen).opacity(0.78),
                    Color(uiColor: .systemYellow).opacity(0.46)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(.black.opacity(0.26))
                .frame(width: 210, height: 322)
                .overlay(alignment: .top) {
                    Text("18:00")
                        .font(.system(size: 38, weight: .regular))
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.top, 54)
                }
                .offset(y: 32)

            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.white.opacity(0.68))
                .frame(width: 178, height: 174)
                .overlay {
                    SheetDesignPreviewNotificationCard()
                }
                .offset(y: -58)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct SheetDesignPreviewNotificationCard: View {
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.black.opacity(0.14))
                    .frame(width: 34, height: 8)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.black.opacity(0.11))
                    .frame(width: 98, height: 8)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(uiColor: .systemCyan).opacity(0.9),
                                Color(uiColor: .systemTeal).opacity(0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 104, height: 58)
                    .overlay(alignment: .bottom) {
                        MountainSilhouette()
                    }
                    .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 17)
            .padding(.leading, 17)

            Circle()
                .fill(Color(uiColor: .systemCyan))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 13)
                .padding(.trailing, 14)

            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(uiColor: .systemCyan).opacity(0.82),
                            Color(uiColor: .systemGreen).opacity(0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 34)
                .offset(x: 56, y: -8)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .systemBackground).opacity(0.36))
                .frame(width: 72, height: 82)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(uiColor: .systemOrange).opacity(0.95),
                                    Color(uiColor: .systemRed).opacity(0.45),
                                    .black
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 48
                            )
                        )
                        .frame(width: 58, height: 46)
                        .overlay(alignment: .trailing) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.78))
                                .padding(.trailing, 5)
                        }
                }
                .offset(x: 42, y: 40)
        }
    }
}

private struct MountainSilhouette: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height * 0.58))
            path.addCurve(
                to: CGPoint(x: size.width * 0.34, y: size.height * 0.72),
                control1: CGPoint(x: size.width * 0.12, y: size.height * 0.62),
                control2: CGPoint(x: size.width * 0.22, y: size.height * 0.82)
            )
            path.addLine(to: CGPoint(x: size.width * 0.54, y: size.height * 0.52))
            path.addCurve(
                to: CGPoint(x: size.width, y: size.height * 0.62),
                control1: CGPoint(x: size.width * 0.7, y: size.height * 0.6),
                control2: CGPoint(x: size.width * 0.82, y: size.height * 0.76)
            )
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.black.opacity(0.42)))
        }
    }
}

private struct SheetDesignPreviewFeatureRow: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let details: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 70, alignment: .center)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .fixedSize(horizontal: false, vertical: true)

                Text(details)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SheetDesignPreviewActions: View {
    let primaryAction: () -> Void
    let secondaryAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button {
                primaryAction()
            } label: {
                Text("Continue")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .contentShape(Capsule())
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Color(uiColor: .systemBlue))

            Button {
                secondaryAction()
            } label: {
                Text("Set Up Later")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contentShape(Capsule())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .tint(Color.white)
        }
    }
}
