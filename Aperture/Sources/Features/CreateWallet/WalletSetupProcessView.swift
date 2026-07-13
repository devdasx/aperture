import SwiftUI

/// Domain stages for create / import — **4 steps** matching process handoff.
/// UI chrome is only `ProcessLyricsScreen`.
enum WalletSetupStage: Int, CaseIterable, Sendable, Hashable {
    /// Ring segment 0 — deriving addresses / keys.
    case derivingKeys
    /// Ring segment 1 — encrypting on device.
    case encrypting
    /// Ring segment 2 — writing wallet to disk.
    case securingWallet
    /// Ring segment 3 — activate as current wallet.
    case almostReady

    var progressCeiling: Double {
        switch self {
        case .derivingKeys: return 0.25
        case .encrypting: return 0.50
        case .securingWallet: return 0.75
        case .almostReady: return 1.0
        }
    }
}

enum WalletSetupProcessMode: Sendable, Hashable {
    case create
    case importWallet
    case watchOnly

    var completionNotice: WalletFirstRefreshKind {
        switch self {
        case .create: return .created
        case .importWallet, .watchOnly: return .imported
        }
    }
}

// MARK: - Domain adapter → unified ProcessLyricsScreen

/// Thin adapter: maps wallet-setup stages onto the handoff process screen.
struct WalletSetupProcessView: View {
    let mode: WalletSetupProcessMode
    let perform: (@escaping @MainActor (WalletSetupStage, Double) async -> Void) async throws -> Void
    let onFinished: () -> Void
    var onDuplicateImport: ((ExistingWalletImportMatch) -> Void)? = nil
    var logCategory: String = "wallet-setup-process"

    var body: some View {
        ProcessLyricsScreen(
            configuration: ProcessLyricsConfiguration
                .walletSetup(mode: mode)
                .withLogCategory(logCategory),
            perform: { report in
                try await perform { stage, fraction in
                    await report(stage.rawValue, fraction)
                }
            },
            onPrimary: {
                WalletFirstRefreshPresentationCenter.markNewWallet(
                    ActiveWalletPointer.currentId,
                    kind: mode.completionNotice
                )
                ScreenRestoration.routeToMainScreenNow()
                var transaction = Transaction(animation: .default)
                transaction.disablesAnimations = false
                withTransaction(transaction) {
                    onFinished()
                }
            },
            onSpecialError: { error in
                if case WalletCommandRepositoryError.alreadyImported(let match) = error {
                    onDuplicateImport?(match)
                    return true
                }
                return false
            },
            mapFailureMessage: { error in
                if let vault = error as? SeedVault.VaultError {
                    switch vault {
                    case .invalidSeedLength:
                        return String.apertureLocalized("The wallet's key material looked invalid. Tap Try Again.")
                    case .databaseWriteFailed(let detail), .databaseReadFailed(let detail), .databaseDeleteFailed(let detail):
                        return String(format: String.apertureLocalized("Couldn't save your wallet: %@. Tap Try Again."), detail)
                    default:
                        return String.apertureLocalized("Couldn't save your wallet. Tap Try Again.")
                    }
                }
                if error is KeyImportError {
                    return String.apertureLocalized("Couldn't derive addresses for this wallet. Check the details and try again.")
                }
                return String(format: String.apertureLocalized("Couldn't save your wallet: %@. Tap Try Again."), error.localizedDescription)
            }
        )
    }
}

#Preview("Create process") {
    NavigationStack {
        WalletSetupProcessView(
            mode: .create,
            perform: { onProgress in
                for stage in WalletSetupStage.allCases {
                    await onProgress(stage, stage.progressCeiling * 0.5)
                    try? await Task.sleep(for: .milliseconds(500))
                    await onProgress(stage, stage.progressCeiling)
                }
            },
            onFinished: {}
        )
    }
}
