import SwiftUI
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// **Restore from iCloud** — the read side of the encrypted-backup feature
/// (2026-06-19 backup handoff). Lists the user's CloudKit wallet backups,
/// takes the backup password, decrypts the phrase **on device**, and brings
/// it in through the exact same mnemonic-import path a typed phrase uses
/// (derive every chain's address → `ImportWalletState.persist(.mnemonic)`),
/// so a restored wallet is indistinguishable from a freshly imported one.
///
/// Reached from the Import Wallet chooser (and therefore from Onboarding +
/// every add-wallet entry point). On success it hands control back to the
/// parent flow, which dismisses to the main wallet shell.
struct ICloudRestoreView: View {
    let state: ImportWalletState
    /// Called with the new wallet id after a successful import; the parent
    /// dismisses to the main wallet shell.
    let onImported: (UUID) -> Void
    let onDuplicate: (ExistingWalletImportMatch) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.editMode) private var editMode

    @State private var listState: ListState = .loading
    @State private var selectedBackupId: UUID?
    @State private var selectedBackupIds = Set<UUID>()
    @State private var pendingDeleteIds = Set<UUID>()
    @State private var isDeletingBackups = false
    @State private var deleteErrorMessage: String?
    @State private var password = ""
    /// BIP-39 passphrase (not the backup password). Required when the blob
    /// was flagged `hasPassphrase` (P0-003).
    @State private var bip39Passphrase = ""
    /// Legacy backups without the flag: optional advanced field.
    @State private var showOptionalPassphrase = false
    @State private var isWorking = false
    @State private var passwordError = false
    @State private var passphraseError: String?

    private let store = CloudKitBackupStore()
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "icloud-restore")

    enum ListState: Equatable {
        case loading
        case loaded([WalletBackupBlob])
        /// Signed in to iCloud, but this account has no wallet backups.
        case empty
        /// No iCloud account / iCloud unavailable — distinct from a failure
        /// so we can guide the user to sign in rather than show a generic
        /// error (2026-06-20 user direction).
        case needsICloud
        case failed(String)
    }

    var body: some View {
        listScreen
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Restore from iCloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { restoreToolbar }
        .navigationDestination(item: $selectedBackupId) { backupId in
            if let blob = backup(withId: backupId) {
                passwordScreen(for: blob)
                    .navigationTitle("Enter password")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                restoreState(
                    icon: "icloud.slash",
                    title: "Backup unavailable",
                    detail: "This iCloud backup is no longer available. Go back and refresh the list."
                )
                .navigationTitle("Enter password")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await loadIfNeeded() }
        .onChange(of: isEditingBackups) { _, isEditing in
            if !isEditing { selectedBackupIds.removeAll() }
        }
        .alert(deleteConfirmationTitle, isPresented: deleteConfirmationBinding) {
            Button("Cancel", role: .cancel) { pendingDeleteIds.removeAll() }
            Button("Delete", role: .destructive) {
                let ids = pendingDeleteIds
                pendingDeleteIds.removeAll()
                Task { await deleteBackups(ids) }
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert("Couldn't delete backup", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    // MARK: - List

    @ViewBuilder
    private var listScreen: some View {
        switch listState {
        case .loading:
            UniLoadingState(caption: "Looking for backups in iCloud…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsICloud:
            // No Apple ID signed in / iCloud unavailable. CloudKit needs the
            // iCloud account (it does NOT need iCloud Drive specifically), so
            // guide the user to sign in rather than show a generic failure.
            restoreState(
                icon: "icloud.slash",
                title: "Sign in to iCloud",
                detail: "To restore a wallet from iCloud, sign in to iCloud on this iPhone. Open Settings, tap your name at the top, and turn on iCloud.",
                actionTitle: "Open Settings",
                action: { openSettings() }
            )
        case .empty:
            // A REAL empty state — calm and clearly NOT an error: an accent
            // (not error-grey) tray icon, a friendly title, no "Try again"
            // (there's nothing to retry). 2026-06-20 user direction.
            restoreState(
                icon: "tray",
                iconTint: UniColors.Icon.accent,
                discTint: UniColors.Icon.accent.opacity(0.12),
                title: "No backups yet",
                detail: "When you back a wallet up to iCloud, it shows up here to restore. You can create one from a wallet's recovery-phrase screen → Back up.",
                usesDashedEmptyMark: true
            )
        case .failed(let message):
            restoreState(
                icon: "icloud.slash",
                title: "Couldn't reach iCloud",
                detail: LocalizedStringKey(message),
                actionTitle: "Try again",
                action: { Task { listState = .loading; await load() } }
            )
        case .loaded(let backups):
            List(selection: $selectedBackupIds) {
                Section {
                    ForEach(backups) { blob in
                        if isEditingBackups {
                            backupRow(blob, showsChevron: false)
                                .tag(blob.id)
                                .uniListRowSurface()
                        } else {
                            Button {
                                UniHapticEngine.shared.play(.selection)
                                password = ""
                                bip39Passphrase = ""
                                showOptionalPassphrase = false
                                passwordError = false
                                passphraseError = nil
                                selectedBackupId = blob.id
                            } label: {
                                backupRow(blob, showsChevron: true)
                            }
                            .buttonStyle(.uniListRow)
                            .tag(blob.id)
                            .uniListRowSurface()
                        }
                    }
                    .onDelete { offsets in
                        confirmDeleteBackups(Set(offsets.map { backups[$0].id }))
                    }
                } header: {
                    // M-009: passphrase wallets need the BIP-39 passphrase too.
                    Text("Choose a backup. You need its backup password. If the row says “passphrase”, you also need the BIP-39 passphrase (25th word) — without it restore derives different empty addresses, not your wallet.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .textCase(nil)
                }
            }
            .uniListPageChrome()
        }
    }

    @ToolbarContentBuilder
    private var restoreToolbar: some ToolbarContent {
        if hasLoadedBackups {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
                    .disabled(isDeletingBackups)
            }
        }
        if hasLoadedBackups, isEditingBackups {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selectAllTitle) { toggleSelectAllBackups() }
                    .disabled(isDeletingBackups)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button(role: .destructive) { confirmDeleteSelectedBackups() } label: {
                    if isDeletingBackups {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(deleteSelectionTitle)
                    }
                }
                .disabled(selectedBackupIds.isEmpty || isDeletingBackups)

                Spacer()

                Text(selectionSummaryTitle)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
        }
    }

    /// Modern, full-bleed state surface for the error + empty cases — sits on
    /// the app background with NO white card (2026-06-20 user direction): a
    /// soft tinted icon disc, a bold title, a calm detail line, and an optional
    /// action pinned to the bottom. Replaces the `UniEmptyState` card, whose
    /// `Material.card` fill read as a white block on this full-screen surface.
    @ViewBuilder
    private func restoreState(
        icon: String,
        iconTint: Color = UniColors.Icon.secondary,
        discTint: Color = UniColors.Background.secondary,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil,
        usesDashedEmptyMark: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: UniSpacing.l) {
                ZStack {
                    Circle()
                        .fill(discTint)
                        .frame(width: 96, height: 96)
                    if usesDashedEmptyMark {
                        Image("MarkEmptyDashed")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .foregroundStyle(iconTint)
                            .frame(width: 58, height: 58)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 40, weight: .light))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(iconTint)
                    }
                }
                .accessibilityHidden(true)
                VStack(spacing: UniSpacing.s) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(UniColors.Text.primary)
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, UniSpacing.xl)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                UniButton(title: actionTitle, variant: .secondary) { action() }
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.bottom, UniSpacing.l)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func backupRow(_ blob: WalletBackupBlob, showsChevron: Bool) -> some View {
        HStack(spacing: UniSpacing.s) {
            // The wallet's own identity disc (the user's chosen color / logo),
            // not a generic cloud+lock (2026-06-20 user direction). Backups
            // made before the avatar was stored derive a colored disc from the
            // name so it's still a logo, never a cloud.
            WalletAvatar(
                spec: blob.avatar ?? .auto(name: blob.walletName),
                size: .row,
                walletId: blob.walletId
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: blob.walletName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: backupSubtitle(blob))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: UniDirectionalSymbol.disclosure)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniListRowHitTarget()
    }

    private func backup(withId id: UUID) -> WalletBackupBlob? {
        guard case .loaded(let backups) = listState else { return nil }
        return backups.first { $0.id == id }
    }

    private func backupSubtitle(_ blob: WalletBackupBlob) -> String {
        let date = blob.createdAt.formatted(date: .abbreviated, time: .omitted)
        if blob.hasPassphrase {
            return "\(blob.wordCount) words · passphrase · \(date)"
        }
        return "\(blob.wordCount) words · \(date)"
    }

    private var loadedBackups: [WalletBackupBlob] {
        guard case .loaded(let backups) = listState else { return [] }
        return backups
    }

    private var hasLoadedBackups: Bool { !loadedBackups.isEmpty }

    private var isEditingBackups: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    private var selectAllTitle: String {
        selectedBackupIds.count == loadedBackups.count ? String.apertureLocalized("Deselect All") : String.apertureLocalized("Select All")
    }

    private var deleteSelectionTitle: String {
        selectedBackupIds.count <= 1
            ? String.apertureLocalized("Delete")
            : String(format: String.apertureLocalized("Delete %d"), selectedBackupIds.count)
    }

    private var selectionSummaryTitle: String {
        selectedBackupIds.count == 1
            ? String.apertureLocalized("1 Selected")
            : String(format: String.apertureLocalized("%d Selected"), selectedBackupIds.count)
    }

    private var deleteConfirmationTitle: String {
        pendingDeleteIds.count <= 1
            ? String.apertureLocalized("Delete iCloud backup?")
            : String(format: String.apertureLocalized("Delete %d iCloud backups?"), pendingDeleteIds.count)
    }

    private var deleteConfirmationMessage: String {
        pendingDeleteIds.count <= 1
            ? String.apertureLocalized("This permanently removes the encrypted backup from iCloud and this device. You won't be able to restore it later.")
            : String.apertureLocalized("This permanently removes the selected encrypted backups from iCloud and this device. You won't be able to restore them later.")
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeleteIds.isEmpty },
            set: { isPresented in
                if !isPresented { pendingDeleteIds.removeAll() }
            }
        )
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteErrorMessage != nil },
            set: { isPresented in
                if !isPresented { deleteErrorMessage = nil }
            }
        )
    }

    private func toggleSelectAllBackups() {
        let ids = Set(loadedBackups.map(\.id))
        selectedBackupIds = selectedBackupIds.count == ids.count ? [] : ids
        UniHapticEngine.shared.play(selectedBackupIds.isEmpty ? .selectionDeselect : .selection)
    }

    private func confirmDeleteSelectedBackups() {
        confirmDeleteBackups(selectedBackupIds)
    }

    private func confirmDeleteBackups(_ ids: Set<UUID>) {
        guard !ids.isEmpty, !isDeletingBackups else { return }
        pendingDeleteIds = ids
    }

    private func deleteBackups(_ ids: Set<UUID>) async {
        guard !ids.isEmpty, !isDeletingBackups else { return }
        isDeletingBackups = true
        defer { isDeletingBackups = false }

        do {
            for id in ids {
                try await store.delete(walletId: id)
            }
            selectedBackupIds.subtract(ids)
            if selectedBackupIds.isEmpty {
                editMode?.wrappedValue = .inactive
            }
            applyDeletedBackups(ids)
            UniHapticEngine.shared.play(.contextualImpact(.weighted))
        } catch {
            deleteErrorMessage = Self.message(for: error)
            UniHapticEngine.shared.play(.warning)
            await load()
        }
    }

    private func applyDeletedBackups(_ ids: Set<UUID>) {
        guard case .loaded(let backups) = listState else { return }
        let remaining = backups.filter { !ids.contains($0.id) }
        listState = remaining.isEmpty ? .empty : .loaded(remaining)
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

                    UniTextField(
                        placeholder: "Backup password",
                        text: $password,
                        directionPolicy: .forceLTR,
                        isSecure: true,
                        showsRevealToggle: true,
                        contentType: .password
                    )
                    .onChange(of: password) { _, _ in passwordError = false }

                    if passwordError {
                        Text("Incorrect password. Try again.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Feedback.Error.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // P0-003: BIP-39 passphrase is separate from the backup password.
                    if blob.requiresBIP39Passphrase {
                        passphraseRequiredSection
                    } else {
                        passphraseOptionalSection
                    }

                    if let passphraseError {
                        Text(verbatim: passphraseError)
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Feedback.Error.foreground)
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
                isEnabled: canSubmitRestore(for: blob) && !isWorking
            ) {
                Task { await restore(blob) }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.m)
        }
        .onAppear {
            // Reset passphrase UI when opening a different backup.
            bip39Passphrase = ""
            showOptionalPassphrase = false
            passphraseError = nil
            passwordError = false
        }
    }

    private var passphraseRequiredSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text("BIP-39 passphrase required")
                .font(UniTypography.subheadlineEmphasized)
                .foregroundStyle(UniColors.Text.primary)
            Text("This wallet was created with a BIP-39 passphrase (sometimes called a 25th word). It is not your backup password. Leaving it blank restores a different empty wallet.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            UniTextField(
                placeholder: "BIP-39 passphrase",
                text: $bip39Passphrase,
                directionPolicy: .forceLTR,
                isSecure: true,
                showsRevealToggle: true,
                contentType: .password
            )
            .onChange(of: bip39Passphrase) { _, _ in passphraseError = nil }
        }
        .padding(UniSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UniColors.Card.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var passphraseOptionalSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showOptionalPassphrase.toggle()
                    if !showOptionalPassphrase {
                        bip39Passphrase = ""
                        passphraseError = nil
                    }
                }
            } label: {
                HStack {
                    Text("I used a BIP-39 passphrase")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                    Spacer()
                    Image(systemName: showOptionalPassphrase ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
            .buttonStyle(.uniTactile)

            if showOptionalPassphrase {
                Text("Only for wallets created with an extra passphrase. Most users leave this blank. A wrong passphrase restores the wrong (empty) addresses.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                UniTextField(
                    placeholder: "BIP-39 passphrase (optional)",
                    text: $bip39Passphrase,
                    directionPolicy: .forceLTR,
                    isSecure: true,
                    showsRevealToggle: true,
                    contentType: .password
                )
            }
        }
    }

    private func canSubmitRestore(for blob: WalletBackupBlob) -> Bool {
        guard !password.isEmpty else { return false }
        if blob.requiresBIP39Passphrase {
            return !bip39Passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    // MARK: - Load + restore

    private func loadIfNeeded() async {
        if case .loading = listState { await load() }
    }

    private func load() async {
        // Account first: no Apple ID / iCloud unavailable gets its own calm
        // "Sign in to iCloud" state, not a generic failure (2026-06-20).
        do {
            try await store.ensureAccountAvailable()
        } catch CloudKitBackupStore.StoreError.notSignedIn,
                CloudKitBackupStore.StoreError.iCloudUnavailable {
            listState = .needsICloud
            return
        } catch {
            listState = .failed(Self.message(for: error))
            return
        }
        do {
            let backups = try await store.list()
            listState = backups.isEmpty ? .empty : .loaded(backups)
        } catch {
            listState = .failed(Self.message(for: error))
        }
    }

    /// Open the iOS Settings app (the closest public affordance — it lands on
    /// Aperture's settings page, from which the user can reach iCloud).
    private func openSettings() {
#if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
#endif
    }

    private func restore(_ blob: WalletBackupBlob) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        passphraseError = nil
        passwordError = false

        // P0-003: never silently derive with "" when the backup requires a
        // BIP-39 passphrase — that would create a different empty wallet.
        let resolvedPassphrase: String
        do {
            resolvedPassphrase = try WalletBackupBlob.resolvedPassphrase(
                hasPassphrase: blob.hasPassphrase,
                passphrase: bip39Passphrase
            )
        } catch let error as RestorePassphraseError {
            passphraseError = error.userMessage
            UniHapticEngine.shared.play(.warning)
            return
        } catch {
            passphraseError = String.apertureLocalized("Enter your BIP-39 passphrase to restore this wallet.")
            UniHapticEngine.shared.play(.warning)
            return
        }

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

        // Bring it in through the canonical mnemonic-import path with the
        // correct BIP-39 passphrase (empty only when the wallet never used one).
        state.mnemonicWordCount = words.count == 24 ? .twentyFour : .twelve
        state.mnemonicWords = words
        state.mnemonicPassphrase = resolvedPassphrase
        state.derivedAddressesFromMnemonic = await state.service.deriveAddresses(
            mnemonic: words, passphrase: resolvedPassphrase
        )

        guard !state.derivedAddressesFromMnemonic.isEmpty else {
            passphraseError = String.apertureLocalized("Couldn't derive addresses for this phrase. Check the passphrase and try again.")
            UniHapticEngine.shared.play(.warning)
            return
        }

        let repo = WalletCommandRepository()
        do {
            let walletId = try await state.persist(
                result: .mnemonic, into: repo, defaultName: blob.walletName
            )
            // Restore the wallet's saved look (color / logo) so it comes back
            // exactly as the user had it. Best-effort — a default disc is fine
            // if this fails, and older backups simply have no avatar to apply.
            if let avatar = blob.avatar {
                _ = try? await repo.updateAvatar(id: walletId, spec: avatar)
            }
            state.zeroSensitiveInput()
            bip39Passphrase = ""
            UniHapticEngine.shared.play(.contextualImpact(.consequential))
            onImported(walletId)
        } catch WalletCommandRepositoryError.alreadyImported(let match) {
            passwordError = false
            onDuplicate(match)
        } catch {
            Self.log.error("iCloud restore persist failed: \(String(describing: error), privacy: .public)")
            passwordError = false
            listState = .failed(String.apertureLocalized("Couldn't save the restored wallet to this iPhone. Try again."))
            selectedBackupId = nil
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
                // CloudKit 12 (invalidArguments) "Field 'recordName' is not
                // marked queryable" — the legacy list QUERY couldn't run. This
                // means a backup MIGHT exist but couldn't be enumerated the old
                // way; it must NOT be shown as "no backups" (that would falsely
                // claim the user's backup is gone). Restore now reads a
                // query-free index instead, which self-heals when the wallet's
                // own device opens the app — so point the user there, not at
                // the CloudKit Console. (The raw server string is logged for
                // devs in `CloudKitBackupStore.map`.)
                if code == 12 || message.localizedCaseInsensitiveContains("queryable") {
                    return String.apertureLocalized("We couldn't list your iCloud backups just yet. If you've backed one up, open Aperture on the iPhone that holds that wallet so it finishes syncing to iCloud, then come back and try again.")
                }
                return String(format: String.apertureLocalized("Couldn't reach iCloud (CloudKit %lld): %@"), Int64(code), message)
            case .unknown(let message):
                return String(format: String.apertureLocalized("Couldn't reach iCloud: %@"), message)
            }
        }
        return String(format: String.apertureLocalized("Something went wrong: %@"), error.localizedDescription)
    }
}
