import SwiftUI
import OSLog

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
    /// **Persistence happens before this fires.** The active commit
    /// path calls `state.persist(result:into:)` inside the commit
    /// handler; the wallet and its seed, if any, are in GRDB by the time the parent sees the
    /// `onCompleted` callback.
    let onCompleted: (ImportResult) -> Void

    @State private var state = ImportWalletState()

    /// Set when `persist` throws. Navigation stays in place so the user can
    /// retry from the same commit screen after reading or emailing details.
    @State private var persistErrorReport: ApertureErrorReport?

    /// True while `persistThen` is running (derive + write to GRDB +
    /// fire first refresh). Passed down to the active commit
    /// screen so its `UniButton` shows the native loading spinner while
    /// the wallet is being saved — the work takes a real beat, and a
    /// silent button reads as a frozen app (Rule #28: the work stays
    /// off-main; the view just reflects the state).
    @State private var isCommitting = false

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
                        isCommitting: isCommitting,
                        onContinue: {
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
                        onContinue: {
                            ScreenRestoration.routeToMainScreenNow()
                            onCompleted(result)
                        }
                    )
                }
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .sheet(item: $persistErrorReport) { report in
            ApertureErrorReportSheet(report: report)
                .uniAppEnvironment()
        }
    }

    /// Persist the imported wallet via `WalletCommandRepository`, then fire
    /// `onCompleted` so the parent can dismiss. On failure the flow
    /// does NOT complete — completing without a persisted seed would
    /// hand the parent a zombie wallet with no key material in GRDB.
    /// Instead the error is logged, an alert names the
    /// failure, and navigation stays in place so the user can retry
    /// the commit from the same screen.
    private func persistThen(_ result: ImportResult) {
        // Suppress a double-commit: the button is already showing its
        // loading spinner + disabled, but guard the async path too.
        guard !isCommitting else { return }
        isCommitting = true
        let repository = WalletCommandRepository()
        Task { @MainActor in
            defer { isCommitting = false }
            do {
                let walletId = try await state.persist(result: result, into: repository)
                // Seed / key bytes are now encrypted in GRDB —
                // the plaintext inputs have no reason to outlive the
                // flow.
                state.zeroSensitiveInput()
                // Show the success screen as the terminal step instead of
                // dismissing straight onto the wallet; its "Continue to
                // wallet" CTA fires `onCompleted`, dismissing the cover.
                navigationPath.append(
                    ImportDestination.success(walletId: walletId, result: result)
                )
            } catch {
                Self.log.error(
                    "Wallet import persist failed: \(String(describing: error), privacy: .public)"
                )
                let message = String.apertureLocalized("Aperture couldn't write your wallet to this iPhone. Nothing was imported. Try again.")
                persistErrorReport = ApertureErrorReport(
                    context: "Import wallet",
                    title: "Couldn't save your wallet",
                    message: message,
                    error: error,
                    recoverySuggestion: "Try importing again from the same screen. If it keeps failing, email support with the advanced details.",
                    metadata: [
                        "importResult": String(describing: result)
                    ]
                )
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
                .listRowBackground(UniColors.List.rowBackground)

                methodRow(
                    systemImage: "text.book.closed",
                    title: "Recovery phrase",
                    info: .recoveryPhrase,
                    onPick: { onPick(.mnemonicEntry) }
                )
                .listRowBackground(UniColors.List.rowBackground)

                methodRow(
                    systemImage: "key.horizontal",
                    title: "Private key",
                    info: .privateKey,
                    onPick: { onPick(.keyChainPicker) }
                )
                .listRowBackground(UniColors.List.rowBackground)

                methodRow(
                    systemImage: "eye",
                    title: "Watch-only",
                    info: .watchOnly,
                    onPick: { onPick(.watchOnlyChainPicker) }
                )
                .listRowBackground(UniColors.List.rowBackground)
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
            .accessibilityLabel(Text("About \(Text(title))"))

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}
