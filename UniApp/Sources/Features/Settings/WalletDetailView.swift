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
    @State private var isShowingBackupFlow: Bool = false
    @State private var isShowingIconPicker: Bool = false
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
            // **Backup state — the screen's lead surface.**
            //
            // Added 2026-06-07 per direct user direction (replaces the
            // wallet-home `BackupRequiredBanner` — see
            // `WalletHomeView.banners` for the deletion rationale).
            // The card has two states, both calm and monochrome:
            //
            // - **A (`requiresBackup == true`):** a `UniCard` with a
            //   `lock.shield` hero glyph, a headline that names the
            //   responsibility ("Back up this wallet."), an honest
            //   body line that states the irreversibility plainly, and
            //   a `UniButton(.primary)` that opens the
            //   `BackupExistingWalletFlow` sheet against this specific
            //   wallet's stored mnemonic (T-046 honored).
            //
            // - **B (`requiresBackup == false`):** the same card slot,
            //   with `checkmark.shield.fill`, a one-line "Backed up.",
            //   and a single body line that names the co-existence
            //   honestly ("Aperture is one of two copies."). No CTA —
            //   the absence of work to do IS the moment.
            //
            // The transition between A and B is the screen's most
            // important visual moment. SwiftUI's `@Query` reactivity
            // on `WalletRecord` flips `requiresBackup` the moment
            // `WalletRepository.markBackupComplete(id:)` lands; the
            // `.animation(.smooth, value:)` on the section makes the
            // crossfade feel deliberate. The symbol's
            // `.symbolEffect(.bounce, options: .nonRepeating)` (gated
            // by Reduce Motion via the engine) gives the user the
            // one-beat acknowledgement they earned it.
            //
            // The card is OPAQUE — not glass, not warning-yellow.
            // Content-layer per Rule #2 §B.3 (no glass on long-form
            // content), monochrome per the brand handoff (Rule #2
            // §A.5).
            Section {
                BackupStateCard(
                    requiresBackup: wallet.requiresBackup,
                    onBackUpNow: { isShowingBackupFlow = true }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: 0,
                    bottom: 0,
                    trailing: 0
                ))
                .listRowSeparator(.hidden)
                .animation(.smooth(duration: 0.4), value: wallet.requiresBackup)
            }

            // 2026-06-09 — wallet-identity section. A `.preview`-sized
            // `WalletAvatar` centered above a single "Customise..."
            // row that pushes the icon picker sheet. The hero
            // preview here matches the sheet's hero preview so the
            // user reads the same affordance whether they enter
            // from the long-press tab menu or from this detail
            // screen. The avatar updates live via `@Query` when
            // the picker writes through `WalletRepository`.
            Section {
                VStack(spacing: UniSpacing.s) {
                    WalletAvatar(
                        symbol: wallet.iconSymbol.isEmpty ? WalletAvatarDefaults.symbol : wallet.iconSymbol,
                        colorHex: wallet.iconColorHex.isEmpty ? WalletAvatarDefaults.colorHex : wallet.iconColorHex,
                        size: .preview
                    )
                    .padding(.top, UniSpacing.xs)

                    UniButton(
                        title: "Customise…",
                        variant: .tertiary
                    ) {
                        isShowingIconPicker = true
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UniSpacing.xs)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text("Identity").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            }

            Section {
                renameRow(wallet)
            } header: {
                Text("Name").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            }

            // Details lost the explicit "Backup · Pending/Complete" row
            // when the lead card took on that role. Reading the same
            // status in two places (top card + middle row) would have
            // read as redundant chrome — the top card carries enough
            // weight on its own.
            Section {
                kindRow(wallet)
                addressesRow(wallet)
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
        .sheet(isPresented: $isShowingBackupFlow) {
            // The `BackupExistingWalletFlow` reads the stored mnemonic
            // via `MnemonicVault.loadMnemonic`, presents the canonical
            // `BackupVerifyView` against it, and on success calls
            // `WalletRepository.markBackupComplete(id:)`. That flip
            // propagates through `@Query` reactivity to this view; the
            // backup card animates A → B in front of the user, the
            // sheet dismisses, and the moment is felt.
            BackupExistingWalletFlow(
                walletId: wallet.id,
                onCompleted: {}
            )
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
        .sheet(isPresented: $isShowingIconPicker) {
            WalletIconPickerSheet(walletId: wallet.id)
                .uniAppEnvironment()
                .presentationDetents([.large])
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

    // `backupStatusRow` removed 2026-06-07. Its meaning is now carried
    // by `BackupStateCard` at the top of the screen.
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

// MARK: - Backup state card (two-state lead surface)

/// Two-state backup card on `WalletDetailView`. The single component
/// handles both the "needs backup" and "backed up" states so the
/// transition between them happens in-place — the user sees the card
/// they were looking at change shape, not a card vanish and another
/// one appear. That continuity is the load-bearing moment.
///
/// **State A (`requiresBackup == true`).** Monochrome `lock.shield`
/// hero glyph (the brand mark color, not a status color — the user
/// is being asked to take responsibility, not warned of danger),
/// headline that names the work plainly ("Back up this wallet."), body
/// that names the consequence honestly without alarm, and a single
/// `UniButton(.primary)` "Back up now" that opens the verify flow
/// against this specific wallet's stored mnemonic.
///
/// **State B (`requiresBackup == false`).** Same card slot. The hero
/// glyph swaps to `checkmark.shield.fill` and gains a one-beat bounce
/// (Reduce Motion → no bounce). Headline: "Backed up." Body names
/// the post-backup co-existence ("You have the phrase. Aperture is
/// one of two copies."). No CTA — the absence of work to do IS the
/// confirmation.
///
/// **Visual register (Rule #2 §A.5 + Rule #16 §B).** Lean monochrome
/// for both states — the headline + body sit in `Text.primary` /
/// `Text.secondary` on `UniCard`'s default `Material.card` fill. No
/// alarming yellow background (the old wallet-home banner), no
/// celebratory green (would read as marketing). The shield glyph
/// itself takes `UniColors.Brand.mark` so both states feel like the
/// brand carrying the same care, just with different posture.
///
/// **iOS 26 concentric corners (Rule #2 §B.4).** The card is a
/// `UniCard` (radius `UniRadius.card`, container shape declared by
/// the primitive). Inside, the hero glyph + headline + body sit in a
/// plain `VStack` — no inner container, so no concentric math is
/// needed.
private struct BackupStateCard: View {
    let requiresBackup: Bool
    let onBackUpNow: () -> Void

    /// Drives `.symbolEffect(.bounce, options: .nonRepeating)` on the
    /// State-B checkmark. Bumped in `onChange` when the requiresBackup
    /// flag flips from true → false, so the user sees the bounce
    /// exactly at the moment of earning the Done state — not on every
    /// view rebuild and not on cold appears of an already-backed-up
    /// wallet.
    @State private var doneBounceTrigger: Int = 0

    var body: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                if requiresBackup {
                    needsBackupContent
                } else {
                    backedUpContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Animation is keyed on the requiresBackup flag so SwiftUI
            // crossfades the two content variants when SwiftData's
            // `@Query` reactivity flips the value. Smooth (not spring)
            // so the moment lands as quiet confirmation rather than
            // celebration. Reduce Motion is honored automatically —
            // SwiftUI shortens / suppresses the animation under that
            // accessibility preference.
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .onChange(of: requiresBackup) { _, newValue in
            if !newValue { doneBounceTrigger &+= 1 }
        }
    }

    // MARK: - State A content (needs backup)

    @ViewBuilder
    private var needsBackupContent: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(UniColors.Brand.mark)
                .frame(width: 32, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniHeadline(text: "Back up this wallet.")
                UniBody(
                    text: "Right now, this wallet only exists on this iPhone. If you lose access before you write down the recovery phrase, the funds in it can't be recovered.",
                    color: UniColors.Text.secondary
                )
            }
        }

        UniButton(title: "Back up now", variant: .primary) {
            onBackUpNow()
        }
    }

    // MARK: - State B content (backed up)

    @ViewBuilder
    private var backedUpContent: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(UniColors.Brand.mark)
                .frame(width: 32, alignment: .leading)
                // One-beat bounce on the A → B transition. Trigger
                // counter only ticks when the requiresBackup flag
                // flips from true to false (see `onChange` on the
                // card), so cold appears of an already-backed-up
                // wallet don't get the bounce — it's reserved for the
                // moment of earning.
                .symbolEffect(.bounce, options: .nonRepeating, value: doneBounceTrigger)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniHeadline(text: "Backed up.")
                UniBody(
                    text: "You have the recovery phrase. Aperture is one of two copies.",
                    color: UniColors.Text.secondary
                )
            }
        }
    }
}
