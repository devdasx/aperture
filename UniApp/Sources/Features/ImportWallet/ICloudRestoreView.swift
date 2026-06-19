import SwiftUI
import OSLog

/// **Restore from iCloud** — the read side of the encrypted-backup feature
/// (2026-06-19 backup handoff). Lists the user's CloudKit wallet backups,
/// takes the backup password, decrypts the phrase **on device**, and brings
/// it in through the exact same mnemonic-import path a typed phrase uses
/// (derive every chain's address → `ImportWalletState.persist(.mnemonic)`),
/// so a restored wallet is indistinguishable from a freshly imported one.
///
/// Reached from the Import Wallet chooser (and therefore from Onboarding +
/// every add-wallet entry point). On success it pushes the shared
/// `ImportSuccessView` via the parent's navigation.
struct ICloudRestoreView: View {
    let state: ImportWalletState
    /// Called with the new wallet id after a successful import; the parent
    /// routes to the success screen.
    let onImported: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var listState: ListState = .loading
    @State private var selected: WalletBackupBlob?
    @State private var password = ""
    @State private var showPassword = false
    @State private var isWorking = false
    @State private var passwordError = false

    private let store = CloudKitBackupStore()
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "icloud-restore")

    enum ListState: Equatable {
        case loading
        case loaded([WalletBackupBlob])
        case empty
        case failed(String)
    }

    var body: some View {
        Group {
            if let selected {
                passwordScreen(for: selected)
            } else {
                listScreen
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle(selected == nil ? Text("Restore from iCloud") : Text("Enter password"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadIfNeeded() }
    }

    // MARK: - List

    @ViewBuilder
    private var listScreen: some View {
        switch listState {
        case .loading:
            UniLoadingState(caption: "Looking for backups in iCloud…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: UniSpacing.l) {
                UniEmptyState(
                    title: "Couldn't reach iCloud",
                    detail: LocalizedStringKey(message),
                    mark: .icon(systemName: "icloud.slash")
                )
                UniButton(title: "Try again", variant: .secondary) {
                    Task { listState = .loading; await load() }
                }
                .padding(.horizontal, UniSpacing.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            UniEmptyState(
                title: "No iCloud backups",
                detail: "You don't have any wallet backups in this iCloud account yet. Create one from a wallet's recovery-phrase screen → Backup Now.",
                mark: .icon(systemName: "icloud")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, UniSpacing.l)
        case .loaded(let backups):
            List {
                Section {
                    ForEach(backups) { blob in
                        Button {
                            UniHapticEngine.shared.play(.selection)
                            password = ""
                            passwordError = false
                            selected = blob
                        } label: {
                            backupRow(blob)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(UniColors.Background.secondary)
                    }
                } header: {
                    Text("Choose a backup to restore. You'll need its password.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
        }
    }

    private func backupRow(_ blob: WalletBackupBlob) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "lock.icloud")
                .font(.system(size: 20))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: blob.walletName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: "\(blob.wordCount) words · \(blob.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, UniSpacing.xxs)
        .contentShape(Rectangle())
    }

    // MARK: - Password

    private func passwordScreen(for blob: WalletBackupBlob) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 36, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(UniColors.Text.primary)
                        .frame(width: 80, height: 80)
                        .background(Circle().fill(UniColors.Text.primary.opacity(0.08)))
                        .padding(.top, UniSpacing.m)
                        .accessibilityHidden(true)

                    VStack(spacing: UniSpacing.xs) {
                        Text(verbatim: blob.walletName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                        Text("Enter the backup password you set for this wallet to decrypt it.")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: UniSpacing.s) {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                        .onChange(of: password) { _, _ in passwordError = false }

                        Button {
                            UniHapticEngine.shared.play(.selection)
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 16))
                                .foregroundStyle(UniColors.Icon.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(showPassword ? "Hide password" : "Show password"))
                    }
                    .padding(.horizontal, UniSpacing.m)
                    .padding(.vertical, UniSpacing.s + 2)
                    .background(
                        RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                            .fill(UniColors.Background.secondary)
                    )

                    if passwordError {
                        Text("Incorrect password. Try again.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Status.errorForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
            }

            UniButton(
                title: "Restore wallet",
                variant: .primary,
                isLoading: isWorking,
                isEnabled: !password.isEmpty && !isWorking
            ) {
                Task { await restore(blob) }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.m)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { selected = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text("Back"))
                .disabled(isWorking)
            }
        }
    }

    // MARK: - Load + restore

    private func loadIfNeeded() async {
        if case .loading = listState { await load() }
    }

    private func load() async {
        do {
            try await store.ensureAccountAvailable()
            let backups = try await store.list()
            listState = backups.isEmpty ? .empty : .loaded(backups)
        } catch {
            listState = .failed(Self.message(for: error))
        }
    }

    private func restore(_ blob: WalletBackupBlob) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let pw = password
        // Decrypt off-main (PBKDF2 600k). A wrong password throws .openFailed.
        let words: [String]
        do {
            words = try await Task.detached(priority: .userInitiated) {
                try blob.recoverWords(password: pw)
            }.value
        } catch {
            passwordError = true
            UniHapticEngine.shared.play(.warning)
            return
        }

        // Bring it in through the canonical mnemonic-import path.
        state.mnemonicWordCount = words.count == 24 ? .twentyFour : .twelve
        state.mnemonicWords = words
        state.derivedAddressesFromMnemonic = await state.service.deriveAddresses(
            mnemonic: words, passphrase: ""
        )

        let container = modelContext.container
        let repo = WalletRepository(modelContainer: container)
        do {
            let walletId = try await state.persist(
                result: .mnemonic, into: repo, defaultName: blob.walletName
            )
            state.zeroSensitiveInput()
            // Kick the restored wallet's first balance/history refresh so it
            // doesn't read $0 until relaunch (mirrors the typed-import path).
            let fiat = UserDefaults.standard.string(forKey: CurrencyPreference.storageKey)
                ?? CurrencyPreference.defaultCode
            Task {
                await WalletRefreshCoordinator(container: container)
                    .refreshWallet(walletId: walletId, fiatCode: fiat)
            }
            UniHapticEngine.shared.play(.contextualImpact(.consequential))
            onImported(walletId)
        } catch {
            Self.log.error("iCloud restore persist failed: \(String(describing: error), privacy: .public)")
            passwordError = false
            listState = .failed(String.apertureLocalized("Couldn't save the restored wallet to this iPhone. Try again."))
            selected = nil
        }
    }

    private static func message(for error: Error) -> String {
        if let e = error as? CloudKitBackupStore.StoreError {
            switch e {
            case .notSignedIn:
                return String.apertureLocalized("You're not signed in to iCloud. Sign in from Settings, then try again.")
            case .iCloudUnavailable:
                return String.apertureLocalized("iCloud isn't available on this device right now. Try again later.")
            case .networkUnavailable:
                return String.apertureLocalized("No internet connection. Reconnect and try again.")
            case .quotaExceeded:
                return String.apertureLocalized("Your iCloud storage is full.")
            case .notFound:
                return String.apertureLocalized("That backup is no longer in iCloud.")
            case .cloudKit(let code, let message):
                return String(format: String.apertureLocalized("Couldn't reach iCloud (CloudKit %lld): %@"), Int64(code), message)
            case .unknown(let message):
                return String(format: String.apertureLocalized("Couldn't reach iCloud: %@"), message)
            }
        }
        return String(format: String.apertureLocalized("Something went wrong: %@"), error.localizedDescription)
    }
}
