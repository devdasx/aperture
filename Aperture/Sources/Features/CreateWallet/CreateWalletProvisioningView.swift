import SwiftUI

/// Create-wallet entry into the **unified** `ProcessLyricsScreen`
/// (via `WalletSetupProcessView` adapter). Design lives only on
/// `ProcessLyricsScreen` — do not reimplement process chrome here.
struct CreateWalletProvisioningView: View {
    let state: CreateWalletState
    let requiresBackup: Bool
    var manualBackup: Bool = false
    let onFinished: () -> Void
    var onRequiresBackupFlag: (() -> Void)? = nil

    var body: some View {
        WalletSetupProcessView(
            mode: .create,
            perform: { onProgress in
                let repository = WalletCommandRepository()
                _ = try await state.persist(
                    into: repository,
                    requiresBackup: requiresBackup,
                    manualBackup: manualBackup,
                    onProgress: onProgress
                )
                state.zeroSensitiveState()
                if requiresBackup {
                    onRequiresBackupFlag?()
                }
            },
            onFinished: onFinished,
            logCategory: "create-wallet-provisioning"
        )
    }
}

#Preview("Provisioning") {
    NavigationStack {
        CreateWalletProvisioningView(
            state: CreateWalletState(),
            requiresBackup: true,
            onFinished: {}
        )
    }
}
