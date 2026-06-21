import SwiftUI

/// The **Reset Aperture** section — the app's nuclear hatch. Moved out of the
/// removed Advanced screen to live directly on the Settings screen (2026-06-19,
/// user direction). Renders the destructive row + its honest footer, and opens
/// the full-screen `ResetApertureFlow` (`design_handoff_reset`) which owns
/// every gate and the real staged wipe.
///
/// A self-contained `View` whose body IS a `Section`, so `SettingsView` embeds
/// it inside its `List` with one line.
struct ResetApertureSection: View {
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @State private var isShowingResetSheet: Bool = false

    /// Rule #12 §G direction-only key for sheet content rebuild
    /// (`"ltr"` / `"rtl"`).
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    var body: some View {
        Section {
            Button {
                isShowingResetSheet = true
            } label: {
                HStack(spacing: UniSpacing.s) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(UniColors.Status.errorForeground)
                        .frame(width: 28)
                    Text("Reset Aperture")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Status.errorForeground)
                    Spacer()
                }
                .padding(.vertical, UniSpacing.xxs)
            }
            .buttonStyle(.plain)
            .listRowBackground(UniColors.Background.secondary)
        } footer: {
            Text("Deletes every wallet, every encrypted seed, every cached balance, every preference. This cannot be undone — back up any recovery phrases first.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Status.errorForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        // App-wide reset is FULL-SCREEN, not a sheet (design_handoff_reset).
        // The flow owns every gate (warning → backup checkpoint → three
        // acknowledgements → typed RESET → Face ID / passcode) and the real
        // staged wipe (`FactoryReset.performStagedWipe`). It dismisses itself
        // via `onClose` — the ✕/Cancel on any gate, and "Get Started" once the
        // wipe completes (by then the wallet count is zero, so `RootGate`
        // routes to onboarding).
        .fullScreenCover(isPresented: $isShowingResetSheet) {
            ResetApertureFlow(onClose: { isShowingResetSheet = false })
                .id(sheetDirectionKey)
                .uniAppEnvironment()
        }
    }
}
