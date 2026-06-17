import Foundation
import SwiftData

/// Signs + broadcasts a real swap from an approved `SwapReviewSummary`.
/// The swap-side analog of `SendExecutor` (same outbox discipline,
/// Rule #27 §C): resolve wallet → just-in-time pre-sign reads → sign
/// off-main → broadcast → confirm → auto-add the received token.
///
/// **The UI authenticates first.** Like `SendExecutor`, this assumes the
/// PIN / Face-ID gate already passed — it just performs the swap, calling
/// `onPhase` so the Review screen can show approving / signing /
/// broadcasting / confirming.
///
/// **EVM (Li.Fi) — the proven order (ported from Stabro `SwapEngine`):**
/// 1. If the `from` token is an ERC-20 and a spender is set, read
///    `allowance(owner, spender)`; if it's below the swap amount, sign +
///    broadcast `approve(spender, MAX)` and WAIT for its receipt (the swap
///    calldata reverts without allowance).
/// 2. Sign the Li.Fi `transactionRequest` (router `to`, calldata `data`,
///    native `value`) with a fresh pending nonce + Li.Fi gas (+20% buffer);
///    the router was already allowlist-verified at quote-build
///    (`SwapRouterAllowlist`).
/// 3. Broadcast `eth_sendRawTransaction`; poll the receipt; on success
///    auto-add the received token (`SwapTokenPersistence`).
///
/// The key is derived inside `SigningKeyProvider.withPrivateKey` (scoped,
/// key↔address parity) — twice for a token swap (approve, then swap), so
/// key material never outlives a single sign.
@MainActor
struct SwapExecutor {

    /// Progress the Review UI reflects (Rule #25 live feedback).
    enum Phase: Sendable, Equatable {
        case preparing, checkingApproval, approving, confirmingApproval
        case signing, broadcasting, confirming
    }

    /// Broadcast succeeded — the tx is on-chain. `confirmed` is the receipt
    /// verdict: `true` confirmed, `false` reverted on-chain, `nil` not yet
    /// confirmed within the poll window (still pending). Honest by
    /// construction (Rule #16) — a broadcast is never reported as a
    /// confirmed swap until the receipt says so.
    struct Executed: Sendable, Hashable {
        let txHash: String
        let chain: SupportedChain
        let confirmed: Bool?
    }

    enum ExecError: Error, Sendable, Equatable {
        case quoteExpired
        case noWallet
        case missingExecutionData
        case swapBuildFailed
        case feeUnavailable
        case nonceUnavailable
        case approvalReverted
        case approvalTimeout
        case signingFailed(String)
        case broadcastFailed(String)
        case broadcastAmbiguous(String)
        case unsupported(String)

        var message: String {
            switch self {
            case .quoteExpired:
                return "This quote expired. Go back and refresh it before swapping."
            case .noWallet:
                return "Couldn't find a wallet to sign this swap."
            case .missingExecutionData:
                return "This quote can't be executed — its transaction data is missing. Refresh and try again."
            case .swapBuildFailed:
                return "Couldn't build the swap transaction. The quote may have expired — go back and refresh it."
            case .feeUnavailable:
                return "Couldn't fetch the network fee right now. Try again in a moment."
            case .nonceUnavailable:
                return "Couldn't read your account state to sign. Try again in a moment."
            case .approvalReverted:
                return "The token approval failed on-chain. Nothing was swapped."
            case .approvalTimeout:
                return "Your approval is still pending on-chain after several minutes — the network may be congested. Nothing was swapped and your funds are safe; the approval will still land, then you can swap again."
            case .signingFailed(let detail):
                return detail
            case .broadcastFailed(let detail):
                return detail
            case .broadcastAmbiguous(let detail):
                return detail
            case .unsupported(let detail):
                return detail
            }
        }
    }

    private let container: ModelContainer
    private let broadcaster: BroadcastService

    init(container: ModelContainer = ApertureDatabase.shared.container,
         broadcaster: BroadcastService = BroadcastService()) {
        self.container = container
        self.broadcaster = broadcaster
    }

    // MARK: - Entry

    func execute(
        summary: SwapReviewSummary,
        walletId: UUID,
        passphrase: String? = nil,
        onPhase: @MainActor (Phase) -> Void
    ) async -> Result<Executed, ExecError> {
        let quote = summary.quote
        guard !quote.isExpired else { return .failure(.quoteExpired) }
        switch quote.provider {
        case .lifi, .kyberswap, .openocean:
            // Every EVM aggregator signs the same evmTx (to/data/value) +
            // ERC-20 approval path; the producing client already gated the
            // router/spender against SwapRouterAllowlist.
            return await executeEVM(quote: quote, walletId: walletId, passphrase: passphrase, onPhase: onPhase)
        case .jupiter:
            return await executeSolana(quote: quote, walletId: walletId, passphrase: passphrase, onPhase: onPhase)
        }
    }

    // MARK: - Solana (Jupiter)

    private func executeSolana(
        quote: SwapQuote,
        walletId: UUID,
        passphrase: String?,
        onPhase: @MainActor (Phase) -> Void
    ) async -> Result<Executed, ExecError> {
        onPhase(.preparing)
        let chain = SupportedChain.solana
        guard let solanaTx = quote.solanaTx else { return .failure(.missingExecutionData) }
        guard let resolved = resolveWallet(walletId: walletId, chain: chain) else {
            return .failure(.noWallet)
        }
        let wallet = resolved.descriptor
        let fromAddress = resolved.address

        // Build the signable VersionedTransaction NOW (post-auth) so its
        // embedded blockhash is fresh when we sign + broadcast immediately.
        onPhase(.signing)
        guard let base64Tx = await SwapQuoteService.shared.buildSolanaSwap(
            quoteResponseJSON: solanaTx.quoteResponseJSON, userPublicKey: fromAddress
        ) else {
            return .failure(.swapBuildFailed)
        }

        let signedBase64: String
        do {
            signedBase64 = try await Task.detached(priority: .userInitiated) {
                try SigningKeyProvider.withPrivateKey(
                    wallet: wallet, chain: chain, passphrase: passphrase, expectedAddress: fromAddress
                ) { key in
                    try SwapSolanaSigner.signVersioned(base64: base64Tx, privateKey: key)
                }
            }.value
        } catch let error as SigningError {
            return .failure(.signingFailed(error.userMessage))
        } catch {
            return .failure(.signingFailed(error.localizedDescription))
        }

        // Broadcast via the shared Solana sendTransaction path.
        onPhase(.broadcasting)
        guard let rawData = Data(base64Encoded: signedBase64) else {
            return .failure(.signingFailed("signed transaction isn't valid base64"))
        }
        let signed = SignedTransaction(rawData: rawData, rawHex: signedBase64, txHash: "")
        let signature: String
        do {
            signature = try await broadcaster.broadcast(signed, chain: chain)
        } catch {
            // `broadcast` is typed `throws(SigningError)`, so `error` is a
            // SigningError; `mapBroadcast` preserves `.broadcastAmbiguous`, so
            // the unknown-outcome handling is intact (Rule #16).
            return .failure(mapBroadcast(error))
        }

        // Confirm + auto-add the received token on success.
        onPhase(.confirming)
        let confirmed = await awaitSolanaConfirm(signature: signature)
        if confirmed == true {
            await SwapTokenPersistence.persistIfNeeded(quote.toToken, container: container)
        }
        return .success(Executed(txHash: signature, chain: chain, confirmed: confirmed))
    }

    /// Poll `getSignatureStatuses` until the swap signature confirms.
    /// `true` confirmed (err == null), `false` failed (err != null), `nil`
    /// not resolved within the window. Mirrors `SendExecutor.pollSolanaStatus`.
    private func awaitSolanaConfirm(
        signature: String, attempts: Int = 12, delaySeconds: UInt64 = 4
    ) async -> Bool? {
        guard !signature.isEmpty else { return nil }
        for _ in 0..<attempts {
            try? await Task.sleep(for: .seconds(delaySeconds))
            let opts: [String: Sendable] = ["searchTransactionHistory": true]
            guard let data = try? await RPCClient.shared.callJSONResultData(
                chain: .solana, method: "getSignatureStatuses", params: [[signature], opts]
            ) else { continue }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let values = root["value"] as? [Any], let first = values.first else { continue }
            guard let status = first as? [String: Any] else { continue } // null → still pending
            let confirmation = status["confirmationStatus"] as? String ?? ""
            guard confirmation == "confirmed" || confirmation == "finalized" else { continue }
            return status["err"] is NSNull || status["err"] == nil
        }
        return nil
    }

    // MARK: - EVM (Li.Fi)

    private func executeEVM(
        quote: SwapQuote,
        walletId: UUID,
        passphrase: String?,
        onPhase: @MainActor (Phase) -> Void
    ) async -> Result<Executed, ExecError> {
        onPhase(.preparing)
        let chain = quote.fromToken.chain
        guard let evmTx = quote.evmTx else { return .failure(.missingExecutionData) }
        guard let resolved = resolveWallet(walletId: walletId, chain: chain) else {
            return .failure(.noWallet)
        }
        let wallet = resolved.descriptor
        let fromAddress = resolved.address

        // 1. ERC-20 approval (skip for a native-coin input). Track the
        //    approve nonce so the swap nonce can't collide with it.
        var approveNonce: UInt64?
        if !quote.fromToken.isNative, let spender = quote.approvalAddress {
            onPhase(.checkingApproval)
            let tokenContract = quote.fromToken.address
            let allowanceHex = await SwapAllowance.read(
                token: tokenContract, owner: fromAddress, spender: spender, chain: chain
            )
            // An unparseable amount → require MAX (32 bytes of 0xff) so an
            // unknown amount truly forces a fresh approve, never skips it.
            let needed = SigningNumeric.bigEndianData(fromBaseUnitsString: quote.fromAmountRaw)
                ?? Data(repeating: 0xff, count: 32)
            let sufficient = allowanceHex.map { SwapEVMABI.isAllowance($0, atLeast: needed) } ?? false
            if !sufficient {
                switch await sendApproval(
                    spender: spender, tokenContract: tokenContract, chain: chain,
                    wallet: wallet, fromAddress: fromAddress, passphrase: passphrase, onPhase: onPhase
                ) {
                case .success(let usedNonce): approveNonce = usedNonce
                case .failure(let failure): return .failure(failure)
                }
            }
        }

        // 2. Sign the swap tx (fresh nonce + Li.Fi gas + 20% buffer). After a
        //    just-mined approve the swap nonce MUST be approveNonce+1 — guard
        //    against a stale "pending" read from a rotated RPC endpoint.
        onPhase(.signing)
        guard let pending = await SwapAllowance.pendingNonce(address: fromAddress, chain: chain) else {
            return .failure(.nonceUnavailable)
        }
        let nonce = approveNonce.map { max(pending, $0 + 1) } ?? pending
        let gasPrice: UInt64
        if let liFiPrice = evmTx.gasPrice.flatMap(SwapEVMABI.quantityToUInt64) {
            gasPrice = liFiPrice
        } else if let live = await SwapAllowance.gasPriceWei(chain: chain) {
            gasPrice = live
        } else {
            return .failure(.feeUnavailable)
        }
        // A provider-suggested gasLimit of 0 (or unparseable) must fall back to
        // the safe ceiling — `flatMap` so a parsed `0` becomes `nil` and the
        // `?? 800_000` fires (a 0 gasLimit signs an `intrinsic gas too low`
        // revert AFTER a paid approval — wasted gas, broken swap).
        let gasLimit = evmTx.gasLimit
            .flatMap(SwapEVMABI.quantityToUInt64)
            .flatMap { $0 > 0 ? $0 + $0 / 5 : nil } ?? 800_000  // suggestion + 20%, else a safe ceiling

        // A swap MUST carry router calldata. An empty/garbled payload would
        // sign a bare value-send INTO the router — for a native-coin input
        // that's the full swap amount, lost. Refuse rather than the silent
        // `?? Data()` fallback (Rule #16 — never sign a fund-losing tx).
        guard let calldata = SigningNumeric.hexToData(SwapEVMABI.strip0x(evmTx.data)),
              !calldata.isEmpty else {
            return .failure(.missingExecutionData)
        }

        // Funds-safety (Rule #16): the allowlist gates WHERE funds go; this
        // gates HOW MUCH native rides along. An ERC-20-in swap MUST attach
        // zero native value (the tokens move via approve + transferFrom, never
        // msg.value). A nonzero `value` on an ERC-20-in tx — a buggy, stale, or
        // tampered keyless-provider response — would forward the user's native
        // coin into the router ON TOP of the swap, a silent loss the allowlist
        // can't catch. Refuse it. (Native-in value is bounded in each client
        // against the reviewed amount.)
        if !quote.fromToken.isNative,
           !SwapEVMABI.strip0x(evmTx.value).drop(while: { $0 == "0" }).isEmpty {
            return .failure(.missingExecutionData)
        }
        let swapTx = SwapEVMSigner.UnsignedTx(
            chain: chain, nonce: nonce, to: evmTx.to, valueHex: evmTx.value,
            data: calldata, gasLimit: gasLimit, gasPriceWei: gasPrice
        )
        let signed: SignedTransaction
        do {
            signed = try await signDetached(tx: swapTx, wallet: wallet, chain: chain, fromAddress: fromAddress, passphrase: passphrase)
        } catch let error as SigningError {
            return .failure(.signingFailed(error.userMessage))
        } catch {
            return .failure(.signingFailed(error.localizedDescription))
        }

        // 3. Broadcast.
        onPhase(.broadcasting)
        let txHash: String
        do {
            txHash = try await broadcaster.broadcast(signed, chain: chain)
        } catch {
            // `broadcast` is typed `throws(SigningError)`, so `error` is a
            // SigningError; `mapBroadcast` preserves `.broadcastAmbiguous`, so
            // the unknown-outcome handling is intact (Rule #16).
            return .failure(mapBroadcast(error))
        }

        // 4. Confirm + auto-add the received token. For a SAME-CHAIN swap a
        //    source receipt of 0x1 means the swap is DONE. For a cross-chain
        //    BRIDGE the source 0x1 only confirms the deposit — the destination
        //    leg lands later — so report it as 'submitted/bridging' (confirmed
        //    = nil), not done, honestly (Rule #16).
        onPhase(.confirming)
        let isBridge = quote.fromToken.chain != quote.toToken.chain
        let sourceConfirmed = await SwapAllowance.awaitReceipt(txHash: txHash, chain: chain, attempts: 10, delaySeconds: 5)
        if sourceConfirmed == true {
            await SwapTokenPersistence.persistIfNeeded(quote.toToken, container: container)
        }
        let reported: Bool? = (isBridge && sourceConfirmed == true) ? nil : sourceConfirmed
        return .success(Executed(txHash: txHash, chain: chain, confirmed: reported))
    }

    /// Build, sign, broadcast `approve(spender, MAX)` and wait for its
    /// receipt. On success returns the NONCE the approve used (so the swap
    /// nonce can be guarded to `approveNonce + 1`); otherwise the failure.
    private func sendApproval(
        spender: String,
        tokenContract: String,
        chain: SupportedChain,
        wallet: WalletDescriptor,
        fromAddress: String,
        passphrase: String?,
        onPhase: @MainActor (Phase) -> Void
    ) async -> Result<UInt64, ExecError> {
        onPhase(.approving)
        guard let nonce = await SwapAllowance.pendingNonce(address: fromAddress, chain: chain) else {
            return .failure(.nonceUnavailable)
        }
        guard let gasPrice = await SwapAllowance.gasPriceWei(chain: chain) else {
            return .failure(.feeUnavailable)
        }
        guard let calldataHex = SwapEVMABI.approveCallData(spender: spender),
              let calldata = SigningNumeric.hexToData(SwapEVMABI.strip0x(calldataHex)) else {
            return .failure(.missingExecutionData)
        }
        let approveTx = SwapEVMSigner.UnsignedTx(
            chain: chain, nonce: nonce, to: tokenContract, valueHex: "0x0",
            data: calldata, gasLimit: 70_000, gasPriceWei: gasPrice
        )
        let signed: SignedTransaction
        do {
            signed = try await signDetached(tx: approveTx, wallet: wallet, chain: chain, fromAddress: fromAddress, passphrase: passphrase)
        } catch let error as SigningError {
            return .failure(.signingFailed(error.userMessage))
        } catch {
            return .failure(.signingFailed(error.localizedDescription))
        }
        let approveHash: String
        do {
            approveHash = try await broadcaster.broadcast(signed, chain: chain)
        } catch {
            // `broadcast` is typed `throws(SigningError)`, so `error` is a
            // SigningError; `mapBroadcast` preserves `.broadcastAmbiguous`, so
            // the unknown-outcome handling is intact (Rule #16).
            return .failure(mapBroadcast(error))
        }
        onPhase(.confirmingApproval)
        // Wait PATIENTLY for the approval (2026-06-17). The old 60s window
        // (12 × 5s) routinely tripped on a congested chain and hard-failed an
        // approval that was simply still pending — and would have confirmed.
        // The swap now runs in `SwapBackgroundManager`, so the user is never
        // blocked behind this wait; they can leave the screen and watch the
        // home banner. ~7.5 min covers virtually every real slow inclusion.
        switch await SwapAllowance.awaitReceipt(txHash: approveHash, chain: chain, attempts: 90, delaySeconds: 5) {
        case .some(true): return .success(nonce)
        case .some(false): return .failure(.approvalReverted)
        case .none: return .failure(.approvalTimeout)
        }
    }

    // MARK: - Helpers

    private struct Resolved { let descriptor: WalletDescriptor; let address: String }

    private func resolveWallet(walletId: UUID, chain: SupportedChain) -> Resolved? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WalletRecord>(predicate: #Predicate { $0.id == walletId })
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first else { return nil }
        let chainRaw = chain.rawValue
        guard let addr = record.addresses.first(where: { $0.chainRaw == chainRaw && !$0.address.isEmpty }) else {
            return nil
        }
        return Resolved(descriptor: WalletDescriptor(record: record), address: addr.address)
    }

    /// Derive the key + sign OFF-MAIN (Rule #28); the key is scoped to the
    /// `withPrivateKey` closure and drops at return.
    private nonisolated func signDetached(
        tx: SwapEVMSigner.UnsignedTx,
        wallet: WalletDescriptor,
        chain: SupportedChain,
        fromAddress: String,
        passphrase: String?
    ) async throws -> SignedTransaction {
        try await Task.detached(priority: .userInitiated) {
            try SigningKeyProvider.withPrivateKey(
                wallet: wallet, chain: chain, passphrase: passphrase, expectedAddress: fromAddress
            ) { key in
                try SwapEVMSigner.sign(tx, privateKey: key)
            }
        }.value
    }

    private func mapBroadcast(_ error: SigningError) -> ExecError {
        switch error {
        case .broadcastAmbiguous(let detail): return .broadcastAmbiguous(detail)
        default: return .broadcastFailed(error.userMessage)
        }
    }
}
