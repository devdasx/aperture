import SwiftUI
import SwiftData
import OSLog

/// Terminal placeholder for the create-wallet flow, pushed onto the
/// cover's `NavigationStack` after `BackupVerifyView` succeeds.
///
/// **Intent (one sentence):** quietly acknowledge that the wallet exists
/// and hand the user back to the app, without theatre.
///
/// **What changed 2026-06-06.** This screen is now also the moment the
/// wallet is **persisted to the local database**. On appear, the view
/// runs `state.persist(into:requiresBackup:)` which encrypts and stores
/// the BIP-39 seed in Keychain (`SeedVault`) and inserts a `WalletRecord`
/// via `WalletRepository`. The Done button is disabled until persistence
/// resolves so the user cannot dismiss with an unpersisted wallet. On
/// failure, the view surfaces an error footnote with a Retry button
/// rather than silently swallowing.
///
/// **No back navigation.** The verify step is final — once the user has
/// proven the phrase, they should land on the next surface, not be
/// able to wander back into a generation step. The system back button
/// is suppressed via `.navigationBarBackButtonHidden(true)`.
struct WalletReadyView: View {
    /// Shared mnemonic + passphrase state — same instance the cover
    /// has been threading through every screen. Needed here to call
    /// `state.persist(...)` once the user lands on the success screen.
    let state: CreateWalletState

    /// Set when the user reached this screen via the skip-backup
    /// branch. Threaded through to `WalletRecord.requiresBackup` so
    /// Settings → Wallets can surface a "back up your recovery phrase"
    /// row later (T-016).
    let requiresBackup: Bool

    /// Fires when the user taps Done. The caller dismisses the
    /// `fullScreenCover` and clears the unbacked-up flag.
    let onDone: () -> Void

    /// SwiftData container injected by `UniAppApp`'s
    /// `.modelContainer(...)` modifier. Used to construct a
    /// `WalletRepository` actor for the one-shot persist call.
    @Environment(\.modelContext) private var modelContext

    private enum PersistState: Equatable {
        case idle
        case persisting
        case persisted
        case failed(String)
    }
    @State private var persistState: PersistState = .idle

    /// The in-flight persist task. Stored so Retry can cancel any
    /// previous launch before spawning a new one — two concurrent
    /// persists of the same wallet would race on Keychain + SwiftData.
    @State private var persistTask: Task<Void, Never>? = nil

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "wallet-ready"
    )

    var body: some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 96, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Status.successForeground)
                .accessibilityHidden(true)

            VStack(spacing: UniSpacing.s) {
                UniLargeTitle(
                    text: "Your wallet is ready.",
                    alignment: .center
                )
                UniBody(
                    text: "Your recovery phrase is saved. You can find your wallet on the main screen.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
            }
            .padding(.horizontal, UniSpacing.l)

            // Rule #16 §A.5 — the boundary statement anchored to the
            // success moment. The user has just taken responsibility
            // for their keys; the calm reminder of what we *don't* do
            // is what makes that responsibility feel earned, not
            // imposed.
            UniFootnote(
                text: "No accounts. No servers. Your wallet lives on your iPhone.",
                alignment: .center
            )
            .padding(.horizontal, UniSpacing.l)

            Spacer()
        }
        .safeAreaInset(edge: .bottom) {
            actionRegion
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        // Rule #10 — Aperture's most weighted tactile moment. Plays
        // the `.walletSealed` Core Haptics pattern exactly once when
        // the view appears (the trigger is a fresh per-presentation
        // sentinel). Reduce Motion silences automatically inside
        // `UniHapticEngine`.
        .uniHapticSignature(.walletSealed, trigger: walletSealedTrigger)
        .onAppear {
            walletSealedTrigger = UUID()
            persistIfNeeded()
        }
    }

    @State private var walletSealedTrigger: UUID = UUID()

    private var actionRegion: some View {
        VStack(spacing: UniSpacing.s) {
            if case .failed(let message) = persistState {
                UniFootnote(
                    text: LocalizedStringKey(message),
                    alignment: .center,
                    color: UniColors.Status.errorForeground
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, UniSpacing.m)
            }

            GlassEffectContainer(spacing: UniSpacing.s) {
                UniButton(
                    title: persistButtonTitle,
                    variant: .primary,
                    isEnabled: persistState != .persisting
                ) {
                    switch persistState {
                    case .persisted:
                        onDone()
                    case .failed:
                        persistIfNeeded(force: true)
                    case .idle, .persisting:
                        // Idle shouldn't be reachable (onAppear fires
                        // persistIfNeeded), but if it is, kick it.
                        persistIfNeeded()
                    }
                }
            }
        }
    }

    private var persistButtonTitle: LocalizedStringKey {
        switch persistState {
        case .idle, .persisting: return "Saving…"
        case .persisted:         return "Done"
        case .failed:            return "Retry"
        }
    }

    /// One-shot persistence kick. Idempotent — won't re-run if already
    /// persisting or persisted. Pass `force: true` from the Retry
    /// button to override the persisted-state guard. Re-entry safe:
    /// an in-flight persist always blocks a second launch (even a
    /// forced one), and the stored task is cancelled before a new
    /// one is spawned so retries can never run concurrently.
    private func persistIfNeeded(force: Bool = false) {
        guard persistState != .persisting else { return }
        if !force, persistState == .persisted { return }
        persistTask?.cancel()
        persistState = .persisting
        let repository = WalletRepository(modelContainer: modelContext.container)
        let requiresBackupFlag = requiresBackup
        persistTask = Task { @MainActor in
            do {
                _ = try await state.persist(
                    into: repository,
                    requiresBackup: requiresBackupFlag
                )
                persistState = .persisted
                // The seed + encrypted mnemonic are in Keychain —
                // wipe the plaintext secrets before the user moves
                // on to the PIN flow.
                state.zeroSensitiveState()
            } catch {
                Self.log.error(
                    "Create-wallet persist failed: \(String(describing: error), privacy: .public)"
                )
                persistState = .failed("Couldn't save your wallet. Tap Retry.")
            }
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        WalletReadyView(state: CreateWalletState(), requiresBackup: false, onDone: {})
    }
    .preferredColorScheme(.light)
    .modelContainer(ApertureDatabase.shared.container)
}

#Preview("Dark") {
    NavigationStack {
        WalletReadyView(state: CreateWalletState(), requiresBackup: false, onDone: {})
    }
    .preferredColorScheme(.dark)
    .modelContainer(ApertureDatabase.shared.container)
}
