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
            case .feeUnavailable:
                return "Couldn't fetch the network fee right now. Try again in a moment."
            case .nonceUnavailable:
                return "Couldn't read your account state to sign. Try again in a moment."
            case .approvalReverted:
                return "The token approval failed on-chain. Nothing was swapped."
            case .approvalTimeout:
                return "The token approval is taking longer than expected. Check the approval, then try the swap again."
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
        case .lifi:
            return await executeEVM(quote: quote, walletId: walletId, passphrase: passphrase, onPhase: onPhase)
        case .jupiter:
            // Solana execution (Jupiter /swap → sign VersionedTransaction →
            // sendTransaction) lands in the immediate next step. Honest
            // refusal, never a fabricated success (Rule #16).
            return .failure(.unsupported("Solana swap execution is landing in the next update — EVM swaps work now."))
        }
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

        // 1. ERC-20 approval (skip for a native-coin input).
        if !quote.fromToken.isNative, let spender = quote.approvalAddress {
            onPhase(.checkingApproval)
            let tokenContract = quote.fromToken.address
            let allowanceHex = await SwapAllowance.read(
                token: tokenContract, owner: fromAddress, spender: spender, chain: chain
            )
            let needed = SigningNumeric.bigEndianData(fromBaseUnitsString: quote.fromAmountRaw) ?? Data([0xff])
            let sufficient = allowanceHex.map { SwapEVMABI.isAllowance($0, atLeast: needed) } ?? false
            if !sufficient {
                if let failure = await sendApproval(
                    spender: spender, tokenContract: tokenContract, chain: chain,
                    wallet: wallet, fromAddress: fromAddress, passphrase: passphrase, onPhase: onPhase
                ) {
                    return .failure(failure)
                }
            }
        }

        // 2. Sign the swap tx (fresh nonce + Li.Fi gas + 20% buffer).
        onPhase(.signing)
        guard let nonce = await SwapAllowance.pendingNonce(address: fromAddress, chain: chain) else {
            return .failure(.nonceUnavailable)
        }
        let gasPrice: UInt64
        if let liFiPrice = evmTx.gasPrice.flatMap(SwapEVMABI.quantityToUInt64) {
            gasPrice = liFiPrice
        } else if let live = await SwapAllowance.gasPriceWei(chain: chain) {
            gasPrice = live
        } else {
            return .failure(.feeUnavailable)
        }
        let gasLimit = evmTx.gasLimit
            .flatMap(SwapEVMABI.quantityToUInt64)
            .map { $0 + $0 / 5 } ?? 800_000  // Li.Fi suggestion + 20%, else a safe ceiling

        let swapTx = SwapEVMSigner.UnsignedTx(
            chain: chain, nonce: nonce, to: evmTx.to, valueHex: evmTx.value,
            data: SigningNumeric.hexToData(SwapEVMABI.strip0x(evmTx.data)) ?? Data(),
            gasLimit: gasLimit, gasPriceWei: gasPrice
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
        } catch let error as SigningError {
            return .failure(mapBroadcast(error))
        } catch {
            return .failure(.broadcastAmbiguous(error.localizedDescription))
        }

        // 4. Confirm + auto-add the received token on success.
        onPhase(.confirming)
        let confirmed = await SwapAllowance.awaitReceipt(txHash: txHash, chain: chain, attempts: 10, delaySeconds: 5)
        if confirmed == true {
            await SwapTokenPersistence.persistIfNeeded(quote.toToken, container: container)
        }
        return .success(Executed(txHash: txHash, chain: chain, confirmed: confirmed))
    }

    /// Build, sign, broadcast `approve(spender, MAX)` and wait for its
    /// receipt. Returns `nil` on success, or the failure to surface.
    private func sendApproval(
        spender: String,
        tokenContract: String,
        chain: SupportedChain,
        wallet: WalletDescriptor,
        fromAddress: String,
        passphrase: String?,
        onPhase: @MainActor (Phase) -> Void
    ) async -> ExecError? {
        onPhase(.approving)
        guard let nonce = await SwapAllowance.pendingNonce(address: fromAddress, chain: chain) else {
            return .nonceUnavailable
        }
        guard let gasPrice = await SwapAllowance.gasPriceWei(chain: chain) else {
            return .feeUnavailable
        }
        guard let calldataHex = SwapEVMABI.approveCallData(spender: spender),
              let calldata = SigningNumeric.hexToData(SwapEVMABI.strip0x(calldataHex)) else {
            return .missingExecutionData
        }
        let approveTx = SwapEVMSigner.UnsignedTx(
            chain: chain, nonce: nonce, to: tokenContract, valueHex: "0x0",
            data: calldata, gasLimit: 70_000, gasPriceWei: gasPrice
        )
        let signed: SignedTransaction
        do {
            signed = try await signDetached(tx: approveTx, wallet: wallet, chain: chain, fromAddress: fromAddress, passphrase: passphrase)
        } catch let error as SigningError {
            return .signingFailed(error.userMessage)
        } catch {
            return .signingFailed(error.localizedDescription)
        }
        let approveHash: String
        do {
            approveHash = try await broadcaster.broadcast(signed, chain: chain)
        } catch let error as SigningError {
            return mapBroadcast(error)
        } catch {
            return .broadcastAmbiguous(error.localizedDescription)
        }
        onPhase(.confirmingApproval)
        switch await SwapAllowance.awaitReceipt(txHash: approveHash, chain: chain) {
        case .some(true): return nil
        case .some(false): return .approvalReverted
        case .none: return .approvalTimeout
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
