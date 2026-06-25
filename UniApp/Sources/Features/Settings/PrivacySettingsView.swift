import SwiftUI

/// Settings → Privacy. After the data-fetching layer was removed
/// (2026-06-25) the screen has a single row: **What Aperture doesn't
/// collect** — a Rule #16-style boundary statement sheet, the
/// load-bearing honest claim of the project. The former background
/// balance-refresh toggle and the Coinbase price disclosure were retired
/// with the fetching they described — the app no longer fetches
/// balances, transaction history, or prices at all.
struct PrivacySettingsView: View {
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @State private var isShowingBoundarySheet: Bool = false

    /// Rule #12 §G direction-only key for sheet content rebuild.
    /// `"ltr"` or `"rtl"`. Identical pattern to `OnboardingView`.
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    var body: some View {
        List {
            Section {
                Button {
                    isShowingBoundarySheet = true
                } label: {
                    SettingsRowShared(
                        systemImage: "eye.slash",
                        title: "What Aperture doesn't collect",
                        trailing: nil
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Privacy"))
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $isShowingBoundarySheet) {
            BoundaryStatementSheet()
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
    }
}

// MARK: - Boundary statement sheet

private struct BoundaryStatementSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        UniSheet(title: "What Aperture doesn't collect") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Brand.mark)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)

                bulletRow(systemImage: "person.crop.circle.badge.xmark",
                          title: "No account",
                          body: "Aperture has no signup, no email, no password.")
                bulletRow(systemImage: "server.rack",
                          title: "No servers",
                          body: "Aperture has no servers that store your wallet, balances, transactions, or addresses.")
                bulletRow(systemImage: "chart.bar.xaxis",
                          title: "No analytics",
                          body: "No telemetry, no event tracking, no crash reports sent back to Aperture.")
                bulletRow(systemImage: "envelope.badge.shield.half.filled",
                          title: "No outreach",
                          body: "Nobody from Aperture will ever message you. There is no Aperture support team. Treat any message claiming to be from Aperture as a scam.")
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) { dismiss() }
        }
    }

    private func bulletRow(systemImage: String, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(title)
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(body)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
