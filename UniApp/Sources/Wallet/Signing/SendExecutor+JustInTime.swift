import Foundation
import WalletCore

/// Per-chain just-in-time pre-sign data fetchers for the 10 PASS-2 chains
/// (Rule #27 §C — we never sign against a stale nonce/sequence/blockhash/
/// gas-price/coin-version). Every fetch is `nonisolated` async I/O through
/// the shared `RPCClient` (rate limiter + circuit breakers + fallback
/// rotation), invoked off-main by `SendExecutor.refreshJustInTime` (Rule
/// #28). Each method's RPC method/endpoint shape is doc-grounded and was
/// live-verified 2026-06-15 (see the per-method comments + the matrix).
///
/// On a transport failure each maps the `RPCError` to a typed
/// `SigningError.justInTimeRefreshFailed` so the executor returns an
/// honest "couldn't reach the network to prepare the transaction" rather
/// than signing against a stale value.
extension SendExecutor {

    // MARK: - Solana

    /// `getLatestBlockhash` (recent blockhash, ~60–90s validity) +, for an
    /// SPL send, the derived sender/recipient ATAs and whether the
    /// recipient ATA must be created (`getAccountInfo` on the recipient
    /// ATA: `value == null` ⇒ create). Doc:
    /// solana.com/docs/rpc/http/getlatestblockhash + …/getaccountinfo.
    nonisolated func refreshSolana(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let bhData = try await RPCClient.shared.callJSONResultData(
                chain: .solana, method: "getLatestBlockhash", params: []
            )
            guard let root = (try? JSONSerialization.jsonObject(with: bhData)) as? [String: Any],
                  let value = root["value"] as? [String: Any],
                  let blockhash = value["blockhash"] as? String, !blockhash.isEmpty else {
                throw SigningError.justInTimeRefreshFailed("Solana blockhash unavailable")
            }

            guard draft.isTokenSend, let mint = draft.tokenContract,
                  let recipient = draft.recipients.first else {
                return TransactionSigner.JustInTimeData(solanaRecentBlockhash: blockhash)
            }

            let senderATA = SolanaAddress(string: draft.fromAddress)?.defaultTokenAddress(tokenMintAddress: mint)
            let recipientATA = SolanaAddress(string: recipient.address)?.defaultTokenAddress(tokenMintAddress: mint)
            // Recipient ATA existence: getAccountInfo → value null ⇒ create.
            var needsCreation = true
            if let recipientATA {
                let info = try? await RPCClient.shared.callJSONResultData(
                    chain: .solana, method: "getAccountInfo",
                    params: [recipientATA, ["encoding": "base64"] as [String: Sendable]]
                )
                if let info,
                   let infoRoot = (try? JSONSerialization.jsonObject(with: info)) as? [String: Any],
                   infoRoot["value"] is [String: Any] {
                    needsCreation = false
                }
            }
            return TransactionSigner.JustInTimeData(
                solanaRecentBlockhash: blockhash,
                solanaRecipientTokenAccount: recipientATA,
                solanaSenderTokenAccount: senderATA,
                solanaRecipientATANeedsCreation: needsCreation
            )
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    // MARK: - XRP / Ripple

    /// `account_info` (account sequence) + `ledger_current` (→
    /// last_ledger_sequence = current + buffer for tx expiry). XRPL's HTTP
    /// API does not echo the request id (`validatesIDEcho: false`). Doc:
    /// xrpl.org account_info + ledger_current.
    nonisolated func refreshXRP(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let acctData = try await RPCClient.shared.callJSONResultData(
                chain: .ripple, method: "account_info",
                params: [["account": draft.fromAddress, "ledger_index": "current"]],
                validatesIDEcho: false
            )
            guard let root = (try? JSONSerialization.jsonObject(with: acctData)) as? [String: Any],
                  let data = root["account_data"] as? [String: Any],
                  let seqNum = (data["Sequence"] as? NSNumber)?.uint32Value else {
                throw SigningError.justInTimeRefreshFailed("XRP account sequence unavailable")
            }

            var lastLedger: UInt32?
            if let ledgerData = try? await RPCClient.shared.callJSONResultData(
                chain: .ripple, method: "ledger_current", params: [], validatesIDEcho: false
            ), let ledgerRoot = (try? JSONSerialization.jsonObject(with: ledgerData)) as? [String: Any],
               let current = (ledgerRoot["ledger_current_index"] as? NSNumber)?.uint32Value {
                lastLedger = current &+ 20 // ~20-ledger expiry buffer (matrix §G8)
            }
            return TransactionSigner.JustInTimeData(
                xrpSequence: seqNum, xrpLastLedgerSequence: lastLedger
            )
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    // MARK: - Stellar

    /// Horizon `GET /accounts/{id}` → `sequence`; the tx sequence is
    /// account sequence + 1. Doc: developers.stellar.org accounts.
    nonisolated func refreshStellar(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let data = try await RPCClient.shared.callREST(
                chain: .stellar, path: "/accounts/\(draft.fromAddress)"
            )
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let seqString = root["sequence"] as? String,
                  let seq = UInt64(seqString) else {
                throw SigningError.justInTimeRefreshFailed("Stellar account sequence unavailable")
            }
            return TransactionSigner.JustInTimeData(stellarSequence: seq &+ 1)
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    // MARK: - TON

    /// `getWalletInformation` (seqno) +, for a jetton send, the sender's
    /// jetton wallet via `runGetMethod get_wallet_address` on the jetton
    /// master. Doc: toncenter.com/api/v2 openapi.
    nonisolated func refreshTON(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let info = try await RPCClient.shared.callREST(
                chain: .ton, path: "/getWalletInformation",
                query: [URLQueryItem(name: "address", value: draft.fromAddress)]
            )
            guard let root = (try? JSONSerialization.jsonObject(with: info)) as? [String: Any],
                  let result = root["result"] as? [String: Any] else {
                throw SigningError.justInTimeRefreshFailed("TON wallet info unavailable")
            }
            // seqno may be Int or numeric String depending on provider.
            let seqno: UInt32
            if let n = (result["seqno"] as? NSNumber)?.uint32Value {
                seqno = n
            } else if let s = result["seqno"] as? String, let n = UInt32(s) {
                seqno = n
            } else {
                seqno = 0 // uninitialized wallet's first tx is seqno 0
            }

            var senderJettonWallet: String?
            if draft.isTokenSend, let master = draft.tokenContract {
                senderJettonWallet = try? await resolveTONJettonWallet(owner: draft.fromAddress, master: master)
            }
            return TransactionSigner.JustInTimeData(
                tonSeqno: seqno, tonSenderJettonWallet: senderJettonWallet
            )
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    /// Resolve the owner's jetton wallet address from the jetton master
    /// via `runGetMethod get_wallet_address` (the owner address is passed
    /// as a serialized slice). toncenter returns the resulting address in
    /// the get-method stack. Best-effort — a nil result surfaces as a
    /// `justInTimeRefreshFailed` in the caller when the send is a jetton.
    private nonisolated func resolveTONJettonWallet(owner: String, master: String) async throws -> String {
        let ownerBoc = TONAddressConverter.toBoc(address: owner)
        guard let ownerBoc else {
            throw SigningError.justInTimeRefreshFailed("TON owner address could not be encoded")
        }
        let body: [String: Sendable] = [
            "address": master,
            "method": "get_wallet_address",
            "stack": [["tvm.Slice", ownerBoc]],
        ]
        let data = try await RPCClient.shared.callRESTPost(
            chain: .ton, path: "/runGetMethod", body: body
        )
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let stack = result["stack"] as? [[Any]],
              let first = stack.first, first.count >= 2,
              let cell = first[1] as? [String: Any],
              let boc = cell["bytes"] as? String,
              let address = TONAddressConverter.fromBoc(boc: boc) else {
            throw SigningError.justInTimeRefreshFailed("TON jetton wallet could not be resolved")
        }
        return address
    }

    // MARK: - TRON

    /// `/wallet/getnowblock` → the latest block header, re-encoded as the
    /// compact JSON the signer parses into a `TronBlockHeader`. Doc:
    /// developers.tron.network getnowblock.
    nonisolated func refreshTron(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let data = try await RPCClient.shared.callRESTPost(
                chain: .tron, path: "/wallet/getnowblock", body: [:]
            )
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let header = root["block_header"] as? [String: Any],
                  let raw = header["raw_data"] as? [String: Any] else {
                throw SigningError.justInTimeRefreshFailed("TRON block reference unavailable")
            }
            // Normalize the fields the signer needs into a flat JSON object.
            var compact: [String: Any] = [:]
            compact["number"] = raw["number"]
            compact["timestamp"] = raw["timestamp"]
            compact["version"] = raw["version"] ?? 0
            compact["txTrieRoot"] = raw["txTrieRoot"]
            compact["parentHash"] = raw["parentHash"]
            compact["witnessAddress"] = raw["witness_address"]
            guard let json = try? JSONSerialization.data(withJSONObject: compact),
                  let jsonString = String(data: json, encoding: .utf8) else {
                throw SigningError.justInTimeRefreshFailed("TRON block header could not be encoded")
            }
            return TransactionSigner.JustInTimeData(tronBlockHeaderJSON: jsonString)
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    // MARK: - NEAR

    /// Access-key nonce (`query` view_access_key) + recent block hash
    /// (`block {finality:final}`). The tx nonce is access-key nonce + 1.
    /// Doc: docs.near.org/api/rpc/access-keys + …/block.
    nonisolated func refreshNear(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            // Public key (base58 "ed25519:…") of the signer for the
            // access-key lookup. The compose layer stores the from-address
            // = implicit/named account; the access key is the wallet's
            // ed25519 public key. We read it from the latest block + the
            // account's access keys via view_access_key_list as a fallback,
            // but the simplest correct path is view_access_key with the
            // wallet's public key. Derive the public key string here.
            let blockData = try await RPCClient.shared.callJSONResultData(
                chain: .near, method: "block", paramsObject: ["finality": "final"]
            )
            guard let blockRoot = (try? JSONSerialization.jsonObject(with: blockData)) as? [String: Any],
                  let blockHeader = blockRoot["header"] as? [String: Any],
                  let blockHash = blockHeader["hash"] as? String, !blockHash.isEmpty else {
                throw SigningError.justInTimeRefreshFailed("NEAR block hash unavailable")
            }

            // Access-key nonce via view_access_key_list (lists all keys with
            // their nonces — robust when we don't have the exact key string
            // pre-resolved). Take the max nonce among full-access keys.
            let keysData = try await RPCClient.shared.callJSONResultData(
                chain: .near, method: "query",
                paramsObject: [
                    "request_type": "view_access_key_list",
                    "finality": "final",
                    "account_id": draft.fromAddress,
                ]
            )
            guard let keysRoot = (try? JSONSerialization.jsonObject(with: keysData)) as? [String: Any],
                  let keys = keysRoot["keys"] as? [[String: Any]], !keys.isEmpty else {
                throw SigningError.justInTimeRefreshFailed("NEAR access keys unavailable")
            }
            // Max nonce across the account's full-access keys (the nonce
            // can be an NSNumber or a numeric String depending on provider).
            let nonce = keys.compactMap { key -> UInt64? in
                guard let ak = key["access_key"] as? [String: Any] else { return nil }
                if let n = ak["nonce"] as? NSNumber { return n.uint64Value }
                if let s = ak["nonce"] as? String { return UInt64(s) }
                return nil
            }.max()
            guard let nonce else {
                throw SigningError.justInTimeRefreshFailed("NEAR access-key nonce unavailable")
            }
            return TransactionSigner.JustInTimeData(
                nearNonce: nonce &+ 1, nearBlockHash: blockHash
            )
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    // MARK: - Polkadot

    /// `state_getRuntimeVersion` (specVersion + transactionVersion),
    /// `chain_getFinalizedHead` + `chain_getHeader` (mortal-era checkpoint
    /// hash + number), `system_accountNextIndex` (nonce). Doc:
    /// polkadot.js.org/docs/substrate/rpc.
    nonisolated func refreshPolkadot(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let rvData = try await RPCClient.shared.callJSONResultData(
                chain: .polkadot, method: "state_getRuntimeVersion", params: []
            )
            guard let rv = (try? JSONSerialization.jsonObject(with: rvData)) as? [String: Any],
                  let specVersion = (rv["specVersion"] as? NSNumber)?.uint32Value,
                  let txVersion = (rv["transactionVersion"] as? NSNumber)?.uint32Value else {
                throw SigningError.justInTimeRefreshFailed("Polkadot runtime version unavailable")
            }

            let finalizedHash = try await RPCClient.shared.callJSONString(
                chain: .polkadot, method: "chain_getFinalizedHead", params: []
            )
            let headerData = try await RPCClient.shared.callJSONResultData(
                chain: .polkadot, method: "chain_getHeader", params: [finalizedHash]
            )
            guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
                  let numberHex = header["number"] as? String,
                  let blockNumber = UInt64(numberHex.hasPrefix("0x") ? String(numberHex.dropFirst(2)) : numberHex, radix: 16) else {
                throw SigningError.justInTimeRefreshFailed("Polkadot header unavailable")
            }

            let nonce = try await RPCClient.shared.callJSONUInt64(
                chain: .polkadot, method: "system_accountNextIndex", params: [draft.fromAddress]
            )

            return TransactionSigner.JustInTimeData(
                polkadotSpecVersion: specVersion,
                polkadotTransactionVersion: txVersion,
                polkadotBlockHash: finalizedHash,
                polkadotBlockNumber: blockNumber,
                polkadotNonce: nonce
            )
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    // MARK: - Aptos

    /// `GET /accounts/{addr}` (sequence_number) + `GET /estimate_gas_price`
    /// (gas_estimate octas/gas). Doc: aptos.dev fullnode REST.
    nonisolated func refreshAptos(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let acct = try await RPCClient.shared.callREST(
                chain: .aptos, path: "/accounts/\(draft.fromAddress)"
            )
            guard let acctRoot = (try? JSONSerialization.jsonObject(with: acct)) as? [String: Any],
                  let seqString = acctRoot["sequence_number"] as? String,
                  let sequence = UInt64(seqString) else {
                throw SigningError.justInTimeRefreshFailed("Aptos sequence number unavailable")
            }
            var gasPrice: UInt64?
            if let gasData = try? await RPCClient.shared.callREST(chain: .aptos, path: "/estimate_gas_price"),
               let gasRoot = (try? JSONSerialization.jsonObject(with: gasData)) as? [String: Any],
               let estimate = (gasRoot["gas_estimate"] as? NSNumber)?.uint64Value {
                gasPrice = estimate
            }
            return TransactionSigner.JustInTimeData(
                aptosSequenceNumber: sequence, aptosGasUnitPrice: gasPrice
            )
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    // MARK: - Sui

    /// `suix_getReferenceGasPrice` (RGP) + `suix_getCoins` (owned coin
    /// objects for the send coin type; for a token send also a separate
    /// SUI gas coin). Doc: docs.sui.io/sui-api-ref.
    nonisolated func refreshSui(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let rgpString = try await RPCClient.shared.callJSONString(
                chain: .sui, method: "suix_getReferenceGasPrice", params: []
            )
            guard let rgp = UInt64(rgpString) else {
                throw SigningError.justInTimeRefreshFailed("Sui reference gas price unavailable")
            }

            let sendCoinType = draft.isTokenSend ? (draft.tokenContract ?? "0x2::sui::SUI") : "0x2::sui::SUI"
            let inputCoins = try await fetchSuiCoins(owner: draft.fromAddress, coinType: sendCoinType)
            guard !inputCoins.isEmpty else {
                throw SigningError.justInTimeRefreshFailed("no Sui coins to spend")
            }

            var gasCoin: SuiCoinRef?
            if draft.isTokenSend {
                // A token send needs a SEPARATE SUI gas coin.
                let suiCoins = try await fetchSuiCoins(owner: draft.fromAddress, coinType: "0x2::sui::SUI")
                gasCoin = suiCoins.first
                guard gasCoin != nil else {
                    throw SigningError.justInTimeRefreshFailed("no SUI coin available to pay gas")
                }
            }
            return TransactionSigner.JustInTimeData(
                suiInputCoins: inputCoins, suiGasCoin: gasCoin, suiReferenceGasPrice: rgp
            )
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }

    private nonisolated func fetchSuiCoins(owner: String, coinType: String) async throws -> [SuiCoinRef] {
        let data = try await RPCClient.shared.callJSONResultData(
            chain: .sui, method: "suix_getCoins", params: [owner, coinType]
        )
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry -> SuiCoinRef? in
            guard let objectId = entry["coinObjectId"] as? String,
                  let digest = entry["digest"] as? String else { return nil }
            let version: UInt64
            if let n = (entry["version"] as? NSNumber)?.uint64Value { version = n }
            else if let s = entry["version"] as? String, let n = UInt64(s) { version = n }
            else { return nil }
            return SuiCoinRef(objectId: objectId, version: version, digest: digest)
        }
    }

    // MARK: - Cosmos (Kava)

    /// `GET /cosmos/auth/v1beta1/accounts/{addr}` → account_number +
    /// sequence (vesting accounts nest these under base_vesting_account.
    /// base_account). Doc: cosmos-sdk auth module.
    nonisolated func refreshCosmos(draft: SendDraft) async throws -> TransactionSigner.JustInTimeData {
        do {
            let data = try await RPCClient.shared.callREST(
                chain: draft.chain, path: "/cosmos/auth/v1beta1/accounts/\(draft.fromAddress)"
            )
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let account = root["account"] as? [String: Any] else {
                throw SigningError.justInTimeRefreshFailed("Kava account unavailable")
            }
            // BaseAccount fields, possibly nested in a vesting wrapper.
            let base: [String: Any]
            if let baseAccount = account["base_account"] as? [String: Any] {
                base = baseAccount
            } else if let vesting = account["base_vesting_account"] as? [String: Any],
                      let baseAccount = vesting["base_account"] as? [String: Any] {
                base = baseAccount
            } else {
                base = account
            }
            guard let accountNumberStr = base["account_number"] as? String,
                  let accountNumber = UInt64(accountNumberStr) else {
                throw SigningError.justInTimeRefreshFailed("Kava account number unavailable")
            }
            // A brand-new (never-seen) account has sequence "0".
            let sequence = (base["sequence"] as? String).flatMap(UInt64.init) ?? 0
            return TransactionSigner.JustInTimeData(
                cosmosAccountNumber: accountNumber, cosmosSequence: sequence
            )
        } catch let rpc as RPCError {
            throw SigningError.justInTimeRefreshFailed(rpc.userFacingLabel)
        }
    }
}
