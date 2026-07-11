import Foundation
import GRDB

/// The outbox orchestrator (Rule #27 §C): sign → broadcast → persist →
/// poll. The single API the Send UI calls AFTER it has authenticated the
/// user (PIN / Face ID gating is the UI's job — this executor assumes
/// authorization already happened and just performs the send).
///
/// **Pipeline (adapted from Stabro's `SmartTransactionExecutor`).**
/// 1. Resolve the wallet + its address row for the chain, as `Sendable`
///    values.
/// 2. JUST-IN-TIME refresh the volatile pre-sign data off-main (Rule #27
///    §C): EVM live pending nonce. (Bitcoin's UTXO set + fee rate are
///    already in the draft, refreshed by the compose layer immediately
///    before this call; if a future flow needs a re-fetch it threads it
///    through the draft.)
/// 3. Derive the key + build + sign OFF-MAIN (Rule #28) — the key lives
///    only inside `SigningKeyProvider`'s closure.
/// 4. Broadcast; get the real txid/hash.
/// 5. Write a PENDING `TransactionRecord` to the store (the outbox row),
///    so the UI shows the send live (Rule #25). Then poll the receipt
///    and update the row to confirmed/failed.
///
/// **Result.** `SentTransaction` (the real hash + chain) on success, a
/// typed `SigningError` on failure — never a fabricated success.
///
/// `@MainActor` API surface for UI callers; the heavy sign/broadcast
/// runs off-main via a detached task and only `Sendable` values cross back.
@MainActor
struct SendExecutor {

    /// The successful outcome the UI shows + links to an explorer.
    struct SentTransaction: Sendable, Hashable {
        let txHash: String
        let chain: SupportedChain
        /// The pending DB row id (for the UI to observe its status).
        let recordId: UUID?
    }

    private let database: AppDatabase
    private let broadcaster: BroadcastService

    init(database: AppDatabase = .shared,
         broadcaster: BroadcastService = BroadcastService()) {
        self.database = database
        self.broadcaster = broadcaster
    }

    /// Execute the send. `walletId` is the signing wallet; `passphrase`
    /// is supplied by the UI's T-019 prompt when the wallet has one
    /// (`nil` otherwise — a passphrase wallet then refuses honestly).
    func execute(
        draft: SendDraft,
        walletId: UUID,
        passphrase: String? = nil
    ) async -> Result<SentTransaction, SigningError> {
        // BUG-002: before EVM sign/JIT, unify legacy per-L2 Trust addresses
        // to the MetaMask Ethereum path (uses passphrase when required).
        // P2-008: only rewrite fromAddress when the draft's address is no
        // longer a stored wallet address (migration removed it). Never
        // force preferred over an intentional multi-account fromAddress
        // that still exists on this wallet.
        var effectiveDraft = draft
        if draft.chain.family == .evm {
            _ = try? EVMUnifiedAddressMigration.unifyWalletIfNeeded(
                walletId: walletId,
                passphrase: passphrase,
                database: database
            )
            let draftFromStillStored = resolveWallet(
                walletId: walletId,
                chain: draft.chain,
                fromAddress: draft.fromAddress
            )
            if case .addressNotFound = draftFromStillStored,
               let live = liveAddress(walletId: walletId, chain: draft.chain),
               !live.isEmpty,
               live.caseInsensitiveCompare(draft.fromAddress) != .orderedSame {
                effectiveDraft = draft.replacingFromAddress(live)
            }
        }

        // 1. Resolve the wallet descriptor + the address row id.
        // BUG-018: require exact (wallet, chain, fromAddress) — never fall
        // back to the chain's preferred address for the outbox.
        switch resolveWallet(
            walletId: walletId,
            chain: effectiveDraft.chain,
            fromAddress: effectiveDraft.fromAddress
        ) {
        case .walletNotFound:
            return .failure(.noWallet)
        case .addressNotFound:
            return .failure(.malformedDraft(
                "fromAddress is not stored for this wallet on \(effectiveDraft.chain.displayName)"
            ))
        case .resolved(let walletDescriptor, let addressId):
            return await executeResolved(
                draft: effectiveDraft,
                walletId: walletId,
                walletDescriptor: walletDescriptor,
                addressId: addressId,
                passphrase: passphrase
            )
        }
    }

    private func executeResolved(
        draft: SendDraft,
        walletId: UUID,
        walletDescriptor: WalletDescriptor,
        addressId: UUID,
        passphrase: String?
    ) async -> Result<SentTransaction, SigningError> {
        let effectiveDraft = draft
        let addressId = addressId

        // 2. Just-in-time refresh (off-main) + 3. sign (off-main).
        let signed: SignedTransaction
        do {
            signed = try await signOffMain(
                draft: effectiveDraft, wallet: walletDescriptor, database: database, passphrase: passphrase
            )
        } catch let error as SigningError {
            return .failure(error)
        } catch {
            return .failure(.signingFailed(error.localizedDescription))
        }

        // 4. Broadcast (off-main I/O).
        let txHash: String
        do {
            txHash = try await broadcaster.broadcast(signed, chain: effectiveDraft.chain)
        } catch {
            // `broadcast` is typed `throws(SigningError)`, so `error` carries
            // the precise (incl. `.broadcastAmbiguous`) outcome — surface it
            // verbatim rather than flattening to `.broadcastFailed`.
            return .failure(error)
        }

        // 5. Write the PENDING outbox row (live-update, Rule #25/#27),
        //    then poll the receipt to update it.
        // P2-001: broadcast already succeeded — never report non-send — but
        // do not silently swallow outbox write failure. Retry, then durable
        // orphan queue so Activity + confirmation monitor still track.
        // BUG-018: addressId is always the exact fromAddress row — never preferred.
        let recordId = await writePendingRecordWithRetry(
            txHash: txHash, draft: effectiveDraft, addressId: addressId
        )
        await applyOptimisticOutgoingState(walletId: walletId, draft: effectiveDraft)

        // Fire-and-forget DB monitor. It polls every 3 seconds while pending
        // rows exist and stops per row once the chain reports confirmed or
        // failed, so all supported chains share the same reconciliation path.
        await PendingTransactionMonitor.shared.kick(database: database)

        return .success(SentTransaction(txHash: txHash, chain: effectiveDraft.chain, recordId: recordId))
    }

    /// Live preferred/receive address for `(wallet, chain)` after migration.
    private func liveAddress(walletId: UUID, chain: SupportedChain) -> String? {
        try? database.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT address FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ?
                ORDER BY is_receive_preferred DESC
                LIMIT 1
                """,
                arguments: [walletId.uuidString, chain.rawValue]
            )
        }
    }

    // MARK: - 1. Wallet resolution (main actor)

    /// BUG-018: exact `(wallet, chain, fromAddress)` only — never fall back
    /// to the chain's preferred address when writing the outbox row.
    private func resolveWallet(
        walletId: UUID,
        chain: SupportedChain,
        fromAddress: String
    ) -> SendOutboxAddressResolver.Resolution {
        SendOutboxAddressResolver.resolve(
            walletId: walletId,
            chain: chain,
            fromAddress: fromAddress,
            database: database
        )
    }

    // MARK: - 2+3. Just-in-time refresh + sign (off-main)

    private nonisolated func signOffMain(
        draft: SendDraft,
        wallet: WalletDescriptor,
        database: AppDatabase,
        passphrase: String?
    ) async throws -> SignedTransaction {
        let jit = try await refreshJustInTime(
            draft: draft, wallet: wallet, database: database, passphrase: passphrase
        )
        // Detached so the PBKDF2 seed stretch + secp256k1/ed25519 sign
        // run off any actor (Rule #28). Only Sendable values cross in;
        // the SignedTransaction crosses back.
        return try await Task.detached(priority: .userInitiated) {
            try TransactionSigner.sign(
                draft: draft, wallet: wallet, jit: jit, passphrase: passphrase
            )
        }.value
    }

    /// Refresh the volatile pre-sign values immediately before signing
    /// (Rule #27 §C). Per family: EVM nonce; Solana blockhash + ATAs; XRP
    /// sequence + last-ledger; TON seqno + jetton wallet; TRON block ref;
    /// NEAR nonce + block hash; Polkadot runtime/era/nonce; Aptos sequence
    /// + gas; Sui coins + RGP; Stellar
    /// sequence. We never sign against a stale value. All fetches are
    /// off-main (this method is `nonisolated`); the per-chain fetchers live
    /// in `SendExecutor+JustInTime.swift`.
    private nonisolated func refreshJustInTime(
        draft: SendDraft,
        wallet: WalletDescriptor,
        database: AppDatabase,
        passphrase: String?
    ) async throws -> TransactionSigner.JustInTimeData {
        switch draft.chain.family {
        case .evm:
            do {
                let hex = try await RPCClient.shared.callJSONString(
                    chain: draft.chain,
                    method: "eth_getTransactionCount",
                    params: [draft.fromAddress, "pending"]
                )
                let stripped = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
                guard let nonce = UInt64(stripped, radix: 16) else {
                    throw SigningError.justInTimeRefreshFailed("could not parse nonce")
                }
                return TransactionSigner.JustInTimeData(evmNonce: nonce)
            } catch let rpc as RPCError {
                throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
            }
        case .bitcoin:
            // BUG-005: compose may select UTXOs across every receive/change
            // path. Prefer the wallet-level chain_utxos cache; on miss OR
            // when selected outpoints are missing from the cache, re-fetch
            // ALL wallet addresses for the chain (same set as compose) —
            // never only draft.fromAddress.
            do {
                let cached = try ChainStateRepository(database: database)
                    .utxos(walletId: wallet.id, chain: draft.chain)
                if !cached.isEmpty,
                   let rebound = try? UTXOService.rebindSelected(
                    selected: draft.selectedUTXOs,
                    live: cached
                   ) {
                    return TransactionSigner.JustInTimeData(bitcoinUTXOs: rebound)
                }
                let fresh = try await UTXOService().fetchWalletUTXOs(
                    walletId: wallet.id,
                    chain: draft.chain,
                    preferredAddress: draft.fromAddress,
                    database: database
                )
                return TransactionSigner.JustInTimeData(
                    bitcoinUTXOs: try UTXOService.rebindSelected(
                        selected: draft.selectedUTXOs,
                        live: fresh
                    )
                )
            } catch let rpc as RPCError {
                throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
            } catch let signing as SigningError {
                throw signing
            } catch {
                throw SigningError.justInTimeRefreshFailed(error.localizedDescription)
            }
        case .ed25519:
            switch draft.chain {
            case .solana:  return try await refreshSolana(draft: draft)
            case .stellar: return try await refreshStellar(draft: draft)
            case .sui:     return try await refreshSui(draft: draft)
            default:       return TransactionSigner.JustInTimeData()
            }
        case .ripple:   return try await refreshXRP(draft: draft)
        case .tron:     return try await refreshTron(draft: draft)
        case .aptos:    return try await refreshAptos(draft: draft)
        case .near:     return try await refreshNear(draft: draft, wallet: wallet, passphrase: passphrase)
        case .polkadot: return try await refreshPolkadot(draft: draft)
        case .ton:      return try await refreshTON(draft: draft)
        }
    }

    // MARK: - 5. Outbox persistence + confirmation poll

    /// Write the pending `TransactionRecord` with retries (P2-001).
    /// On permanent failure, enqueue an orphan broadcast for the monitor.
    private func writePendingRecordWithRetry(
        txHash: String,
        draft: SendDraft,
        addressId: UUID
    ) async -> UUID? {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            if let id = writePendingRecord(txHash: txHash, draft: draft, addressId: addressId) {
                return id
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 50_000_000)
            }
        }
        // Durable recovery: monitor will re-upsert when it next runs.
        OrphanBroadcastQueue.enqueue(
            OrphanBroadcastQueue.Entry(
                txHash: txHash,
                chainRaw: draft.chain.rawValue,
                addressId: addressId,
                amountRaw: Self.plainAmountRaw(draft.totalAmount),
                feeRaw: Self.plainAmountRaw(draft.fee.estimatedTotalNative),
                tokenSymbol: draft.tokenSymbol ?? draft.chain.ticker,
                tokenContract: draft.tokenContract,
                counterparty: Self.pendingCounterparty(draft)
            )
        )
        DiagnosticsLogStore.shared.record(
            .error,
            category: "send-outbox",
            message: "Pending outbox write failed after broadcast; queued orphan for \(draft.chain.rawValue)",
            metadata: [
                "chain": draft.chain.rawValue,
                "txHashPrefix": String(txHash.prefix(16)),
                "queued": "orphan",
            ]
        )
        return nil
    }

    /// Write the pending `TransactionRecord` (outgoing) for this send so
    /// the UI shows it live.
    ///
    /// BUG-018: `addressId` must already be the exact `fromAddress` row
    /// resolved by `SendOutboxAddressResolver` — never a preferred fallback.
    /// P2-012: amount/fee raw use plain decimal strings (no scientific notation).
    private func writePendingRecord(
        txHash: String,
        draft: SendDraft,
        addressId: UUID
    ) -> UUID? {
        let recordId = UUID()
        let symbol = draft.tokenSymbol ?? draft.chain.ticker
        let amountRaw = Self.plainAmountRaw(draft.totalAmount)
        let feeRaw = Self.plainAmountRaw(draft.fee.estimatedTotalNative)
        let counterparty = Self.pendingCounterparty(draft)
        let repository = TransactionRepository(database: database)
        do {
            try repository.upsertTransaction(
                addressId: addressId,
                txHash: txHash,
                direction: .outgoing,
                amountRaw: amountRaw,
                tokenSymbol: symbol,
                tokenContract: draft.tokenContract,
                kind: nil,
                blockNumber: nil,
                occurredAt: Date(),
                status: .pending,
                counterparty: counterparty,
                feeRaw: feeRaw,
                id: recordId,
                save: true
            )
        } catch {
            return nil
        }
        return recordId
    }

    /// P2-012: plain digit string for history/fiat parse (never scientific).
    nonisolated static func plainAmountRaw(_ value: Decimal) -> String {
        ComposeDecimal.plainDecimalString(value)
    }

    /// P2-012: multi-recipient — join all counterparties, not only first.
    nonisolated static func pendingCounterparty(_ draft: SendDraft) -> String {
        let addresses = draft.recipients.map(\.address).filter { !$0.isEmpty }
        if addresses.isEmpty { return "" }
        if addresses.count == 1 { return addresses[0] }
        return addresses.joined(separator: ",")
    }

    private func applyOptimisticOutgoingState(walletId: UUID, draft: SendDraft) async {
        let txRepository = TransactionRepository(database: database)
        var changed = false

        if draft.isTokenSend, let tokenSymbol = draft.tokenSymbol {
            changed = ((try? txRepository.applyOptimisticOutgoingDebit(
                walletId: walletId,
                chain: draft.chain,
                tokenSymbol: tokenSymbol,
                tokenContract: draft.tokenContract,
                decimals: draft.effectiveDecimals,
                displayAmount: draft.totalAmount
            )) ?? false) || changed
        }

        let nativeDebit = draft.isTokenSend
            ? draft.fee.estimatedTotalNative
            : draft.totalAmount + draft.fee.estimatedTotalNative
        if nativeDebit > 0 {
            changed = ((try? txRepository.applyOptimisticOutgoingDebit(
                walletId: walletId,
                chain: draft.chain,
                tokenSymbol: draft.chain.ticker,
                tokenContract: nil,
                decimals: draft.chain.nativeDecimals,
                displayAmount: nativeDebit
            )) ?? false) || changed
        }

        if draft.chain.family == .bitcoin, let spent = draft.selectedUTXOs, !spent.isEmpty {
            do {
                try ChainStateRepository(database: database).removeUTXOs(
                    walletId: walletId,
                    chain: draft.chain,
                    utxos: spent
                )
                changed = true
            } catch {
                // Best effort: the pending transaction row remains the source
                // of truth if the local UTXO cache cleanup fails.
            }
        }

        guard changed else { return }
        let currencyCode = AppPreferenceStore.shared.string(
            CurrencyPreference.storageKey,
            default: CurrencyPreference.defaultCode
        )
        _ = try? ChainStateRepository(database: database).rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: [draft.chain],
            failedChains: [],
            interim: false
        )
    }

}
