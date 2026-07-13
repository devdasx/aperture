import SwiftUI

/// Full-screen **remove one wallet** flow (not a sheet).
///
/// 1. Confirm — honest inventory + consequence  
/// 2. Auth — Face ID / passcode / system confirm  
/// 3. Process — shared `ProcessLyricsScreen` (same chrome as setup / reset)
///
/// Parent presents this with `.fullScreenCover` on a surface that **survives**
/// the GRDB row disappearing (do not attach the cover only to content that
/// depends on the live wallet record — that flashes “no longer in the local
/// store” mid-process).
struct WalletRemoveFlow: View {
    let walletId: UUID
    let walletName: String
    let kind: WalletKind
    let networkCount: Int
    let hasStoredSecret: Bool
    /// Called after work finishes and the user taps Done.
    let onFinished: (WalletRepository.RemoveWalletResult) -> Void
    let onCancel: () -> Void

    private enum Route: Hashable {
        case processing
    }

    @State private var path: [Route] = []
    @State private var isShowingPasscodeGate = false
    @State private var passcodeAutoPromptBiometrics = true
    /// System alert after “Remove this wallet” — Cancel or confirm (then auth/process).
    @State private var isShowingFinalConfirm = false
    @State private var deleteErrorMessage: String?
    @State private var removalResult: WalletRepository.RemoveWalletResult?

    var body: some View {
        NavigationStack(path: $path) {
            confirmScreen
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .processing:
                        ProcessLyricsScreen(
                            configuration: .removeWallet(walletName: walletName),
                            perform: { report in
                                try await runDelete(report: report)
                            },
                            onPrimary: {
                                // `perform` always sets `removalResult` before success UI.
                                onFinished(removalResult ?? .appWiped)
                            },
                            mapFailureMessage: { _ in
                                deleteErrorMessage
                                    ?? String.apertureLocalized("Couldn't delete this wallet from the local database. Try again.")
                            }
                        )
                    }
                }
        }
        // Real system alert (not action sheet) — Cancel stays available.
        .alert(
            Text(verbatim: String(format: String.apertureLocalized("Remove %@?"), walletName)),
            isPresented: $isShowingFinalConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove wallet", role: .destructive) {
                proceedAfterFinalConfirm()
            }
        } message: {
            Text(finalConfirmMessage)
        }
        .sheet(isPresented: $isShowingPasscodeGate) {
            SensitiveAuthPasscodeSheet(
                accessContext: .removeWallet,
                autoPromptBiometrics: passcodeAutoPromptBiometrics,
                allowsBiometrics: true,
                onComplete: {
                    isShowingPasscodeGate = false
                    path.append(.processing)
                },
                onCancel: {
                    isShowingPasscodeGate = false
                }
            )
        }
    }

    // MARK: - Confirm (full screen)

    private var confirmScreen: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 52, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(UniColors.Feedback.Error.foreground)
                        .frame(maxWidth: .infinity)
                        .padding(.top, UniSpacing.m)
                        .accessibilityHidden(true)

                    UniBody(
                        text: "This removes \(walletName) from this iPhone. Every other wallet stays exactly as it is.",
                        color: UniColors.Text.secondary
                    )

                    erasedList
                    consequenceLine
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.xl)
            }

            UniButton(
                title: "Remove this wallet",
                variant: .destructive
            ) {
                isShowingFinalConfirm = true
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle(Text("Remove wallet"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onCancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .regular))
                }
                .accessibilityLabel(Text("Cancel"))
            }
        }
    }

    private var erasedList: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                erasedRow(symbol: "number", label: addressesRowLabel)
                UniDivider()
                erasedRow(symbol: "chart.line.uptrend.xyaxis", label: "Its transaction and chart history on this iPhone")
                if hasStoredSecret {
                    UniDivider()
                    erasedRow(symbol: "key.fill", label: secretRowLabel)
                }
            }
        }
    }

    private func erasedRow(symbol: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 26, alignment: .center)
                .accessibilityHidden(true)
            UniBody(text: label, color: UniColors.Text.primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var consequenceLine: some View {
        switch kind {
        case .watchOnly:
            UniBody(
                text: "This wallet only watches an address — nothing secret is stored on this iPhone, so nothing secret is lost. You can add it again anytime.",
                color: UniColors.Text.secondary
            )
        case .created, .importedMnemonic:
            if hasStoredSecret {
                UniBody(
                    text: "Your recovery phrase stays yours. You can import this wallet again with it — there is no server, and removing it here loses nothing you've written down.",
                    color: UniColors.Text.secondary
                )
            } else {
                UniBody(
                    text: "This wallet's recovery phrase isn't stored on this iPhone. Unless you have it written down elsewhere, removing it here is final — the funds in it can't be recovered.",
                    color: UniColors.Feedback.Error.foreground
                )
            }
        case .importedKey:
            if hasStoredSecret {
                UniBody(
                    text: "Your private key stays yours. You can import this wallet again with it — there is no server, and removing it here loses nothing you've saved.",
                    color: UniColors.Text.secondary
                )
            } else {
                UniBody(
                    text: "This wallet's private key isn't stored on this iPhone. Unless you have it saved elsewhere, removing it here is final — the funds in it can't be recovered.",
                    color: UniColors.Feedback.Error.foreground
                )
            }
        }
    }

    private var addressesRowLabel: LocalizedStringKey {
        if networkCount <= 1 {
            return "Its address on this iPhone"
        }
        return "Its addresses on \(networkCount) networks"
    }

    private var secretRowLabel: LocalizedStringKey {
        switch kind {
        case .importedKey:
            return "Its encrypted private key in the database"
        default:
            return "Its encrypted recovery phrase in the database"
        }
    }

    /// Warning body for the system alert — honest consequence + cancel is safe.
    private var finalConfirmMessage: LocalizedStringKey {
        switch kind {
        case .watchOnly:
            return "This stops watching the address on this iPhone. Nothing secret is stored here. Other wallets stay. You can cancel if you changed your mind."
        case .created, .importedMnemonic, .importedKey:
            if hasStoredSecret {
                return "This permanently removes the wallet from this iPhone — addresses, history, and its encrypted secret in the local database. Other wallets stay. You can import it again with its recovery phrase or key. Cancel if you changed your mind."
            }
            return "This permanently removes the wallet from this iPhone. Its secret isn't stored here — unless you have it elsewhere, funds can't be recovered. Other wallets stay. Cancel if you changed your mind."
        }
    }

    // MARK: - Auth + delete

    /// After the system alert’s destructive confirm: Face ID / passcode if set, else process.
    private func proceedAfterFinalConfirm() {
        if PinCodeStorage.hasPin {
            Task { @MainActor in
                let gate = await SensitiveActionAuth.gatePreferringBiometric()
                switch gate {
                case .authorized:
                    path.append(.processing)
                case .presentPasscode(let autoPrompt):
                    passcodeAutoPromptBiometrics = autoPrompt
                    isShowingPasscodeGate = true
                }
            }
        } else {
            path.append(.processing)
        }
    }

    private func runDelete(
        report: @escaping @MainActor (Int, Double) async -> Void
    ) async throws {
        // Stage 0 — addresses / network data scope
        await report(0, 0.12)
        try? await Task.sleep(for: .milliseconds(120))
        await report(0, 0.25)

        // Stage 1 — history / charts
        await report(1, 0.40)
        try? await Task.sleep(for: .milliseconds(80))
        await report(1, 0.50)

        // Stage 2 — encrypted secret rows (deleted with wallet / wipe)
        await report(2, 0.62)
        try? await Task.sleep(for: .milliseconds(80))
        await report(2, 0.75)

        // Stage 3 — delete + choose next active (balance → used → random),
        // or full factory wipe when this was the last wallet.
        await report(3, 0.88)
        let repo = WalletRepository(database: AppDatabase.shared)
        do {
            let result = try await repo.removeWalletSelectingSuccessor(walletId: walletId)
            removalResult = result
        } catch {
            deleteErrorMessage = String.apertureLocalized("Couldn't delete this wallet from the local database. Try again.")
            throw error
        }
        await report(3, 1.0)
    }
}

// MARK: - Backward-compatible name

/// Historical type name — full-screen remove flow (no longer a sheet).
typealias WalletDeleteSheet = WalletRemoveFlow
