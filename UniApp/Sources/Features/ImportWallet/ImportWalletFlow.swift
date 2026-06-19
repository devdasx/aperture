import SwiftUI
import OSLog

/// Push destinations within the Import Wallet flow. Mirrors the
/// `RecoveryPhraseFlow` pattern — value-typed enum with associated
/// chain values for chain-scoped destinations so the hoisted
/// `NavigationPath` survives RTL flips (Rule #12 §G).
enum ImportDestination: Hashable, Codable, Identifiable {
    case mnemonicEntry
    case mnemonicReview
    case iCloudRestore
    case keyChainPicker
    case keyEntry(SupportedChain)
    case keyReview(SupportedChain)
    case watchOnlyChainPicker
    case watchOnlyEntry(SupportedChain)
    case watchOnlyReview(SupportedChain)
    /// Terminal success step — pushed after a successful commit, carrying
    /// the persisted wallet id + what was imported so the success screen
    /// can render the right variant and read the wallet's real networks.
    case success(walletId: UUID, result: ImportResult)

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
    /// **Persistence happens before this fires.** Each method's review
    /// step calls `state.persist(result:into:)` synchronously inside
    /// the commit handler; the wallet is in SwiftData (and its seed,
    /// if any, in Keychain) by the time the parent sees the
    /// `onCompleted` callback.
    let onCompleted: (ImportResult) -> Void

    @State private var state = ImportWalletState()

    /// Set when `persist` throws — drives the retryable error alert.
    /// Navigation stays in place so the user can simply tap the
    /// commit button again.
    @State private var isShowingPersistError = false

    /// True while `persistThen` is running (derive + write to SwiftData +
    /// Keychain + fire first refresh). Passed down to whichever review
    /// view is on screen so its commit `UniButton` shows the native
    /// loading spinner while the wallet is being saved — the work takes a
    /// real beat, and a silent button reads as a frozen app (Rule #28:
    /// the work stays off-main; the view just reflects the state).
    @State private var isCommitting = false

    @Environment(\.modelContext) private var modelContext

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "import-wallet-flow"
    )

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
                        onContinue: {
                            navigationPath.append(ImportDestination.mnemonicReview)
                        }
                    )
                case .mnemonicReview:
                    MnemonicReviewView(
                        state: state,
                        isCommitting: isCommitting,
                        onCommit: {
                            persistThen(.mnemonic)
                        }
                    )
                case .iCloudRestore:
                    // Restore reuses the canonical mnemonic-import path
                    // internally, then routes to the shared success screen.
                    ICloudRestoreView(
                        state: state,
                        onImported: { walletId in
                            navigationPath.append(
                                ImportDestination.success(walletId: walletId, result: .mnemonic)
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
                        isCommitting: isCommitting,
                        onCommit: {
                            persistThen(.privateKey(chain))
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
                        isCommitting: isCommitting,
                        onCommit: {
                            persistThen(.watchOnly(chain))
                        }
                    )
                case .success(let walletId, let result):
                    ImportSuccessView(
                        walletId: walletId,
                        result: result,
                        onContinue: { onCompleted(result) }
                    )
                }
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .alert(
            Text("Couldn't save your wallet"),
            isPresented: $isShowingPersistError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Aperture couldn't write your wallet to this iPhone. Nothing was imported. Try again.")
        }
    }

    /// Persist the imported wallet via `WalletRepository`, then fire
    /// `onCompleted` so the parent can dismiss. On failure the flow
    /// does NOT complete — completing without a persisted seed would
    /// hand the parent a zombie wallet with no key material in the
    /// Keychain. Instead the error is logged, an alert names the
    /// failure, and navigation stays in place so the user can retry
    /// the commit from the same review screen.
    private func persistThen(_ result: ImportResult) {
        // Suppress a double-commit: the button is already showing its
        // loading spinner + disabled, but guard the async path too.
        guard !isCommitting else { return }
        isCommitting = true
        let repository = WalletRepository(modelContainer: modelContext.container)
        let container = modelContext.container
        Task { @MainActor in
            defer { isCommitting = false }
            do {
                let walletId = try await state.persist(result: result, into: repository)
                // Seed / key bytes are now encrypted in Keychain —
                // the plaintext inputs have no reason to outlive the
                // flow.
                state.zeroSensitiveInput()
                // Fire the imported wallet's FIRST balance + history
                // refresh here, with the known-good id (2026-06-12).
                // Belt and braces for the wallet-home's own
                // `.task(id: activeWalletIdRaw)` auto-refresh: its
                // `@Query` lags this actor-context insert in the
                // merge window right after persist, which is how an
                // imported wallet used to show $0.00 until relaunch.
                // `WalletRefreshRegistry` single-flights per wallet,
                // so when the home fires too, both await the same
                // pipeline — the overlap costs nothing.
                let fiatCode = UserDefaults.standard.string(forKey: CurrencyPreference.storageKey)
                    ?? CurrencyPreference.defaultCode
                Task {
                    await WalletRefreshCoordinator(container: container)
                        .refreshWallet(walletId: walletId, fiatCode: fiatCode)
                }
                // Show the success screen as the terminal step instead of
                // dismissing straight onto the (still-scanning) wallet —
                // the first refresh above runs in the background while the
                // user reads the result, and its "Continue to wallet" CTA
                // fires `onCompleted`, dismissing the cover (2026-06-19).
                navigationPath.append(
                    ImportDestination.success(walletId: walletId, result: result)
                )
            } catch {
                Self.log.error(
                    "Wallet import persist failed: \(String(describing: error), privacy: .public)"
                )
                isShowingPersistError = true
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

    @AppStorage("hideImportKeyWarning") private var hideImportKeyWarning: Bool = false

    /// When non-nil, the security-warning sheet is presented. Carries
    /// the destination to push after the user confirms.
    @State private var pendingProtectedDestination: ImportDestination?

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
                .listRowBackground(UniColors.Background.secondary)

                methodRow(
                    systemImage: "text.book.closed",
                    title: "Recovery phrase",
                    info: .recoveryPhrase,
                    onPick: { handleProtectedTap(.mnemonicEntry) }
                )
                .listRowBackground(UniColors.Background.secondary)

                methodRow(
                    systemImage: "key.horizontal",
                    title: "Private key",
                    info: .privateKey,
                    onPick: { handleProtectedTap(.keyChainPicker) }
                )
                .listRowBackground(UniColors.Background.secondary)

                methodRow(
                    systemImage: "eye",
                    title: "Watch-only",
                    info: .watchOnly,
                    onPick: { onPick(.watchOnlyChainPicker) }
                )
                .listRowBackground(UniColors.Background.secondary)
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
        .sheet(item: $pendingProtectedDestination) { destination in
            ImportSecurityWarningSheet(
                onProceed: { suppressFuture in
                    if suppressFuture { hideImportKeyWarning = true }
                    pendingProtectedDestination = nil
                    // Defer push by a frame so the sheet dismiss animation
                    // doesn't race with the NavigationStack push.
                    DispatchQueue.main.async {
                        onPick(destination)
                    }
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(item: $infoMethod) { info in
            ImportMethodInfoSheet(info: info)
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle("Import wallet")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text("Cancel"))
            }
        }
    }

    private func handleProtectedTap(_ destination: ImportDestination) {
        if hideImportKeyWarning {
            onPick(destination)
        } else {
            pendingProtectedDestination = destination
        }
    }

    /// One import-method row. The body (icon + title) picks the method;
    /// the trailing **Info** button opens the per-method explainer sheet.
    /// Two SIBLING buttons (not nested) so each is independently tappable
    /// inside the List row with no gesture ambiguity.
    private func methodRow(
        systemImage: String,
        title: LocalizedStringKey,
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
                    Text(title)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { infoMethod = info } label: {
                HStack(spacing: 3) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .regular))
                    Text("Info")
                        .font(UniTypography.subheadline)
                }
                .foregroundStyle(UniColors.Text.secondary)
                .padding(.vertical, 6)
                .padding(.leading, UniSpacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("About \(Text(title))"))
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}
