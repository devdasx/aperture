import SwiftUI

/// Push destinations within the Import Wallet flow. Mirrors the
/// `RecoveryPhraseFlow` pattern — value-typed enum with associated
/// chain values for chain-scoped destinations so the hoisted
/// `NavigationPath` survives RTL flips (Rule #12 §G).
enum ImportDestination: Hashable, Codable, Identifiable {
    case mnemonicEntry
    case iCloudRestore
    case keyChainPicker
    case keyEntry(SupportedChain)
    case keyReview(SupportedChain)
    case watchOnlyChainPicker
    case watchOnlyEntry(SupportedChain)
    case watchOnlyReview(SupportedChain)
    /// Onboarding only: passcode → Face ID before the process screen.
    case pinSetup(ImportResult)
    /// Shared process screen: encrypt / save with real progress — always last.
    case provisioning(ImportResult)

    var id: Self { self }
}

/// Root content of the Import Wallet `fullScreenCover`. Hosts a
/// `NavigationStack` for the flow; same shape as `RecoveryPhraseFlow`.
struct ImportWalletFlow: View {
    /// Hoisted navigation path — owned by `OnboardingView`, passed in
    /// as a binding so RTL flips don't reset the user's location.
    @Binding var navigationPath: NavigationPath

    let onDismiss: () -> Void

    /// Fires when the user successfully imports a wallet (any method).
    /// The parent (`OnboardingView`) clears the "no wallet" flag and
    /// dismisses the cover. Carries a description of what was imported
    /// so the parent can show an appropriate confirmation later.
    ///
    /// **Persistence happens before this fires.** Commit screens push the
    /// shared process view, which runs `state.persist` with real progress;
    /// the wallet is in GRDB before `onCompleted` runs.
    let onCompleted: (ImportResult) -> Void

    /// When `true` (onboarding import only), require passcode + Face ID
    /// before the process screen if this device has no PIN yet.
    var requiresPasscodeSetup: Bool = false

    @State private var state = ImportWalletState()

    @State private var duplicateImport: DuplicateImportPresentation?
    /// Prevents double-tap Import from stacking process screens.
    @State private var isAdvancing = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ImportMethodSelectionView(
                onDismiss: onDismiss,
                onPick: { destination in
                    navigationPath.append(destination)
                }
            )
            .navigationDestination(for: ImportDestination.self) { destination in
                switch destination {
                case .mnemonicEntry:
                    MnemonicEntryView(
                        state: state,
                        isCommitting: false,
                        onContinue: {
                            pushProvisioning(.mnemonic)
                        }
                    )
                case .iCloudRestore:
                    // Restore reuses the canonical mnemonic-import path
                    // internally, then dismisses to the main wallet shell.
                    ICloudRestoreView(
                        state: state,
                        onImported: { _ in
                            finishImport(.mnemonic)
                        },
                        onDuplicate: { match in
                            duplicateImport = DuplicateImportPresentation(
                                match: match,
                                result: .mnemonic,
                                returnsToPreviousScreen: true
                            )
                        }
                    )
                case .keyChainPicker:
                    ChainPickerView(title: "Choose a chain") { chain in
                        state.selectedChain = chain
                        navigationPath.append(ImportDestination.keyEntry(chain))
                    }
                case .keyEntry(let chain):
                    PrivateKeyEntryView(
                        state: state,
                        chain: chain,
                        onContinue: {
                            navigationPath.append(ImportDestination.keyReview(chain))
                        }
                    )
                case .keyReview(let chain):
                    PrivateKeyReviewView(
                        state: state,
                        chain: chain,
                        isCommitting: false,
                        onCommit: {
                            pushProvisioning(.privateKey(chain))
                        }
                    )
                case .watchOnlyChainPicker:
                    ChainPickerView(title: "Choose a chain") { chain in
                        state.selectedChain = chain
                        navigationPath.append(ImportDestination.watchOnlyEntry(chain))
                    }
                case .watchOnlyEntry(let chain):
                    WatchOnlyEntryView(
                        state: state,
                        chain: chain,
                        onContinue: {
                            navigationPath.append(ImportDestination.watchOnlyReview(chain))
                        }
                    )
                case .watchOnlyReview(let chain):
                    WatchOnlyReviewView(
                        state: state,
                        chain: chain,
                        isCommitting: false,
                        onCommit: {
                            pushProvisioning(.watchOnly(chain))
                        }
                    )
                case .pinSetup(let result):
                    // Passcode → Face ID, then process (last step).
                    PinSetupFlow(
                        onFinish: {
                            guard !isAdvancing else { return }
                            isAdvancing = true
                            pushProvisioningDestination(result)
                        },
                        onBack: {
                            isAdvancing = false
                            if !navigationPath.isEmpty {
                                navigationPath.removeLast()
                            }
                        }
                    )
                case .provisioning(let result):
                    WalletSetupProcessView(
                        mode: processMode(for: result),
                        perform: { onProgress in
                            let repository = WalletCommandRepository()
                            _ = try await state.persist(
                                result: result,
                                into: repository,
                                onProgress: onProgress
                            )
                            state.zeroSensitiveInput()
                        },
                        onFinished: {
                            // User tapped Open Wallet on the process screen.
                            onCompleted(result)
                        },
                        onDuplicateImport: { match in
                            // Pop the process screen so the user returns to the
                            // commit screen under the duplicate sheet.
                            if !navigationPath.isEmpty {
                                navigationPath.removeLast()
                            }
                            isAdvancing = false
                            duplicateImport = DuplicateImportPresentation(
                                match: match,
                                result: result,
                                returnsToPreviousScreen: result != .mnemonic
                            )
                        },
                        logCategory: "import-wallet-provisioning"
                    )
                }
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .sheet(item: $duplicateImport) { duplicate in
            AlreadyImportedWalletSheet(
                walletName: duplicate.match.name,
                onTryAnother: { tryAnotherWallet(after: duplicate) },
                onUseWallet: { useExistingWallet(duplicate) }
            )
            .apertureEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    /// After import commit: onboarding may need passcode + Face ID first;
    /// process screen is always the last step.
    private func pushProvisioning(_ result: ImportResult) {
        guard !isAdvancing else { return }
        if requiresPasscodeSetup, !PinCodeStorage.hasPin {
            isAdvancing = false
            Task { @MainActor in
                await Task.yield()
                var transaction = Transaction(animation: .default)
                transaction.disablesAnimations = false
                withTransaction(transaction) {
                    navigationPath.append(ImportDestination.pinSetup(result))
                }
            }
            return
        }
        isAdvancing = true
        pushProvisioningDestination(result)
    }

    private func pushProvisioningDestination(_ result: ImportResult) {
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction(animation: .default)
            transaction.disablesAnimations = false
            withTransaction(transaction) {
                navigationPath.append(ImportDestination.provisioning(result))
            }
        }
    }

    private func processMode(for result: ImportResult) -> WalletSetupProcessMode {
        switch result {
        case .mnemonic, .privateKey: return .importWallet
        case .watchOnly: return .watchOnly
        }
    }

    private func finishImport(_ result: ImportResult) {
        // No success alert — land on main with first-refresh only.
        WalletFirstRefreshPresentationCenter.markNewWallet(
            ActiveWalletPointer.currentId,
            kind: .imported
        )
        ScreenRestoration.routeToMainScreenNow()
        onCompleted(result)
    }

    private func tryAnotherWallet(after duplicate: DuplicateImportPresentation) {
        duplicateImport = nil
        isAdvancing = false
        state.resetInput(for: duplicate.result)
        if duplicate.returnsToPreviousScreen, !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    private func useExistingWallet(_ duplicate: DuplicateImportPresentation) {
        duplicateImport = nil
        ActiveWalletPointer.set(duplicate.match.id)
        state.zeroSensitiveInput()
        ScreenRestoration.routeToMainScreenNow()
        onCompleted(duplicate.result)
    }
}

private struct DuplicateImportPresentation: Identifiable {
    let match: ExistingWalletImportMatch
    let result: ImportResult
    let returnsToPreviousScreen: Bool

    var id: UUID { match.id }
}

private struct AlreadyImportedWalletSheet: View {
    let walletName: String
    let onTryAnother: () -> Void
    let onUseWallet: () -> Void

    var body: some View {
        UniSheet(title: "Wallet already imported", icon: "wallet.pass") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                Text(verbatim: walletName)
                    .font(UniTypography.headline)
                    .foregroundStyle(UniColors.Text.primary)
                UniBody(
                    text: "This wallet is already saved in Aperture. No duplicate was created. You can enter different wallet details or switch to the saved wallet now.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            VStack(spacing: UniSpacing.s) {
                UniButton(title: "Use this wallet", variant: .primary) {
                    onUseWallet()
                }
                UniButton(title: "Try another wallet", variant: .secondary) {
                    onTryAnother()
                }
            }
        }
    }
}

/// Summary of what the user imported. Returned to the presenter via
/// `onCompleted` so the parent can react appropriately (e.g. show a
/// different confirmation per method).
enum ImportResult: Hashable, Sendable, Codable {
    case mnemonic
    case privateKey(SupportedChain)
    case watchOnly(SupportedChain)
}

// MARK: - Method selection (root)

private struct ImportMethodSelectionView: View {
    let onDismiss: () -> Void
    let onPick: (ImportDestination) -> Void

    /// When non-nil, the per-method "Info" explainer sheet is presented.
    @State private var infoMethod: ImportInfo?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: UniSpacing.s) {
                    UniHeadline(
                        text: "Bring an existing wallet into Aperture.",
                        alignment: .leading
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    UniBody(
                        text: "Aperture imports keys locally. Nothing leaves this iPhone.",
                        color: UniColors.Text.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, UniSpacing.s)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                // Each row: the body picks the method; the trailing "Info"
                // button opens a deep per-method explainer sheet (2026-06-20
                // — replaced the terse trailing captions). Recovery phrase +
                // Private key still route through the security warning gate.
                methodRow(
                    systemImage: "icloud.and.arrow.down",
                    title: "Restore from iCloud",
                    info: .iCloud,
                    onPick: { onPick(.iCloudRestore) }
                )
                .uniListRowSurface()

                methodRow(
                    systemImage: "text.book.closed",
                    title: "Recovery phrase",
                    info: .recoveryPhrase,
                    onPick: { onPick(.mnemonicEntry) }
                )
                .uniListRowSurface()

                methodRow(
                    systemImage: "key.horizontal",
                    title: "Private key",
                    info: .privateKey,
                    onPick: { onPick(.keyChainPicker) }
                )
                .uniListRowSurface()

                methodRow(
                    systemImage: "eye",
                    title: "Watch-only",
                    info: .watchOnly,
                    onPick: { onPick(.watchOnlyChainPicker) }
                )
                .uniListRowSurface()
            }

            Section {
                EmptyView()
            } footer: {
                Text("Watch-only wallets can see balances and transactions. They cannot send. Imported private keys cover a single chain — your other chains stay outside Aperture until you also import their keys or your recovery phrase.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $infoMethod) { info in
            ImportMethodInfoSheet(info: info)
                .apertureEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .uniListPageChrome()
        .navigationTitle("Import wallet")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .regular))
                }
                .accessibilityLabel(Text("Cancel"))
            }
        }
    }

    /// One import-method row. The body (icon + title) picks the method;
    /// the trailing **Info** button opens the per-method explainer sheet.
    /// Two SIBLING buttons (not nested) so each is independently tappable
    /// inside the List row with no gesture ambiguity.
    private func methodRow(
        systemImage: String,
        title: String,
        info: ImportInfo,
        onPick: @escaping () -> Void
    ) -> some View {
        HStack(spacing: UniSpacing.s) {
            Button(action: onPick) {
                HStack(spacing: UniSpacing.s) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(UniColors.Icon.secondary)
                        .frame(width: 28, alignment: .center)
                        .accessibilityHidden(true)
                    Text(LocalizedStringKey(title))
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer(minLength: 0)
                }
                .uniListRowHitTarget()
            }
            .buttonStyle(.uniListRow)

            // Info icon only (no label), placed BEFORE the chevron
            // (2026-06-20 user direction).
            Button { infoMethod = info } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .padding(.vertical, 6)
                    .padding(.leading, UniSpacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: String(
                format: String.apertureLocalized("About %@"),
                String.apertureLocalizedKey(title)
            )))

            Image(systemName: UniDirectionalSymbol.disclosure)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(UniColors.Icon.tertiary)
                .accessibilityHidden(true)
        }
    }
}
