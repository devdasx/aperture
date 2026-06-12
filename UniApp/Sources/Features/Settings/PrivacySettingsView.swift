import SwiftUI

/// Settings → Privacy. Three rows in v1:
/// 1. **Background balance refresh** toggle (`@AppStorage("backgroundBalanceRefresh")`).
///    Note: the actual `BGTaskScheduler` wiring lands as T-041 — for
///    now this toggle persists the preference but no background task
///    is scheduled. The Settings copy is honest about the current
///    state.
/// 2. **Prices** — read-only "Coinbase" disclosure row that opens the
///    Coinbase public API page externally per Rule #3 (no in-app
///    browser).
/// 3. **What Aperture doesn't collect** — Rule #16-style boundary
///    statement sheet, the load-bearing honest claim of the project.
struct PrivacySettingsView: View {
    @AppStorage("backgroundBalanceRefresh") private var backgroundRefresh: Bool = true
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
                UniToggle(isOn: $backgroundRefresh) {
                    HStack(spacing: UniSpacing.s) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(UniColors.Icon.secondary)
                            .frame(width: 28, alignment: .center)
                            .accessibilityHidden(true)
                        Text("Background refresh")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                    }
                }
                .tint(UniColors.Button.primaryTint)
                .padding(.vertical, UniSpacing.xxs)
                .listRowBackground(UniColors.Background.secondary)
            } footer: {
                Text("When enabled, Aperture will fetch balances in the background by talking to public chain RPC providers. The providers may log the request — Aperture itself records nothing about you.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                SettingsRowShared(
                    systemImage: "dollarsign.arrow.circlepath",
                    title: "Prices",
                    trailing: "Coinbase"
                )
                .listRowBackground(UniColors.Background.secondary)
            } footer: {
                Text("Fiat prices are read from Coinbase's public price API. Aperture sends only the token ticker and your selected currency code — never an address or amount.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
