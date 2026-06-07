import SwiftUI
import SwiftData

/// Inline banner shown when `BiometricEnrollmentTracker.checkForDrift`
/// flipped `AppMetadataRecord.requiresBiometricReenrollment = true` —
/// the user changed their Face ID / Touch ID enrollment in iOS
/// Settings since their last successful Aperture biometric auth, so
/// Aperture's `biometricEnabled` has been disabled defensively.
///
/// Tapping opens the system biometric prompt; on success we capture
/// the new snapshot via `BiometricEnrollmentTracker.acknowledgeReenrollment`
/// and the banner disappears (the `@Query` of `AppMetadataRecord` is
/// reactive — flipping the flag re-renders the wallet home without it).
struct BiometricReenrollmentBanner: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("biometricEnabled") private var biometricEnabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "faceid")
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Status.infoForeground)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text("Re-enable Face ID.")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your Face ID enrollment changed. Authenticate once to trust this iPhone again.")
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
            RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                .fill(UniColors.Status.infoBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                .stroke(UniColors.Status.infoStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { Task { await reenroll() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Re-enable Face ID"))
        .accessibilityHint(Text("Opens the biometric prompt to confirm your enrollment."))
    }

    private func reenroll() async {
        let service = BiometricService()
        let outcome = await service.authenticate(
            reason: LocalizedStringResource("Confirm your new Face ID enrollment.")
        )
        switch outcome {
        case .success:
            BiometricEnrollmentTracker.acknowledgeReenrollment(in: modelContext.container)
            biometricEnabled = true
        case .failure:
            // Silent on failure — user cancelled or failed, banner
            // stays so they can try again. No error theatre.
            break
        }
    }
}
