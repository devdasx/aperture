import Foundation
import SwiftData

/// The outbox orchestrator (Rule #27 §C): sign → broadcast → persist →
/// poll. The single API the Send UI calls AFTER it has authenticated the
/// user (PIN / Face ID gating is the UI's job — this executor assumes
/// authorization already happened and just performs the send).
///
/// **Pipeline (adapted from Stabro's `SmartTransactionExecutor`).**
/// 1. Resolve the wallet + its address row for the chain (main actor —
///    SwiftData), as `Sendable` values.
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
/// `@MainActor` API surface (it touches SwiftData on the main context for
/// the live-update write); the heavy sign/broadcast runs off-main via a
/// detached task and only `Sendable` values cross back.
@MainActor
struct SendExecutor {

    /// The successful outcome the UI shows + links to an explorer.
    struct SentTransaction: Sendable, Hashable {
        let txHash: String
        let chain: SupportedChain
        /// The pending DB row id (for the UI to observe its status).
        let recordId: UUID?
    }

    private let container: ModelContainer
    private let broadcaster: BroadcastService

    init(container: ModelContainer = ApertureDatabase.shared.container,
         broadcaster: BroadcastService = BroadcastService()) {
        self.container = container
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
        // 1. Resolve the wallet descriptor + the address row id (main
        //    actor — SwiftData). `WalletRecord` is not Sendable; we
        //    extract Sendable values.
        guard let resolved = resolveWallet(walletId: walletId, chain: draft.chain) else {
            return .failure(.noWallet)
        }
        let walletDescriptor = resolved.descriptor
        let addressId = resolved.addressId

        // 2. Just-in-time refresh (off-main) + 3. sign (off-main).
        let signed: SignedTransaction
        do {
            signed = try await signOffMain(
                draft: draft, wallet: walletDescriptor, passphrase: passphrase
            )
        } catch let error as SigningError {
            return .failure(error)
        } catch {
            return .failure(.signingFailed(error.localizedDescription))
        }

        // 4. Broadcast (off-main I/O).
        let txHash: String
        do {
            txHash = try await broadcaster.broadcast(signed, chain: draft.chain)
        } catch let error as SigningError {
            return .failure(error)
        } catch {
            return .failure(.broadcastFailed(error.localizedDescription))
        }

        // 5. Write the PENDING outbox row (live-update, Rule #25/#27),
        //    then poll the receipt to update it. The write is best-effort
        //    — a successful broadcast is the source of truth; a failed DB
        //    write must NOT make us report a non-send.
        let recordId = await writePendingRecord(
            txHash: txHash, draft: draft, addressId: addressId, signed: signed
        )

        // Fire-and-forget confirmation poll where a cheap, definitive
        // status RPC exists; otherwise the pending row is reconciled by
        // the next history scan (the Bitcoin-family pattern). Honest about
        // which chains poll vs reconcile:
        //   - EVM        → eth_getTransactionReceipt (definitive 0x1/0x0).
        //   - Solana     → getSignatureStatuses (confirmed/finalized).
        //   - Bitcoin / Stellar / Sui / XRP / TRON / Cosmos / Aptos / NEAR
        //     / Polkadot / TON → reconcile via the next history scan; a
        //     successful broadcast is the source of truth and the scanner
        //     flips the row when the tx lands (no fragile per-chain poll).
        switch draft.chain.family {
        case .evm:
            pollEVMReceipt(txHash: txHash, chain: draft.chain, addressId: addressId, draft: draft)
        case .ed25519 where draft.chain == .solana:
            pollSolanaStatus(txHash: txHash, addressId: addressId, draft: draft)
        default:
            break // reconciled by the next history scan (Rule: honest, no fake poll)
        }

        return .success(SentTransaction(txHash: txHash, chain: draft.chain, recordId: recordId))
    }

    // MARK: - 1. Wallet resolution (main actor)

    private struct ResolvedWallet { let descriptor: WalletDescriptor; let addressId: UUID? }

    private func resolveWallet(walletId: UUID, chain: SupportedChain) -> ResolvedWallet? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WalletRecord>(predicate: #Predicate { $0.id == walletId })
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first else { return nil }
        let chainRaw = chain.rawValue
        let addressId = record.addresses.first(where: { $0.chainRaw == chainRaw })?.id
        return ResolvedWallet(descriptor: WalletDescriptor(record: record), addressId: addressId)
    }

    // MARK: - 2+3. Just-in-time refresh + sign (off-main)

    private nonisolated func signOffMain(
        draft: SendDraft,
        wallet: WalletDescriptor,
        passphrase: String?
    ) async throws -> SignedTransaction {
        let jit = try await refreshJustInTime(draft: draft)
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
        draft: SendDraft
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
            // Re-fetch the address's CURRENT unspent set immediately before
            // signing (Rule #27 §C) — the draft's UTXO set was captured on
            // the amount screen and may be stale (a selected input could
            // have been spent since). wallet-core's planner selects + sizes
            // change over this fresh set. On a transport failure we refuse
            // honestly rather than sign against a stale set.
            do {
                let fresh = try await UTXOService().fetchUTXOs(
                    address: draft.fromAddress, chain: draft.chain
                )
                return TransactionSigner.JustInTimeData(bitcoinUTXOs: fresh)
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
        case .near:     return try await refreshNear(draft: draft)
        case .polkadot: return try await refreshPolkadot(draft: draft)
        case .ton:      return try await refreshTON(draft: draft)
        }
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
        let repository = TransactionRepository(modelContainer: container)
        do {
            try await repository.upsertTransaction(
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

    /// Poll `eth_getTransactionReceipt` a few times and flip the pending
    /// row to confirmed/failed when the receipt lands. Detached so it
    /// doesn't block the executor's return; the row updates live (Rule
    /// #25). `result == "0x1"` confirmed, `"0x0"` failed, null = still
    /// pending (the next history scan will also reconcile it).
    private func pollEVMReceipt(
        txHash: String,
        chain: SupportedChain,
        addressId: UUID?,
        draft: SendDraft
    ) {
        guard let addressId else { return }
        let container = self.container
        let symbol = draft.tokenSymbol ?? draft.chain.ticker
        let amountRaw = draft.totalAmount.description
        let counterparty = draft.recipients.first?.address ?? ""
        let feeRaw = draft.fee.estimatedTotalNative.description
        Task.detached(priority: .utility) {
            for attempt in 0..<10 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 4 : 6))
                guard let data = try? await RPCClient.shared.callJSONResultData(
                    chain: chain, method: "eth_getTransactionReceipt", params: [txHash]
                ) else { continue }
                guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    continue // null receipt → still pending; keep polling
                }
                let statusHex = dict["status"] as? String
                let blockHex = dict["blockNumber"] as? String
                let blockNumber = blockHex.flatMap { Int64(($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0), radix: 16) }
                let resolved: TransactionStatus?
                switch statusHex {
                case "0x1": resolved = .confirmed
                case "0x0": resolved = .failed
                default:    resolved = nil
                }
                guard let resolved else { continue }
                let repository = TransactionRepository(modelContainer: container)
                try? await repository.upsertTransaction(
                    addressId: addressId,
                    txHash: txHash,
                    direction: .outgoing,
                    amountRaw: amountRaw,
                    tokenSymbol: symbol,
                    tokenContract: draft.tokenContract,
                    kind: nil,
                    blockNumber: blockNumber,
                    occurredAt: Date(),
                    status: resolved,
                    counterparty: counterparty,
                    feeRaw: feeRaw,
                    save: true
                )
                return // terminal status written; stop polling
            }
        }
    }

    /// Poll Solana `getSignatureStatuses` a few times and flip the pending
    /// row to confirmed/failed. Doc: solana.com/docs/rpc/http/
    /// getsignaturestatuses — `value[0]` is null while unknown, then carries
    /// `confirmationStatus` (processed/confirmed/finalized) + `err` (null =
    /// success). `searchTransactionHistory: true` so a just-landed sig is
    /// found. Detached; the row updates live (Rule #25). If it never
    /// resolves in the window, the next history scan reconciles it.
    private func pollSolanaStatus(
        txHash: String,
        addressId: UUID?,
        draft: SendDraft
    ) {
        guard let addressId, !txHash.isEmpty else { return }
        let container = self.container
        let symbol = draft.tokenSymbol ?? draft.chain.ticker
        let amountRaw = draft.totalAmount.description
        let counterparty = draft.recipients.first?.address ?? ""
        let feeRaw = draft.fee.estimatedTotalNative.description
        let tokenContract = draft.tokenContract
        Task.detached(priority: .utility) {
            for attempt in 0..<8 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 3 : 5))
                let opts: [String: Sendable] = ["searchTransactionHistory": true]
                guard let data = try? await RPCClient.shared.callJSONResultData(
                    chain: .solana, method: "getSignatureStatuses",
                    params: [[txHash], opts]
                ) else { continue }
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let values = root["value"] as? [Any], let first = values.first else { continue }
                guard let status = first as? [String: Any] else { continue } // null → still pending
                let confirmation = status["confirmationStatus"] as? String ?? ""
                guard confirmation == "confirmed" || confirmation == "finalized" else { continue }
                let resolved: TransactionStatus = (status["err"] is NSNull || status["err"] == nil) ? .confirmed : .failed
                let slot = (status["slot"] as? NSNumber)?.int64Value
                let repository = TransactionRepository(modelContainer: container)
                try? await repository.upsertTransaction(
                    addressId: addressId,
                    txHash: txHash,
                    direction: .outgoing,
                    amountRaw: amountRaw,
                    tokenSymbol: symbol,
                    tokenContract: tokenContract,
                    kind: nil,
                    blockNumber: slot,
                    occurredAt: Date(),
                    status: resolved,
                    counterparty: counterparty,
                    feeRaw: feeRaw,
                    save: true
                )
                return // terminal status written; stop polling
            }
        }
    }
}
