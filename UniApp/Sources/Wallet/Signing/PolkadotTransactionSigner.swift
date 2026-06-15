import Foundation
import WalletCore

/// Builds + signs Polkadot relay-chain transactions (native DOT
/// `balances.transferKeepAlive`, with a mortal era + optional tip) from
/// `SendDraft` + just-in-time data, using wallet-core's native Polkadot
/// signer — endorsed by the matrix (§G11) for the relay chain.
///
/// **wallet-core SigningInput (Polkadot.proto, WalletCore 4.6.13 — field
/// names verified against the pinned `arm64.swiftinterface` + the
/// upstream `PolkadotTests.testSignTransfer` fixture):**
/// `genesisHash`, `blockHash` (mortal-era checkpoint, JIT), `nonce`
/// (`system_accountNextIndex`, JIT), `specVersion` + `transactionVersion`
/// (`state_getRuntimeVersion`, JIT — never hardcoded), `network`
/// (ss58Prefix = 0), `multiAddress` (true for the modern MultiAddress
/// runtime), `era = PolkadotEra{blockNumber, period}`, `tip` (raw value
/// bytes), `privateKey`, and `balanceCall.transfer = PolkadotBalance.
/// Transfer{toAddress, value (raw u128 plancks Data — wallet-core
/// SCALE-compact-encodes it internally)}`.
///
/// **Fee model (matrix §G11, doc-grounded — fees):** weight-based
/// inclusion fee computed by the runtime; the only sender lever is the
/// optional `tip` (`FeeChoice.polkadotTipPlancks`). Default
/// `transferKeepAlive` so the runtime rejects a tx that would reap the
/// sender below the Existential Deposit (matrix §G11). Send-all could use
/// `balances.transferAll`; for safety + the keep-alive default we sign a
/// keep-alive transfer of the resolved amount.
///
/// **Genesis hash** is the relay-chain constant (verified live + in the
/// upstream fixture): `0x91b171bb158e2d3848fa23a9f1c25182fb8e20313b2c1eb…`.
///
/// **No relay-chain tokens** — DOT has no native tokens; assets live on
/// the Asset Hub parachain (a separate endpoint/pallet, out of scope
/// here). A token send refuses honestly rather than sign a relay-chain
/// extrinsic that can't carry it.
///
/// Output: `output.encoded` is the SCALE-encoded signed extrinsic for
/// `author_submitExtrinsic` (0x-hex); the node assigns the hash.
enum PolkadotTransactionSigner {

    /// Polkadot relay-chain genesis hash (constant; verified live via
    /// `chain_getBlockHash[0]` and the upstream test fixture).
    private static let genesisHashHex = "91b171bb158e2d3848fa23a9f1c25182fb8e20313b2c1eb49219da7a70ce90c3"
    /// Mortal-era period (~6.4 min at 64 blocks) so a stuck tx expires.
    private static let mortalEraPeriod: UInt64 = 64

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .polkadot else {
            throw SigningError.malformedDraft("Polkadot signer used for \(draft.chain.rawValue)")
        }
        guard !draft.isTokenSend else {
            // Asset Hub assets are a separate parachain path (matrix §G11).
            throw SigningError.signingFailed("Sending tokens on Polkadot isn't available yet")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let value = SigningAmount.bigEndianMinimal(display: recipient.amount, decimals: draft.chain.nativeDecimals) else {
            throw SigningError.malformedDraft("invalid DOT amount")
        }
        guard let specVersion = jit.polkadotSpecVersion,
              let txVersion = jit.polkadotTransactionVersion else {
            throw SigningError.justInTimeRefreshFailed("Polkadot runtime version not refreshed")
        }
        guard let blockHashHex = jit.polkadotBlockHash,
              let blockHash = SigningNumeric.hexToData(blockHashHex.hasPrefix("0x") ? String(blockHashHex.dropFirst(2)) : blockHashHex) else {
            throw SigningError.justInTimeRefreshFailed("Polkadot block hash not refreshed")
        }
        guard let blockNumber = jit.polkadotBlockNumber, blockNumber > 0 else {
            throw SigningError.justInTimeRefreshFailed("Polkadot block number not refreshed")
        }
        guard let nonce = jit.polkadotNonce else {
            throw SigningError.justInTimeRefreshFailed("Polkadot nonce not refreshed")
        }
        guard let genesisHash = SigningNumeric.hexToData(genesisHashHex) else {
            throw SigningError.signingFailed("Polkadot genesis hash invalid")
        }

        var input = PolkadotSigningInput()
        input.genesisHash = genesisHash
        input.blockHash = blockHash
        input.nonce = nonce
        input.specVersion = specVersion
        input.transactionVersion = txVersion
        input.network = CoinType.polkadot.ss58Prefix
        input.multiAddress = true
        input.privateKey = privateKey.data
        input.era = PolkadotEra.with {
            $0.blockNumber = blockNumber
            $0.period = mortalEraPeriod
        }
        // Optional tip (the only sender fee lever) — raw value bytes.
        if let tipDec = draft.fee.polkadotTipPlancks,
           let tip = SigningAmount.bigEndianMinimal(tipDec), tip != Data([0]) {
            input.tip = tip
        }
        // transferKeepAlive — the runtime rejects a reaping transfer
        // rather than destroying the sender's account (matrix §G11). The
        // Balances pallet index is 5; transferKeepAlive method index is 3
        // (call 0x0503). wallet-core's built-in default is
        // transferAllowDeath (0x0500), so we override via callIndices to
        // get the safer keep-alive variant.
        input.balanceCall.transfer = PolkadotBalance.Transfer.with {
            $0.toAddress = recipient.address
            $0.value = value
            $0.callIndices = PolkadotCallIndices.with {
                $0.custom = PolkadotCustomCallIndices.with {
                    $0.moduleIndex = 0x05 // Balances pallet
                    $0.methodIndex = 0x03 // transferKeepAlive
                }
            }
        }

        let output: PolkadotSigningOutput = AnySigner.sign(input: input, coin: .polkadot)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "Polkadot: empty AnySigner output" : output.errorMessage)
        }

        let rawData = output.encoded
        return SignedTransaction(
            rawData: rawData,
            rawHex: SigningNumeric.hexString0x(rawData), // 0x-hex for author_submitExtrinsic
            txHash: ""                                   // node assigns the hash
        )
    }
}
