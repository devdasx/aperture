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
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage("biometricEnabled") private var biometricEnabled: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String = ""
    @State private var isShowingDeleteConfirm: Bool = false
    /// Passcode-only verify gate presented after the typed-name
    /// confirmation and before the destructive delete fires. Per
    /// user direction 2026-06-13, wallet removal asks for the
    /// passcode — never Face ID — so the gate's `PinCodeView` runs
    /// with `allowsBiometrics: false`. Armed only when a passcode
    /// exists: no-passcode users keep the typed-name confirmation
    /// as the sole gate (PIN is optional per Rule #17).
    @State private var isShowingDeletePinVerify: Bool = false
    /// Set by the confirmation sheet's `onConfirm` when a passcode
    /// gate must follow; consumed in the sheet's `onDismiss` so the
    /// verify cover presents only after the sheet has fully gone —
    /// presenting a second surface mid-dismissal races the
    /// transition and can drop the presentation.
    @State private var pendingDeletePinVerify: Bool = false
    @State private var isShowingPhrase: Bool = false
    @State private var isShowingKey: Bool = false
    @State private var isShowingBackupFlow: Bool = false
    @State private var isShowingIconPicker: Bool = false
    @State private var biometricChallenge: BiometricChallenge?
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
            Section {
                VStack(spacing: UniSpacing.m) {
                    // Gradient-disc avatar per the design handoff.
                    // `wallet.avatarSpec` hydrates the persisted columns
                    // with auto(name) fallback; the picker writes through
                    // the same hydrate path so this hero preview updates
                    // live the moment the user taps Save.
                    WalletAvatar(spec: wallet.avatarSpec, size: .preview, walletId: wallet.id)

                    UniButton(
                        title: "Customise wallet",
                        variant: .secondary,
                        systemImage: "paintpalette"
                    ) {
                        isShowingIconPicker = true
                    }
                    .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UniSpacing.m)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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

            // Secret-reveal section. Watch-only wallets hold no secret
            // — no row at all (an enabled-looking row that can't ever
            // reveal anything would be dishonest chrome).
            if wallet.kind != .watchOnly {
                Section {
                    if wallet.kind == .importedKey {
                        viewKeyRow(wallet)
                    } else {
                        viewPhraseRow(wallet)
                    }
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
        .sheet(
            isPresented: $isShowingDeleteConfirm,
            onDismiss: {
                // Hand off to the passcode gate only after the
                // confirmation sheet has fully dismissed (see
                // `pendingDeletePinVerify` doc). Cancel / swipe-down
                // never sets the flag, so plain dismissals are inert.
                if pendingDeletePinVerify {
                    pendingDeletePinVerify = false
                    isShowingDeletePinVerify = true
                }
            }
        ) {
            DeleteWalletConfirmationSheet(
                walletName: wallet.name,
                onConfirm: {
                    // Typed-name semantics are unchanged — this fires
                    // only once the name matches. With a passcode set,
                    // the destructive action is deferred behind the
                    // passcode-only verify gate (user direction
                    // 2026-06-13); without one, the existing
                    // confirm-then-delete behavior stays as-is.
                    if PinCodeStorage.hasPin {
                        pendingDeletePinVerify = true
                    } else {
                        Task { await deleteWallet(wallet) }
                    }
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingDeletePinVerify) {
            // Same presentation shape as the Security entry gate and
            // `PinDisableVerifyFlow`: NavigationStack so the close
            // affordance lives in a native toolbar slot (Rule #15),
            // canonical `PinCodeView` per Rule #17 — passcode-only,
            // so no Face ID auto-prompt and no biometric keypad key.
            NavigationStack {
                PinCodeView(
                    mode: .verify,
                    onComplete: { _ in
                        isShowingDeletePinVerify = false
                        Task { await deleteWallet(wallet) }
                    },
                    onCancel: {
                        // Declining to authenticate aborts the
                        // deletion entirely — back to the detail
                        // screen, wallet untouched.
                        isShowingDeletePinVerify = false
                    },
                    allowsBiometrics: false
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingDeletePinVerify = false } label: {
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
        .sheet(isPresented: $isShowingPhrase) {
            RecoveryPhraseRevealSheet(walletId: wallet.id)
                .uniAppEnvironment()
                .presentationDetents([.large])
                .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingKey) {
            PrivateKeyRevealSheet(walletId: wallet.id)
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

    /// Custom Tokens row — pushes `CustomTokensListView`. Reactive to
    /// the live count of user-added tokens via `@Query` inside that
    /// view; this row just opens it.
    private var customTokensRow: some View {
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
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
            // Gate the reveal behind a biometric prompt when biometric
            // is enabled — keeps the phrase from being trivially
            // viewable by anyone with the unlocked phone (Rule #16).
            if biometricEnabled {
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

    /// "View private key" — the imported-key counterpart of
    /// `viewPhraseRow`. Same biometric gate, same enabled/disabled
    /// register; enabled iff the import stored the key string in
    /// `MnemonicVault` (always, since the always-store policy — only
    /// key wallets imported before it lack the entry).
    private func viewKeyRow(_ wallet: WalletRecord) -> some View {
        let hasKey = MnemonicVault.hasPrivateKey(for: wallet.id)
        return Button {
            guard hasKey else { return }
            // Same gate as the phrase reveal — the key must not be
            // trivially viewable by anyone holding the unlocked phone
            // (Rule #16).
            if biometricEnabled {
                biometricChallenge = BiometricChallenge(
                    reason: LocalizedStringResource("Confirm to view your private key."),
                    onSuccess: {
                        biometricChallenge = nil
                        isShowingKey = true
                    }
                )
            } else {
                isShowingKey = true
            }
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(hasKey ? UniColors.Icon.accent : UniColors.Icon.tertiary)
                    .frame(width: 28)
                Text("View private key")
                    .font(UniTypography.body)
                    .foregroundStyle(hasKey ? UniColors.Text.primary : UniColors.Text.tertiary)
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
        // Keychain first: if a vault delete fails the database record
        // survives, so the wallet stays reachable and the user can
        // retry. Deleting the database row first would orphan the
        // Keychain secrets with no UI left to reach them.
        try? SeedVault.deleteSeed(for: id)
        try? MnemonicVault.deleteMnemonic(for: id)
        try? MnemonicVault.deletePrivateKey(for: id)
        let repo = WalletRepository(modelContainer: modelContext.container)
        do {
            try await repo.deleteWallet(id: id)
        } catch {
            errorAlertMessage = String.apertureLocalized("Couldn't delete this wallet from the local database. Try again.")
            return
        }
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
