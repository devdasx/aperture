import SwiftUI
import SwiftData

/// Settings → Wallets → <wallet>. Single-wallet management surface:
/// rename, view recovery phrase (honest about post-backup
/// availability), inspect addresses, delete.
///
/// **Backup-status honesty (Rule #16 + Rule #2 §A.7):**
/// - If `MnemonicVault.hasMnemonic(for:)` returns true (the user
///   skipped backup at create time, mnemonic is encrypted locally) →
///   "View recovery phrase" is enabled and opens the
///   `RecoveryPhraseRevealSheet`.
/// - If the mnemonic is gone (backed-up wallets, imported wallets,
///   non-mnemonic kinds) → "View recovery phrase" is disabled with a
///   footnote: "Aperture no longer has your phrase. You're the only
///   copy." That's honest about BIP-39's one-way derivation.
struct WalletDetailView: View {
    let walletId: UUID

    @Query private var matches: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String = ""
    @State private var isShowingDeleteConfirm: Bool = false
    @State private var isShowingPhrase: Bool = false
    @State private var biometricChallenge: BiometricChallenge?

    init(walletId: UUID) {
        self.walletId = walletId
        _matches = Query(
            filter: #Predicate<WalletRecord> { $0.id == walletId }
        )
    }

    private var wallet: WalletRecord? { matches.first }

    var body: some View {
        Group {
            if let wallet {
                content(wallet)
            } else {
                missing
            }
        }
        .navigationTitle(Text(wallet?.name ?? String.apertureLocalized("Wallet")))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if editedName.isEmpty, let wallet { editedName = wallet.name }
        }
    }

    @ViewBuilder
    private func content(_ wallet: WalletRecord) -> some View {
        List {
            Section {
                renameRow(wallet)
            } header: {
                Text("Name").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            }

            Section {
                kindRow(wallet)
                addressesRow(wallet)
                backupStatusRow(wallet)
            } header: {
                Text("Details").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            }

            Section {
                viewPhraseRow(wallet)
            } footer: {
                Text(phraseFooter(wallet))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                deleteRow(wallet)
            } footer: {
                Text("Deleting this wallet removes it from this iPhone and erases its encrypted seed from Keychain. Your recovery phrase, if you wrote it down, is still yours — you can restore the wallet later by importing it.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .sheet(isPresented: $isShowingDeleteConfirm) {
            DeleteWalletConfirmationSheet(
                walletName: wallet.name,
                onConfirm: {
                    Task { await deleteWallet(wallet) }
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingPhrase) {
            RecoveryPhraseRevealSheet(walletId: wallet.id)
                .uniAppEnvironment()
                .presentationDetents([.large])
                .presentationBackground(UniColors.Background.primary)
        }
        .sheet(item: $biometricChallenge) { challenge in
            BiometricChallengeSheet(
                reason: challenge.reason,
                onSuccess: challenge.onSuccess,
                onFailure: { biometricChallenge = nil }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Rows

    private func renameRow(_ wallet: WalletRecord) -> some View {
        HStack {
            TextField(String.apertureLocalized("Wallet"), text: $editedName)
                .font(UniTypography.body)
                .submitLabel(.done)
                .onSubmit { commitRename(wallet) }
            if editedName != wallet.name && !editedName.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Save") { commitRename(wallet) }
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Tint.accent)
            }
        }
        .listRowBackground(UniColors.Background.secondary)
    }

    private func kindRow(_ wallet: WalletRecord) -> some View {
        HStack {
            Text("Kind").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            Spacer()
            Text(kindLabel(wallet.kind)).font(UniTypography.subheadline).foregroundStyle(UniColors.Text.secondary)
        }
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.Background.secondary)
    }

    private func addressesRow(_ wallet: WalletRecord) -> some View {
        HStack {
            Text("Addresses").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            Spacer()
            Text("\(wallet.addresses.count)").font(UniTypography.subheadline).foregroundStyle(UniColors.Text.secondary).monospacedDigit()
        }
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.Background.secondary)
    }

    private func backupStatusRow(_ wallet: WalletRecord) -> some View {
        HStack {
            Text("Backup").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            Spacer()
            if wallet.requiresBackup {
                Label("Pending", systemImage: "exclamationmark.shield.fill")
                    .labelStyle(.titleAndIcon)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Status.warningForeground)
            } else {
                Label("Complete", systemImage: "checkmark.shield.fill")
                    .labelStyle(.titleAndIcon)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Status.successForeground)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.Background.secondary)
    }

    private func viewPhraseRow(_ wallet: WalletRecord) -> some View {
        let hasMnemonic = MnemonicVault.hasMnemonic(for: wallet.id)
        return Button {
            guard hasMnemonic else { return }
            // Gate the reveal behind a biometric prompt when biometric
            // is enabled — keeps the phrase from being trivially
            // viewable by anyone with the unlocked phone (Rule #16).
            if UserDefaults.standard.bool(forKey: "biometricEnabled") {
                biometricChallenge = BiometricChallenge(
                    reason: LocalizedStringResource("Confirm to view your recovery phrase."),
                    onSuccess: {
                        biometricChallenge = nil
                        isShowingPhrase = true
                    }
                )
            } else {
                isShowingPhrase = true
            }
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(hasMnemonic ? UniColors.Icon.accent : UniColors.Icon.tertiary)
                    .frame(width: 28)
                Text("View recovery phrase")
                    .font(UniTypography.body)
                    .foregroundStyle(hasMnemonic ? UniColors.Text.primary : UniColors.Text.tertiary)
                Spacer()
                if hasMnemonic {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .buttonStyle(.plain)
        .disabled(!hasMnemonic)
        .listRowBackground(UniColors.Background.secondary)
    }

    private func deleteRow(_ wallet: WalletRecord) -> some View {
        Button {
            isShowingDeleteConfirm = true
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(UniColors.Status.errorForeground)
                    .frame(width: 28)
                Text("Delete wallet")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Status.errorForeground)
                Spacer()
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .buttonStyle(.plain)
        .listRowBackground(UniColors.Background.secondary)
    }

    private var missing: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
            UniBody(
                text: "This wallet is no longer in the local store.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
        .frame(maxWidth: .infinity)
        .padding(UniSpacing.xl)
    }

    // MARK: - Helpers

    private func kindLabel(_ kind: WalletKind) -> LocalizedStringKey {
        switch kind {
        case .created:          return "Created"
        case .importedMnemonic: return "Imported (phrase)"
        case .importedKey:      return "Imported (key)"
        case .watchOnly:        return "Watch-only"
        }
    }

    private func phraseFooter(_ wallet: WalletRecord) -> LocalizedStringKey {
        if MnemonicVault.hasMnemonic(for: wallet.id) {
            return "Your recovery phrase is stored encrypted on this iPhone (AES-GCM 256-bit, Keychain). Tap “View recovery phrase” anytime — the phrase never leaves this device."
        }
        switch wallet.kind {
        case .created, .importedMnemonic:
            return "Aperture no longer has your phrase. You're the only copy — write it down and keep it safe."
        case .importedKey:
            return "This wallet was imported from a private key. There is no recovery phrase to show."
        case .watchOnly:
            return "Watch-only wallets have no recovery phrase — they hold no key."
        }
    }

    private func commitRename(_ wallet: WalletRecord) {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != wallet.name else { return }
        let id = wallet.id
        let newName = trimmed
        Task { @MainActor in
            let repo = WalletRepository(modelContainer: modelContext.container)
            try? await repo.renameWallet(id: id, to: newName)
        }
    }

    private func deleteWallet(_ wallet: WalletRecord) async {
        let id = wallet.id
        let repo = WalletRepository(modelContainer: modelContext.container)
        try? await repo.deleteWallet(id: id)
        try? SeedVault.deleteSeed(for: id)
        try? MnemonicVault.deleteMnemonic(for: id)
        // If this was the active wallet, clear the pointer; the
        // wallet-home will pick a new active on next appear.
        if activeWalletIdRaw == id.uuidString { activeWalletIdRaw = "" }
        dismiss()
    }
}

// MARK: - Biometric challenge shim

/// Identifiable shim so `.sheet(item:)` can present a biometric
/// challenge inline without us threading a separate state per use
/// site.
private struct BiometricChallenge: Identifiable {
    let id = UUID()
    let reason: LocalizedStringResource
    let onSuccess: () -> Void
}

private struct BiometricChallengeSheet: View {
    let reason: LocalizedStringResource
    let onSuccess: () -> Void
    let onFailure: () -> Void

    var body: some View {
        UniSheet(title: "Authenticate") {
            VStack(spacing: UniSpacing.m) {
                Image(systemName: "faceid")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Status.infoForeground)
                    .accessibilityHidden(true)
                UniBody(text: "Confirm with Face ID to continue.", alignment: .center, color: UniColors.Text.secondary)
            }
        } actions: {
            UniButton(title: "Confirm", variant: .primary) {
                Task {
                    let outcome = await BiometricService().authenticate(reason: reason)
                    if case .success = outcome { onSuccess() } else { onFailure() }
                }
            }
        }
        .task {
            // Auto-present the system prompt on appear for one-tap UX.
            let outcome = await BiometricService().authenticate(reason: reason)
            if case .success = outcome { onSuccess() } else { onFailure() }
        }
    }
}

// MARK: - Delete confirmation

struct DeleteWalletConfirmationSheet: View {
    let walletName: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typedConfirmation: String = ""

    private var matchesName: Bool {
        typedConfirmation.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(walletName) == .orderedSame
    }

    var body: some View {
        UniSheet(title: "Delete this wallet?") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Status.errorForeground)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)

                UniBody(
                    text: "This deletes \(walletName) from this iPhone, including its encrypted seed and any cached balances and transactions.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)

                UniBody(
                    text: "If you have your recovery phrase written down, you can restore this wallet later by importing it. If you don't, the funds are gone.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: UniSpacing.xs) {
                    Text("Type the wallet's name to confirm:")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                    UniTextField(
                        placeholder: LocalizedStringKey(walletName),
                        text: $typedConfirmation,
                        directionPolicy: .automatic
                    )
                }
            }
        } actions: {
            VStack(spacing: UniSpacing.s) {
                UniButton(
                    title: "Delete wallet",
                    variant: .destructive,
                    isEnabled: matchesName
                ) {
                    onConfirm()
                    dismiss()
                }
                UniButton(title: "Cancel", variant: .secondary) { dismiss() }
            }
        }
    }
}
