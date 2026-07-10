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
        var effectiveDraft = draft
        if draft.chain.family == .evm {
            _ = try? EVMUnifiedAddressMigration.unifyWalletIfNeeded(
                walletId: walletId,
                passphrase: passphrase,
                database: database
            )
            if let live = liveAddress(walletId: walletId, chain: draft.chain),
               !live.isEmpty,
               live.caseInsensitiveCompare(draft.fromAddress) != .orderedSame {
                effectiveDraft = draft.replacingFromAddress(live)
            }
        }

        // 1. Resolve the wallet descriptor + the address row id.
        guard let resolved = resolveWallet(
            walletId: walletId,
            chain: effectiveDraft.chain,
            fromAddress: effectiveDraft.fromAddress
        ) else {
            return .failure(.noWallet)
        }
        let walletDescriptor = resolved.descriptor
        let addressId = resolved.addressId

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
        //    then poll the receipt to update it. The write is best-effort
        //    — a successful broadcast is the source of truth; a failed DB
        //    write must NOT make us report a non-send.
        let recordId = await writePendingRecord(
            txHash: txHash, draft: effectiveDraft, addressId: addressId, signed: signed
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

    private struct ResolvedWallet { let descriptor: WalletDescriptor; let addressId: UUID? }

    private func resolveWallet(walletId: UUID, chain: SupportedChain, fromAddress: String) -> ResolvedWallet? {
        do {
            return try database.read { db in
                guard let walletRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, kind_raw, has_passphrase
                    FROM wallets
                    WHERE id = ?
                    LIMIT 1
                    """,
                    arguments: [walletId.uuidString]
                ), let id = UUID(uuidString: walletRow["id"]) else {
                    return nil
                }
                let addressRaw = try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM wallet_addresses
                    WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                    LIMIT 1
                    """,
                    arguments: [walletId.uuidString, chain.rawValue, fromAddress]
                )
                let fallbackAddressRaw: String?
                if let addressRaw {
                    fallbackAddressRaw = addressRaw
                } else {
                    fallbackAddressRaw = try String.fetchOne(
                        db,
                        sql: """
                        SELECT id FROM wallet_addresses
                        WHERE wallet_id = ? AND chain_raw = ?
                        ORDER BY is_receive_preferred DESC
                        LIMIT 1
                        """,
                        arguments: [walletId.uuidString, chain.rawValue]
                    )
                }
                return ResolvedWallet(
                    descriptor: WalletDescriptor(
                        id: id,
                        kind: WalletKind(rawValue: walletRow["kind_raw"]) ?? .watchOnly,
                        hasPassphrase: (walletRow["has_passphrase"] as Int) != 0
                    ),
                    addressId: fallbackAddressRaw.flatMap(UUID.init(uuidString:))
                )
            }
        } catch {
            return nil
        }
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
    /// + gas; Sui coins + RGP; Cosmos account number + sequence; Stellar
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
            // Prefer the wallet-level UTXO cache from the latest scanner
            // pass. Bitcoin balances are aggregated across all persisted
            // receive/change paths, but signing must keep the exact selected
            // outpoints from compose after refreshing their current spendability.
            do {
                let cached = try ChainStateRepository(database: database)
                    .utxos(walletId: wallet.id, chain: draft.chain)
                if !cached.isEmpty {
                    return TransactionSigner.JustInTimeData(
                        bitcoinUTXOs: try currentSelectedBitcoinUTXOs(cached, draft: draft)
                    )
                }
                let fresh = try await UTXOService().fetchUTXOs(
                    address: draft.fromAddress, chain: draft.chain
                )
                return TransactionSigner.JustInTimeData(
                    bitcoinUTXOs: try currentSelectedBitcoinUTXOs(fresh, draft: draft)
                )
            } catch let rpc as RPCError {
                throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
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
        case .cosmos:   return try await refreshCosmos(draft: draft)
        case .aptos:    return try await refreshAptos(draft: draft)
        case .near:     return try await refreshNear(draft: draft, wallet: wallet, passphrase: passphrase)
        case .polkadot: return try await refreshPolkadot(draft: draft)
        case .ton:      return try await refreshTON(draft: draft)
        }
    }

    private nonisolated func currentSelectedBitcoinUTXOs(
        _ current: [SelectedUTXO],
        draft: SendDraft
    ) throws -> [SelectedUTXO] {
        guard let selected = draft.selectedUTXOs, !selected.isEmpty else {
            return current
        }
        var byOutpoint: [String: SelectedUTXO] = [:]
        for utxo in current {
            byOutpoint[utxo.id] = utxo
        }
        var refreshed: [SelectedUTXO] = []
        refreshed.reserveCapacity(selected.count)
        for utxo in selected {
            guard let current = byOutpoint[utxo.id] else {
                throw SigningError.justInTimeRefreshFailed(
                    "One or more selected Bitcoin inputs are no longer spendable"
                )
            }
            refreshed.append(current)
        }
        return refreshed
    }

    // MARK: - 5. Outbox persistence + confirmation poll

    /// Write the pending `TransactionRecord` (outgoing) for this send so
    /// the UI shows it live. Best-effort — returns the row id or nil.
    private func writePendingRecord(
        txHash: String,
        draft: SendDraft,
        addressId: UUID?,
        signed: SignedTransaction
    ) async -> UUID? {
        guard let addressId else { return nil }
        let recordId = UUID()
        let symbol = draft.tokenSymbol ?? draft.chain.ticker
        let amountRaw = draft.totalAmount.description
        let counterparty = draft.recipients.first?.address ?? ""
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
                feeRaw: draft.fee.estimatedTotalNative.description,
                id: recordId,
                save: true
            )
        } catch {
            return nil
        }
        return recordId
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
