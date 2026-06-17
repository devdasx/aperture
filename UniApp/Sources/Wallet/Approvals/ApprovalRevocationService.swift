import Foundation
import SwiftData

/// Revokes a single ERC-20 approval by signing + broadcasting an
/// `approve(spender, 0)` transaction — for real, returning the on-chain
/// tx hash. This is the EXACT pipeline `EVMDAppSigner.sendTransaction`
/// uses for a dApp's `eth_sendTransaction` (Rule #3 §B — compose the
/// proven path, write no new crypto, no new signing):
///
///   1. Custody guard — only mnemonic-backed wallets (`.created` /
///      `.importedMnemonic`) without a never-persisted BIP-39 passphrase
///      can sign. Watch-only / single-key wallets get an honest refusal,
///      never a fabricated hash (Rule #16).
///   2. Build `approve(spender, 0)` calldata via `SwapEVMABI`
///      (`approveSelector` 095ea7b3, 32-byte-padded spender + a 64-zero
///      amount word).
///   3. Fetch a fresh pending nonce + live gas price (`SwapAllowance`).
///      The gas LIMIT is a safe approve default — an `approve` is a
///      ~46k-gas write; 100k is comfortable and a wrong limit reverts
///      on-chain (refunding unused gas), never loses principal.
///   4. Sign off the main actor: `SigningKeyProvider.withPrivateKey`
///      derives + scopes the key, `SwapEVMSigner.sign` produces the
///      Type-0 (legacy) signed tx. Key material lives only inside the
///      closure (Rule #17).
///   5. Broadcast via `BroadcastService` (shared `RPCClient`).
///
/// The caller (the Connection & Approvals screen) gates this behind a
/// biometric check — it moves an on-chain transaction.
@MainActor
enum ApprovalRevocationService {

    /// Refusals + outcomes for a revoke attempt. The `userMessage`
    /// maps each to a truthful sentence the screen can render (Rule #16).
    enum RevokeError: Error, Sendable {
        /// No active wallet resolved.
        case noActiveWallet
        /// The wallet can't sign (watch-only / single-key import) — an
        /// honest refusal, never a fabricated revoke.
        case walletCannotSign
        /// The mnemonic is no longer on device (backed up) or the wallet
        /// is passphrase-protected (passphrase never persisted).
        case secretUnavailable
        /// The approval row's spender/contract failed ABI encoding.
        case invalidApproval
        /// A volatile pre-sign value (nonce / gas) couldn't be read.
        case preflightFailed(String)
        /// Signing failed locally (the tx never left the device).
        case signingFailed(String)
        /// The node DEFINITIVELY rejected the broadcast — the tx never
        /// relayed, so no approval changed. Carries the node's reason.
        case broadcastFailed(String)
        /// The broadcast outcome is UNKNOWN — the request left the device
        /// but no definitive accept/reject came back. The revoke MAY have
        /// landed; the UI must NOT claim it failed for sure (Rule #16).
        case broadcastAmbiguous(String)

        /// Honest, user-facing sentence for inline display.
        var userMessage: String {
            switch self {
            case .noActiveWallet:
                return "No wallet is selected to sign this revoke."
            case .walletCannotSign:
                return "This wallet can't sign — it's watch-only or a single-key import."
            case .secretUnavailable:
                return "Aperture can't sign on this device yet (the recovery phrase isn't available)."
            case .invalidApproval:
                return "This approval couldn't be prepared for revoke."
            case .preflightFailed(let reason):
                return "Couldn't reach the network to prepare the revoke: \(reason)."
            case .signingFailed(let reason):
                return "Signing failed — the revoke was not sent. \(reason)"
            case .broadcastFailed(let reason):
                return "The network rejected the revoke: \(reason)"
            case .broadcastAmbiguous:
                return "Aperture couldn't confirm whether the revoke went through. Check the explorer before trying again."
            }
        }
    }

    /// `approve(spender, amount)` amount word for a revoke: 64 zero
    /// nibbles (uint256 zero). `SwapEVMABI.approveCallData` defaults to
    /// the MAX_UINT256 grant; we override with zero to REVOKE.
    private static let zeroAmountHex32 = String(repeating: "0", count: 64)

    /// A safe gas limit for an ERC-20 `approve` write. The call itself is
    /// ~46k gas; 100k is a comfortable ceiling that never under-funds the
    /// intrinsic gas, and the unused portion is refunded on-chain.
    private static let approveGasLimit: UInt64 = 100_000

    /// Build, sign, and broadcast an `approve(spender, 0)` for `approval`
    /// using `wallet`'s key. Returns the REAL on-chain tx hash on success
    /// (never fabricated), or an honest `RevokeError` on refusal/failure.
    ///
    /// `wallet` is the `Sendable` snapshot (`WalletDescriptor`) of the
    /// active record — the caller resolves it on the main actor (SwiftData)
    /// and hands this value type across the off-main signing boundary,
    /// exactly as `EVMDAppSigner.sendTransaction` does with `WalletRecord`.
    static func revoke(
        approval: TokenApproval,
        wallet: WalletDescriptor,
        ownerAddress: String,
        client: RPCClient = .shared
    ) async -> Result<String, RevokeError> {
        // 1. Custody guard — copied from EVMDAppSigner.sendTransaction.
        switch wallet.kind {
        case .created, .importedMnemonic: break
        case .importedKey, .watchOnly:    return .failure(.walletCannotSign)
        }
        guard !wallet.hasPassphrase else { return .failure(.secretUnavailable) }

        let chain = approval.chain
        guard chain.family == .evm else { return .failure(.walletCannotSign) }

        // 2. Build approve(spender, 0) calldata.
        guard let callDataHex = SwapEVMABI.approveCallData(
            spender: approval.spender, amountHex32: zeroAmountHex32
        ), let calldata = dataFromHex(SwapEVMABI.strip0x(callDataHex)), !calldata.isEmpty else {
            return .failure(.invalidApproval)
        }

        // 3. Fresh pending nonce + live gas price (never sign against a
        //    stale value — Rule #27 §C).
        guard let nonce = await SwapAllowance.pendingNonce(address: ownerAddress, chain: chain) else {
            return .failure(.preflightFailed("couldn't read your account state"))
        }
        guard let gasPrice = await SwapAllowance.gasPriceWei(chain: chain) else {
            return .failure(.preflightFailed("couldn't fetch the network fee"))
        }

        // 4. Sign off the main actor. `valueHex` is "0x0" — an approve
        //    moves no native value; the token contract is the `to`.
        let tx = SwapEVMSigner.UnsignedTx(
            chain: chain,
            nonce: nonce,
            to: approval.tokenContract,
            valueHex: "0x0",
            data: calldata,
            gasLimit: approveGasLimit,
            gasPriceWei: gasPrice
        )

        let signed: SignedTransaction
        do {
            signed = try await Task.detached(priority: .userInitiated) {
                try SigningKeyProvider.withPrivateKey(
                    wallet: wallet, chain: chain, passphrase: nil, expectedAddress: ownerAddress
                ) { key in
                    try SwapEVMSigner.sign(tx, privateKey: key)
                }
            }.value
        } catch let error as SigningError {
            return .failure(.signingFailed(error.userMessage))
        } catch {
            return .failure(.signingFailed("Signing failed."))
        }

        // 5. Broadcast via the shared pipeline; return the real hash.
        //    `broadcast` is `throws(SigningError)`, so `error` is a
        //    `SigningError` in this catch. Preserve the rejected-vs-
        //    ambiguous distinction (Rule #16 — never claim a definitive
        //    failure when the outcome is actually unknown).
        do {
            let hash = try await BroadcastService(client: client).broadcast(signed, chain: chain)
            return .success(hash)
        } catch {
            switch error {
            case .broadcastFailed(let reason):
                return .failure(.broadcastFailed(reason))
            case .broadcastAmbiguous(let reason):
                return .failure(.broadcastAmbiguous(reason))
            default:
                return .failure(.broadcastFailed(error.userMessage))
            }
        }
    }

    // MARK: - Hex

    /// Decode an even-length hex string to bytes. `nil` for odd-length /
    /// non-hex input. Local copy (matches `EVMDAppSigner.data(fromHex:)`)
    /// so the service has no cross-file private dependency.
    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
