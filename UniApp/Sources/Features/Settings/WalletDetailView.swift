import SwiftUI
import SwiftData

/// Settings → Wallets → <wallet>. Single-wallet management surface:
/// rename, view recovery phrase (honest about post-backup
/// availability), inspect addresses, delete.
///
/// **Secret-reveal honesty (Rule #16 + Rule #2 §A.7), per kind:**
/// - Created / Imported (phrase): "View recovery phrase", enabled iff
///   `MnemonicVault.hasMnemonic(for:)` — the vault stores the phrase
///   at persist time for both kinds. Disabled only for wallets
///   persisted before the always-store policy shipped, with a footer
///   that names the truth for that kind (created → the user is the
///   only copy; imported → the phrase wasn't kept at import time,
///   re-import to store it).
/// - Imported (key): "View private key", enabled iff
///   `MnemonicVault.hasPrivateKey(for:)`, same biometric gate, opens
///   `PrivateKeyRevealSheet`.
/// - Watch-only: no reveal row — the Details footer states that no
///   secret exists on this device.
struct WalletDetailView: View {
    let walletId: UUID

    @Query private var matches: [WalletRecord]
    // `activeWalletId` is no longer read or written here — the repository's
    // `deleteWalletAndActivateNext` owns the post-delete pointer move
    // (2026-06-13). The old `@AppStorage("activeWalletId")` clobber is gone
    // (see `deleteWallet`).
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String = ""
    /// Presents `WalletDeleteSheet`, the wallet-scoped sibling of
    /// `ResetApertureSheet`. The sheet owns its own authorization gate
    /// internally — passcode-only verify when a passcode is set, native
    /// destructive confirmation otherwise (user direction 2026-06-13).
    /// No typed wallet name, no separate passcode-cover state here.
    @State private var isShowingDeleteConfirm: Bool = false
    @State private var isShowingPhrase: Bool = false
    @State private var isShowingKey: Bool = false
    /// Presents `ChainKeysRevealSheet` — the per-chain private-key export.
    @State private var isShowingChainKeys: Bool = false
    @State private var isShowingBackupFlow: Bool = false
    @State private var isShowingIconPicker: Bool = false
    @State private var biometricChallenge: BiometricChallenge?

    // MARK: - Backup status section (2026-06-20)
    /// Presents the full backup flow (iCloud / manual chooser) once the
    /// phrase has been decrypted behind the auth gate.
    @State private var isShowingWalletBackup: Bool = false
    @State private var backupWords: [String] = []
    /// Live iCloud-backup status for this wallet, resolved from CloudKit.
    @State private var iCloudStatus: BackupRowStatus = .checking

    enum BackupRowStatus: Equatable { case checking, done, notDone, unavailable }

    // MARK: - Sensitive-reveal auth gate (2026-06-19)
    //
    // One unified resolution for "view recovery phrase / private key(s)":
    //   1. App passcode set  → the unified `PinCodeView` verify screen,
    //      which auto-prompts Face ID when the in-app Face ID toggle is on
    //      (no longer a raw Face ID prompt when only a passcode is set).
    //   2. Else device biometric enrolled → a direct Face ID/Touch ID
    //      prompt, even when both in-app toggles are off (the device's own
    //      biometric still guards the secret).
    //   3. Else (no app passcode, no device biometric) → a professional
    //      warning sheet, then allow (nothing on the device can gate it).
    private enum SensitiveReveal { case phrase, key, chainKeys, backup }
    @State private var pendingReveal: SensitiveReveal?
    @State private var isShowingPasscodeGate: Bool = false
    @State private var isShowingNoAuthWarning: Bool = false

    /// Already-localized message for the shared error alert. Non-nil
    /// presents the alert; dismissing it clears the value.
    @State private var errorAlertMessage: String?

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
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(
                get: { errorAlertMessage != nil },
                set: { if !$0 { errorAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorAlertMessage ?? ""))
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
            // Shown ONLY for phrase-based wallets — they're the only kind
            // with a "recovery phrase" to back up, so the card's truth
            // ("you have the phrase" / "back it up") actually applies
            // (2026-06-19). A private-key import's backup IS its key (the
            // reveal section covers it), and a watch-only wallet holds no
            // secret — claiming "Backed up. You have the recovery phrase"
            // for either would be false (Rule #16).
            // The top "Backed up." card was removed 2026-06-20 — its
            // status now lives in the dedicated Backup section below
            // (iCloud + manual), so a lead card restating it read as
            // redundant chrome.

            // 2026-06-13 — wallet-identity hero. The `.preview`-sized
            // `WalletAvatar` is the identity hero; beneath it sits a
            // compact Liquid Glass "Customise wallet" chip that opens
            // the icon picker. The hero preview matches the sheet's
            // hero preview so the user reads the same affordance
            // whether they enter from the long-press wallet-pill menu
            // or from this detail screen; the chip's verb + symbol
            // (`paintpalette`) match that menu's "Customise wallet"
            // row so the vocabulary is consistent across both entry
            // points. The avatar updates live via `@Query` when the
            // picker writes through `WalletRepository`.
            //
            // **The chip — `.secondary`, not `.tertiary` (Rule #19).**
            // This control commits to a flow (it opens
            // `WalletIconPickerSheet`), so it goes through `UniButton`
            // with a real material — not a bare inline text link. The
            // earlier `.tertiary` rendered as background-less grey text
            // ("Customise…" truncated), which didn't read as a control.
            // `.secondary` gives the canonical `.buttonStyle(.glass)`
            // surface (translucency + specular + motion via the system
            // API per Rule #2 §B.5), the `.selection` haptic, and the
            // `.contentShape(Capsule())` hit-test contract — all for
            // free. `.fixedSize()` collapses the variant's full-bleed
            // width so it hugs its label as a compact chip rather than
            // spanning the row as a CTA bar; the avatar stays the louder
            // element. Stripped the "Identity" section header (Rule #2
            // §D.5) — the avatar already IS the identity; a label
            // naming it restated the hero.
            // Customize row — a standard inset row like the others
            // (2026-06-19 user direction): the wallet's avatar on the
            // leading edge, "Customize" + chevron trailing, opening
            // `WalletIconPickerSheet`. The avatar updates live via
            // `@Query` the moment the picker writes through the repo.
            Section {
                customizeRow(wallet)
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
            } header: {
                Text("Details").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            } footer: {
                // Watch-only wallets have no reveal section below, so
                // the honest "no secret on this device" statement
                // lives here instead (Rule #16 §A.5).
                if wallet.kind == .watchOnly {
                    Text("This wallet watches an address. There is no recovery phrase or private key on this iPhone — nothing secret is stored.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Backup status — iCloud + manual, for phrase wallets (the only
            // kind with a recovery phrase to back up). Two connected rows so
            // the related statuses read as one group; tapping either (when not
            // yet done) opens the backup flow (2026-06-20 user direction —
            // replaces the old top backup-state card).
            if wallet.kind == .created || wallet.kind == .importedMnemonic {
                Section {
                    backupStatusRow(
                        icon: "icloud",
                        title: "iCloud backup",
                        status: iCloudStatus,
                        onTap: { startWalletBackup() }
                    )
                    backupStatusRow(
                        icon: "square.and.pencil",
                        title: "Manual backup",
                        // Driven by the dedicated manual flag — NOT
                        // requiresBackup, which an iCloud backup also clears
                        // (that's what falsely marked this "Backed up" after an
                        // iCloud-only backup, 2026-06-20). nil (migrated rows)
                        // reads as not-yet-manually-backed-up.
                        status: (wallet.manualBackupCompleted ?? false) ? .done : .notDone,
                        onTap: { startWalletBackup() }
                    )
                } header: {
                    Text("Backup").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
                } footer: {
                    Text("An iCloud backup keeps an encrypted copy of your recovery phrase in your private iCloud, so you can restore on another device. A manual backup means you've written the words down yourself. Doing both is the safest.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Reveal secrets — recovery phrase + per-chain private keys in ONE
            // connected group (2026-06-20 user direction). Watch-only wallets
            // hold no secret, so no section at all.
            if wallet.kind != .watchOnly {
                Section {
                    if wallet.kind == .importedKey {
                        viewKeyRow(wallet)
                    } else {
                        viewPhraseRow(wallet)
                    }
                    viewChainKeysRow(wallet)
                } header: {
                    Text("Recovery & keys").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
                } footer: {
                    Text(secretFooter(wallet))
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Custom tokens — Aperture reads what the contract says
            // about itself, the user adds tokens by pasting contract
            // addresses. Row is always visible (no count gate); the
            // empty state inside `CustomTokensListView` does its own
            // calm "no custom tokens yet" treatment.
            Section {
                customTokensRow
            } header: {
                Text("Tokens").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            } footer: {
                Text("Add ERC-20 / SPL tokens by pasting their contract or mint address. Aperture reads name, symbol, and decimals from chain.")
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
        .task(id: walletId) {
            // Resolve the iCloud-backup status for phrase wallets (the only
            // kind with a recovery phrase to back up).
            guard wallet.kind == .created || wallet.kind == .importedMnemonic else { return }
            await refreshICloudBackupStatus()
        }
        .sheet(isPresented: $isShowingDeleteConfirm) {
            // Wallet-scoped sibling of `ResetApertureSheet` (user
            // direction 2026-06-13: "it should match resetting the
            // whole app flow but for wallet"). No typed wallet name —
            // the sheet owns its own passcode-only verify gate (passcode
            // set) or native destructive `confirmationDialog` (no
            // passcode) internally, exactly like the reset flow. On
            // authorization it calls back into `deleteWallet` here, which
            // delegates to the canonical repository helper.
            WalletDeleteSheet(
                walletName: wallet.name,
                kind: wallet.kind,
                networkCount: Set(wallet.addresses.map(\.chainRaw)).count,
                hasStoredSecret: walletHasStoredSecret(wallet),
                onAuthorized: {
                    isShowingDeleteConfirm = false
                    Task { await deleteWallet(wallet) }
                }
            )
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        // Full-screen export flows (2026-06-19 handoff) — replaced the
        // bottom-sheet reveals. Auth already ran via `requestReveal`
        // before these present.
        .fullScreenCover(isPresented: $isShowingPhrase) {
            ExportRecoveryPhraseFlow(
                walletId: wallet.id,
                walletName: wallet.name,
                onClose: { isShowingPhrase = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingKey) {
            // An imported single-key wallet routes to the same per-chain
            // export flow — its picker lists the chains the key covers
            // (one for a single-chain key, all EVM chains for an EVM key).
            ExportPrivateKeyFlow(
                descriptor: WalletDescriptor(record: wallet),
                chains: chainEntries(wallet),
                onClose: { isShowingKey = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingChainKeys) {
            ExportPrivateKeyFlow(
                descriptor: WalletDescriptor(record: wallet),
                chains: chainEntries(wallet),
                onClose: { isShowingChainKeys = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingWalletBackup) {
            // The full backup chooser (iCloud / manual), against the phrase
            // decrypted behind the auth gate. On close, re-check iCloud status.
            WalletBackupFlow(
                walletId: wallet.id,
                walletName: wallet.name,
                words: backupWords,
                onClose: {
                    isShowingWalletBackup = false
                    backupWords = []
                    Task { await refreshICloudBackupStatus() }
                }
            )
            .uniAppEnvironment()
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
            .uniSheetDetents([.large])
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
        // App passcode set → the unified passcode verify screen. It
        // auto-prompts Face ID when the in-app Face ID toggle is on
        // (`allowsBiometrics: true`), so a passcode-only user is NOT shown
        // a raw Face ID prompt — they see the keypad and may use Face ID
        // only if they enabled it (2026-06-19 user direction).
        .fullScreenCover(isPresented: $isShowingPasscodeGate) {
            NavigationStack {
                PinCodeView(
                    mode: .verify,
                    onComplete: { _ in
                        isShowingPasscodeGate = false
                        let target = pendingReveal
                        // Defer one runloop so the cover finishes
                        // dismissing before the reveal sheet presents.
                        DispatchQueue.main.async {
                            if let target { performReveal(target) }
                        }
                    },
                    onCancel: { isShowingPasscodeGate = false },
                    allowsBiometrics: true
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingPasscodeGate = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Cancel"))
                    }
                }
            }
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        // No app passcode AND no device biometric → nothing on the device
        // can gate the secret. Allow, but warn honestly first.
        .sheet(isPresented: $isShowingNoAuthWarning) {
            NoDeviceLockWarningSheet(
                onContinue: {
                    isShowingNoAuthWarning = false
                    let target = pendingReveal
                    DispatchQueue.main.async {
                        if let target { performReveal(target) }
                    }
                },
                onCancel: { isShowingNoAuthWarning = false }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingIconPicker) {
            WalletIconPickerSheet(walletId: wallet.id)
                .uniAppEnvironment()
                .uniSheetDetents([.large])
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

    /// Customize row — the wallet's avatar on the leading edge,
    /// "Customize" + chevron trailing, opening the icon picker. Reads as
    /// a standard inset row (2026-06-19 user direction), replacing the
    /// old centered avatar hero.
    private func customizeRow(_ wallet: WalletRecord) -> some View {
        Button {
            isShowingIconPicker = true
        } label: {
            HStack(spacing: UniSpacing.s) {
                WalletAvatar(spec: wallet.avatarSpec, size: .row, walletId: wallet.id)
                Text("Customize")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .buttonStyle(.plain)
        .listRowBackground(UniColors.Background.secondary)
    }

    /// Custom Tokens row — pushes `CustomTokensListView`. Reactive to
    /// the live count of user-added tokens via `@Query` inside that
    /// view; this row just opens it.
    private var customTokensRow: some View {
        // NavigationLink supplies its OWN trailing disclosure chevron in
        // an inset-grouped List — so the row carries NO manual chevron
        // (a second one was the "two arrows" the user saw, 2026-06-19).
        NavigationLink {
            CustomTokensListView()
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "tag")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(UniColors.Icon.accent)
                    .frame(width: 28)
                Text("Custom tokens")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .listRowBackground(UniColors.Background.secondary)
    }

    // `backupStatusRow` removed 2026-06-07. Its meaning is now carried
    // by `BackupStateCard` at the top of the screen.
    private func viewPhraseRow(_ wallet: WalletRecord) -> some View {
        let hasMnemonic = MnemonicVault.hasMnemonic(for: wallet.id)
        return Button {
            guard hasMnemonic else { return }
            requestReveal(.phrase)
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(hasMnemonic ? UniColors.Icon.accent : UniColors.Icon.disabled)
                    .frame(width: 28)
                Text("View recovery phrase")
                    .font(UniTypography.body)
                    .foregroundStyle(hasMnemonic ? UniColors.Text.primary : UniColors.Text.disabled)
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

    /// "View private key" — the imported-key counterpart of
    /// `viewPhraseRow`. Same biometric gate, same enabled/disabled
    /// register; enabled iff the import stored the key string in
    /// `MnemonicVault` (always, since the always-store policy — only
    /// key wallets imported before it lack the entry).
    private func viewKeyRow(_ wallet: WalletRecord) -> some View {
        let hasKey = MnemonicVault.hasPrivateKey(for: wallet.id)
        return Button {
            guard hasKey else { return }
            requestReveal(.key)
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(hasKey ? UniColors.Icon.accent : UniColors.Icon.disabled)
                    .frame(width: 28)
                Text("View private key")
                    .font(UniTypography.body)
                    .foregroundStyle(hasKey ? UniColors.Text.primary : UniColors.Text.disabled)
                Spacer()
                if hasKey {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .buttonStyle(.plain)
        .disabled(!hasKey)
        .listRowBackground(UniColors.Background.secondary)
    }

    /// "View private keys" — the per-chain export row. Enabled iff a usable
    /// secret is stored on this device (the mnemonic for created / phrase
    /// wallets, the key string for key wallets); a legacy wallet whose secret
    /// wasn't kept shows it disabled, with the footer naming why. Same
    /// biometric gate as the phrase / single-key reveals.
    private func viewChainKeysRow(_ wallet: WalletRecord) -> some View {
        let hasSecret = MnemonicVault.hasMnemonic(for: wallet.id)
            || MnemonicVault.hasPrivateKey(for: wallet.id)
        return Button {
            guard hasSecret else { return }
            requestReveal(.chainKeys)
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(hasSecret ? UniColors.Icon.accent : UniColors.Icon.disabled)
                    .frame(width: 28)
                Text("View private keys")
                    .font(UniTypography.body)
                    .foregroundStyle(hasSecret ? UniColors.Text.primary : UniColors.Text.disabled)
                Spacer()
                if hasSecret {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .buttonStyle(.plain)
        .disabled(!hasSecret)
        .listRowBackground(UniColors.Background.secondary)
    }

    /// The distinct chains this wallet holds, each paired with its address,
    /// for the per-chain key export. Deduped by chain (first address wins),
    /// sorted by display name for a stable list.
    private func chainEntries(_ wallet: WalletRecord) -> [ExportChainEntry] {
        var seen: Set<SupportedChain> = []
        var entries: [ExportChainEntry] = []
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw),
                  !seen.contains(chain) else { continue }
            seen.insert(chain)
            entries.append(ExportChainEntry(chain: chain, address: address.address))
        }
        return entries.sorted { $0.chain.displayName.localizedStandardCompare($1.chain.displayName) == .orderedAscending }
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

    /// Footer under the secret-reveal section. States, per kind and
    /// per actual vault contents, exactly what is stored on this
    /// iPhone — never claims a secret is gone while it's held, never
    /// claims it's held while it's gone (Rule #16 §A, Rule #2 §A.7).
    private func secretFooter(_ wallet: WalletRecord) -> LocalizedStringKey {
        switch wallet.kind {
        case .created, .importedMnemonic:
            if MnemonicVault.hasMnemonic(for: wallet.id) {
                return "Your recovery phrase is stored encrypted on this iPhone (AES-GCM 256-bit, Keychain). Tap “View recovery phrase” anytime — the phrase never leaves this device."
            }
            if wallet.kind == .importedMnemonic {
                // Migration gap: phrase-import wallets persisted before
                // the always-store policy never had their phrase kept.
                // Name the truth and the way out — no backfill flow.
                return "Your phrase wasn't kept when this wallet was imported. You still have it — to store it on this iPhone too, delete this wallet and import the phrase again."
            }
            return "Aperture no longer has your phrase. You're the only copy — write it down and keep it safe."
        case .importedKey:
            if MnemonicVault.hasPrivateKey(for: wallet.id) {
                return "Your private key is stored encrypted on this iPhone (AES-GCM 256-bit, Keychain). Tap “View private key” anytime — the key never leaves this device."
            }
            return "Your key wasn't kept when this wallet was imported. You still have it — to store it on this iPhone too, delete this wallet and import the key again."
        case .watchOnly:
            // Unreachable — the watch-only kind renders no reveal
            // section (the Details footer carries the statement).
            return "This wallet watches an address. There is no recovery phrase or private key on this iPhone — nothing secret is stored."
        }
    }

    private func commitRename(_ wallet: WalletRecord) {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != wallet.name else { return }
        let id = wallet.id
        let newName = trimmed
        let persistedName = wallet.name
        Task { @MainActor in
            let repo = WalletRepository(modelContainer: modelContext.container)
            do {
                try await repo.renameWallet(id: id, to: newName)
            } catch {
                // Revert the field to the persisted name so the UI
                // never shows a rename that didn't land.
                editedName = persistedName
                errorAlertMessage = String.apertureLocalized("Couldn't rename this wallet. Try again.")
            }
        }
    }

    @MainActor
    private func deleteWallet(_ wallet: WalletRecord) async {
        let id = wallet.id
        // `deleteWallet(id:)` delegates to the canonical
        // `deleteWalletAndActivateNext(walletId:)`, which owns the whole
        // contract atomically (2026-06-13): it wipes both Keychain vaults
        // idempotently, deletes the record, and — when the deleted wallet
        // is the active one — moves `activeWalletId` to a deterministic
        // successor BEFORE the save commits. So no manual `SeedVault` /
        // `MnemonicVault` wipes here (the repo does it, and doing it
        // twice risked destroying the secret before a failed save left a
        // live record), and no `activeWalletIdRaw = ""` clobber (the repo
        // names a real successor; the old clear was the source of the
        // "$50 wallet selected, $700 wallet's data" report).
        let repo = WalletRepository(modelContainer: modelContext.container)
        do {
            try await repo.deleteWallet(id: id)
        } catch {
            errorAlertMessage = String.apertureLocalized("Couldn't delete this wallet from the local database. Try again.")
            return
        }
        // The deleted wallet's detail screen can't stay on screen —
        // dismiss back to the wallet list.
        dismiss()
    }

    /// `true` iff this wallet's secret material (recovery phrase or
    /// private key) actually lives in the Keychain on this iPhone.
    /// Watch-only wallets and imports persisted before the always-store
    /// policy hold none — drives `WalletDeleteSheet`'s reversible-vs-final
    /// consequence line and the inventory's encrypted-secret row.
    private func walletHasStoredSecret(_ wallet: WalletRecord) -> Bool {
        switch wallet.kind {
        case .importedKey:
            return MnemonicVault.hasPrivateKey(for: wallet.id)
        case .created, .importedMnemonic:
            return MnemonicVault.hasMnemonic(for: wallet.id)
        case .watchOnly:
            return false
        }
    }

    // MARK: - Sensitive-reveal auth resolution

    /// Resolve how to gate a sensitive reveal, then present the right
    /// surface. See the `SensitiveReveal` state block for the priority.
    private func requestReveal(_ target: SensitiveReveal) {
        pendingReveal = target
        if PinCodeStorage.hasPin {
            // App passcode set → unified passcode screen (auto Face ID
            // if the in-app Face ID toggle is on).
            isShowingPasscodeGate = true
        } else if BiometricService().isAvailable {
            // No app passcode, but the device has Face ID/Touch ID
            // enrolled → prompt it directly, even with both in-app
            // toggles off.
            biometricChallenge = BiometricChallenge(
                reason: revealReason(target),
                onSuccess: {
                    biometricChallenge = nil
                    performReveal(target)
                }
            )
        } else {
            // Nothing on the device can gate it → warn, then allow.
            isShowingNoAuthWarning = true
        }
    }

    private func performReveal(_ target: SensitiveReveal) {
        switch target {
        case .phrase:    isShowingPhrase = true
        case .key:       isShowingKey = true
        case .chainKeys: isShowingChainKeys = true
        case .backup:    Task { await loadWordsAndPresentBackup() }
        }
    }

    private func revealReason(_ target: SensitiveReveal) -> LocalizedStringResource {
        switch target {
        case .phrase:    return LocalizedStringResource("Confirm to view your recovery phrase.")
        case .key:       return LocalizedStringResource("Confirm to view your private key.")
        case .chainKeys: return LocalizedStringResource("Confirm to view your private keys.")
        case .backup:    return LocalizedStringResource("Confirm to back up your wallet.")
        }
    }

    // MARK: - Backup section helpers

    /// One backup-status row. ALWAYS tappable (except while the iCloud status
    /// is still resolving) so the user can back up — or re-back-up — at any
    /// time (2026-06-20 user direction: "manual backup should never be
    /// disabled"). The trailing badge shows the current status; the chevron
    /// signals the row is actionable in every non-checking state.
    private func backupStatusRow(
        icon: String,
        title: LocalizedStringKey,
        status: BackupRowStatus,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(UniColors.Icon.accent)
                    .frame(width: 28)
                Text(title)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                switch status {
                case .checking:
                    ProgressView().controlSize(.small)
                case .done:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(UniColors.Status.successForeground)
                        Text("Backed up")
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Status.successForeground)
                    }
                    chevron
                case .notDone:
                    Text("Not backed up")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                    chevron
                case .unavailable:
                    Text("Unavailable")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.tertiary)
                    chevron
                }
            }
            .padding(.vertical, UniSpacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Only blocked while the iCloud status is still resolving — never
        // permanently disabled, so a backed-up wallet can still be backed up
        // again (e.g. add the other method, or re-upload to iCloud).
        .disabled(status == .checking)
        .listRowBackground(UniColors.Background.secondary)
    }

    /// Trailing disclosure chevron shared by the backup rows.
    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(UniColors.Icon.tertiary)
    }

    /// Auth-gate → decrypt → present the backup flow (iCloud / manual chooser).
    private func startWalletBackup() {
        requestReveal(.backup)
    }

    @MainActor
    private func loadWordsAndPresentBackup() async {
        let id = walletId
        let loaded = try? await Task.detached(priority: .userInitiated) {
            try MnemonicVault.loadMnemonic(for: id)
        }.value
        guard let words = loaded ?? nil, !words.isEmpty else {
            errorAlertMessage = String.apertureLocalized("Couldn't read this wallet's phrase to back it up. Try restarting Aperture.")
            return
        }
        backupWords = words
        isShowingWalletBackup = true
    }

    /// Resolve this wallet's iCloud-backup status from CloudKit.
    @MainActor
    private func refreshICloudBackupStatus() async {
        iCloudStatus = .checking
        let store = CloudKitBackupStore()
        do {
            try await store.ensureAccountAvailable()
            _ = try await store.fetch(walletId: walletId)
            iCloudStatus = .done
        } catch let error as CloudKitBackupStore.StoreError {
            iCloudStatus = (error == .notFound) ? .notDone : .unavailable
        } catch {
            iCloudStatus = .unavailable
        }
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

    /// Guards against two `LAContext` evaluations racing — the
    /// `.task` auto-prompt and the manual Confirm button share one
    /// serialized path; the button is suppressed while a prompt is up.
    @State private var isAuthenticating: Bool = false
    /// Ensures the completion (success or failure) fires at most once.
    @State private var hasCompleted: Bool = false

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
            UniButton(title: "Confirm", variant: .primary, isEnabled: !isAuthenticating) {
                Task { await authenticate() }
            }
        }
        .task {
            // Auto-present the system prompt on appear for one-tap UX.
            await authenticate()
        }
    }

    @MainActor
    private func authenticate() async {
        guard !isAuthenticating, !hasCompleted else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let outcome = await BiometricService().authenticate(reason: reason)
        guard !hasCompleted else { return }
        hasCompleted = true
        if case .success = outcome { onSuccess() } else { onFailure() }
    }
}

// MARK: - No-device-lock warning sheet

/// Shown before a sensitive reveal when this iPhone has neither an
/// in-app passcode nor an enrolled biometric — nothing can gate the
/// secret, so we say so honestly (Rule #16) and let the user decide.
/// Recommends turning on a lock, but never blocks: the user owns the
/// device and the choice.
private struct NoDeviceLockWarningSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        UniSheet(title: "No lock is set") {
            VStack(spacing: UniSpacing.m) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Status.warningForeground)
                    .accessibilityHidden(true)
                UniBody(
                    text: "This iPhone has no passcode or Face ID set, so anyone holding it unlocked could view this secret. Turn on a passcode or Face ID in Settings for real protection.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
            }
        } actions: {
            UniButton(title: "View anyway", variant: .primary) { onContinue() }
            UniButton(title: "Cancel", variant: .secondary) { onCancel() }
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
