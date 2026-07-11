import SwiftUI

/// Inline banner shown when `BiometricEnrollmentTracker.checkForDrift`
/// flipped `AppMetadataRecord.requiresBiometricReenrollment = true` —
/// the user changed their biometric enrollment in iOS
/// Settings since their last successful Aperture biometric auth, so
/// Aperture's `biometricEnabled` has been disabled defensively.
///
/// Tapping opens the system biometric prompt; on success we capture
/// the new snapshot via `BiometricEnrollmentTracker.acknowledgeReenrollment`
/// and the banner disappears (the GRDB observation of `AppMetadataRecord` is
/// reactive — flipping the flag re-renders the wallet home without it).
struct BiometricReenrollmentBanner: View {
    @GRDBStorage("biometricEnabled") private var biometricEnabled: Bool = false
    @GRDBStorage(PinCodePreference.requireBiometricForSendKey) private var requireForSend: Bool = true
    @State private var biometricService = BiometricService()

    var body: some View {
        if biometricService.isAvailable {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                Image(systemName: biometricService.biometryType.systemImageName)
                    .font(.system(size: 22, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Feedback.Info.foreground)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: "Re-enable \(biometricService.biometryType.displayName).")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "Your \(biometricService.biometryType.displayName) enrollment changed. Authenticate once to trust this iPhone again.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(UniSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Feedback.Info.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .stroke(UniColors.Feedback.Info.stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { Task { await reenroll() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(verbatim: "Re-enable \(biometricService.biometryType.displayName)"))
            .accessibilityHint(Text("Opens the biometric prompt to confirm your enrollment."))
        }
    }

    private func reenroll() async {
        let service = BiometricService()
        guard service.isAvailable else { return }
        let outcome = await service.authenticate(reason: service.biometryType.reenrollmentReason)
        switch outcome {
        case .success:
            BiometricEnrollmentTracker.acknowledgeReenrollment(database: AppDatabase.shared)
            biometricEnabled = true
            requireForSend = true
        case .failure:
            // Silent on failure — user cancelled or failed, banner
            // stays so they can try again. No error theatre.
            break
        }
    }
}
