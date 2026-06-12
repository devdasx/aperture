import SwiftUI

/// Backup-this-wallet flow for an existing, unbacked wallet (T-046).
///
/// Presented as a `.large` sheet from `WalletDetailView` when the user
/// taps "Back up now" on the backup-state card. Loads the stored
/// mnemonic from `MnemonicVault.loadMnemonic(for:)`, then routes the
/// user through the same `BackupVerifyView` challenge surface the
/// create-wallet flow uses — so the gesture of proving you saved the
/// phrase reads identically across both contexts (a wallet you just
/// created and a wallet you skipped backup on weeks ago).
///
/// **Why reuse `BackupVerifyView` instead of building a parallel
/// surface.** The challenge UI (three randomly-picked positions, four
/// choices each, no lockout) is the canonical "prove you saved the
/// phrase" gesture in Aperture. Replicating it would mean two surfaces
/// drifting independently; reusing it means any future refinement of
/// the verify gesture (better randomization, accessibility tweaks,
/// haptic adjustments) lands once for both flows. The verify view
/// reads only `state.words`; the parent flow owns the persistence
/// transition (`WalletRepository.markBackupComplete`).
///
/// **State shape.** The flow constructs a fresh `CreateWalletState`,
/// reads the mnemonic from `MnemonicVault`, and calls `state.commit(
/// words:)` to install those words into the state instance. This
/// rolls `state.pendingWalletId` (per `CreateWalletState.commit`'s
/// contract), which we intentionally ignore — the wallet identity is
/// already established (`walletId`), so the rolled pending id is
/// inert. `BackupVerifyView` reads `state.words` only; the pending id
/// is never consulted in the verify path.
///
/// **Mnemonic missing.** The only wallets whose `MnemonicVault` entry
/// is absent are pre-MnemonicVault wallets (created before 2026-06-04
/// when the vault always-store policy shipped) and imported-key /
/// watch-only kinds (which never had a mnemonic). For those wallets
/// `requiresBackup` is already `false` so the parent card never
/// surfaces "Back up now" — but the flow still defends honestly
/// against the edge case by rendering a calm explanatory empty state
/// rather than crashing.
///
/// **On verify success.** Calls `WalletRepository.markBackupComplete(
/// id:)` to flip `WalletRecord.requiresBackup` → `false`. Then
/// deletes the encrypted-local mnemonic from `MnemonicVault` — the
/// user is now the only copy, which is the honest contract the
/// disclosure sheet promises at create-wallet time. Dismisses the
/// sheet; SwiftData `@Query` reactivity on the parent
/// `WalletDetailView` swaps the backup card from "Back up this
/// wallet" → "Backed up." in front of the user.
///
/// **Honesty (Rule #16 §A.6).** The verification gesture is real:
/// missing positions or wrong picks block completion. We never
/// short-circuit the challenge for an existing wallet — the user
/// proves they have the phrase, the same way the create flow's user
/// did. Anything else would be theatre.
struct BackupExistingWalletFlow: View {
    /// The wallet whose backup is being verified.
    let walletId: UUID

    /// Fires after the verify view succeeds AND the database has been
    /// updated. The caller (`WalletDetailView`) uses this to dismiss
    /// the sheet — the `@Query` reactivity then animates the card
    /// from State A → State B.
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Loaded mnemonic words. `nil` until the on-appear load
    /// resolves; empty + `loadError` populated on failure.
    @State private var state: CreateWalletState?
    @State private var loadError: LocalizedStringKey?
    /// Presents the persistence-failure alert when
    /// `markBackupComplete` can't be written. The mnemonic is kept.
    @State private var isShowingCompleteError: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if let state {
                    // The canonical verify surface — same component the
                    // create flow uses. The state has already had the
                    // stored mnemonic installed via `commit(words:)`.
                    BackupVerifyView(state: state) {
                        Task { await complete() }
                    }
                } else if let loadError {
                    errorView(loadError)
                } else {
                    loadingView
                }
            }
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text("Back up this wallet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
            }
        }
        .onAppear(perform: load)
        .alert(
            Text("Couldn't record the backup"),
            isPresented: $isShowingCompleteError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Aperture couldn't save the backup confirmation to the local database. Your encrypted phrase is still stored on this iPhone — nothing was deleted. Try again.")
        }
    }

    // MARK: - States while the mnemonic is resolved

    /// Brief progress surface while `MnemonicVault.loadMnemonic`
    /// returns. The load is synchronous (Keychain read + AES-GCM
    /// decrypt) but we still show a calm spinner so the screen never
    /// appears to be empty at first paint.
    private var loadingView: some View {
        VStack(spacing: UniSpacing.s) {
            ProgressView()
            UniFootnote(
                text: "Preparing your phrase.",
                alignment: .center,
                color: UniColors.Text.tertiary
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Calm honest surface when the mnemonic isn't available. Only
    /// reachable as a defensive edge case (the parent only surfaces
    /// "Back up now" when `requiresBackup == true`, and any wallet
    /// whose `requiresBackup` is `true` should have its mnemonic in
    /// the vault). Composes `UniEmptyState` so the visual register
    /// matches the rest of Aperture's "nothing here, here's why"
    /// surfaces.
    private func errorView(_ message: LocalizedStringKey) -> some View {
        VStack(spacing: UniSpacing.l) {
            UniEmptyState(
                title: "We can't show this wallet's phrase.",
                detail: message,
                mark: .icon(systemName: "questionmark.circle")
            )
            UniButton(title: "Close", variant: .secondary) {
                dismiss()
            }
            .padding(.horizontal, UniSpacing.l)
        }
        .padding(.vertical, UniSpacing.xl)
    }

    // MARK: - Load + complete

    /// Read the encrypted mnemonic for `walletId` and seed a fresh
    /// `CreateWalletState` with it.
    ///
    /// Defensive: if no mnemonic is stored for this wallet (edge case
    /// for legacy or non-mnemonic wallets), surface a calm
    /// explanation rather than crashing.
    private func load() {
        // Already loaded — preserve the existing state across
        // body re-renders (e.g. layout direction flip).
        guard state == nil, loadError == nil else { return }
        do {
            guard let words = try MnemonicVault.loadMnemonic(for: walletId),
                  !words.isEmpty else {
                loadError = "There's no encrypted phrase stored for this wallet. If you saved it elsewhere, you're already its only copy."
                return
            }
            // Match the stored mnemonic's word count so the state's
            // wordCount agrees with what `commit(words:)` installs.
            let wordCount: BIP39WordCount = words.count == 24 ? .twentyFour : .twelve
            let fresh = CreateWalletState(wordCount: wordCount)
            fresh.commit(words: words)
            state = fresh
        } catch {
            loadError = "We couldn't decrypt this wallet's phrase. Try restarting Aperture."
        }
    }

    /// Run after `BackupVerifyView` reports success. Flips the
    /// persistence flag, deletes the encrypted local mnemonic (the
    /// user is now the only copy — that's the contract), and
    /// dismisses. SwiftData `@Query` reactivity on the parent
    /// surfaces the Done state.
    @MainActor
    private func complete() async {
        let repo = WalletRepository(modelContainer: modelContext.container)
        do {
            try await repo.markBackupComplete(id: walletId)
        } catch {
            // The database still says "unverified" — deleting the
            // mnemonic now would leave this wallet permanently
            // unbackupable (the card would keep demanding a backup
            // the vault can no longer serve). Keep the mnemonic,
            // surface the failure, and let the user retry.
            isShowingCompleteError = true
            return
        }
        // The encrypted local copy was the safety net for an
        // unbacked wallet. Now that the user has proven they have the
        // phrase, Aperture honors the disclosure-sheet promise that
        // backed-up wallets exist as one user-held copy. The
        // `RecoveryPhraseRevealSheet` reads from this vault — its
        // call site (`WalletDetailView.viewPhraseRow`) already gates
        // the affordance on `MnemonicVault.hasMnemonic(for:)`, so
        // deletion is what makes the View-Phrase row disappear too.
        try? MnemonicVault.deleteMnemonic(for: walletId)
        onCompleted()
        dismiss()
    }
}
