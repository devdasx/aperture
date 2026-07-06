import Foundation
import WalletCore

/// Builds + signs Polkadot relay-chain transactions (native DOT
/// `balances.transferKeepAlive`, with a mortal era + optional tip) from
/// `SendDraft` + just-in-time data.
///
/// This intentionally does not use WalletCore's Polkadot extrinsic builder.
/// Polkadot mainnet now includes the `CheckMetadataHash` signed extension,
/// which adds a mode byte to signed extras. WalletCore 4.6.x's Polkadot proto
/// has no field for that extension, so its otherwise-valid signature is over
/// the wrong payload and current nodes reject it as `Invalid Transaction`.
/// We still use WalletCore's private-key/public-key/signature primitives, then
/// encode the current SCALE extrinsic directly.
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
    private static let signedExtrinsicVersion: UInt8 = 0x84
    private static let ed25519SignatureKind: UInt8 = 0x00
    private static let multiAddressAccountIdKind: UInt8 = 0x00
    private static let balancesPalletIndex: UInt8 = 0x05
    private static let transferKeepAliveCallIndex: UInt8 = 0x03
    private static let checkMetadataHashDisabledMode: UInt8 = 0x00

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
        guard let value = SigningAmount.uint64(display: recipient.amount, decimals: draft.chain.nativeDecimals) else {
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
        guard let accountId = SS58.decodeAccountId(recipient.address) else {
            throw SigningError.malformedDraft("invalid Polkadot recipient address")
        }
        let toAccountId = Data(accountId)
        let tip = draft.fee.polkadotTipPlancks.flatMap(SigningAmount.uint64) ?? 0

        let publicKey = privateKey.getPublicKeyEd25519().data
        let era = mortalEra(blockNumber: blockNumber, period: mortalEraPeriod)
        let call = transferKeepAliveCall(toAccountId: toAccountId, value: value)
        let signedExtra = signedExtra(era: era, nonce: nonce, tip: tip, includeMetadataHashMode: true)
        let additional = additionalSigned(
            specVersion: specVersion,
            transactionVersion: txVersion,
            genesisHash: genesisHash,
            blockHash: blockHash
        )
        let payload = call + signedExtra + additional
        let signable = payload.count > 256 ? BLAKE2b.hash(payload, outlen: 32) : payload
        guard let signature = privateKey.sign(digest: signable, curve: .ed25519), signature.count == 64 else {
            throw SigningError.signingFailed("Polkadot signature failed")
        }

        let rawData = signedExtrinsic(
            publicKey: publicKey,
            signature: signature,
            signedExtra: signedExtra,
            call: call
        )
        guard !rawData.isEmpty else { throw SigningError.signingFailed("Polkadot: empty signer output") }

        return SignedTransaction(
            rawData: rawData,
            rawHex: SigningNumeric.hexString0x(rawData), // 0x-hex for author_submitExtrinsic
            txHash: ""                                   // node assigns the hash
        )
    }

    // MARK: - SCALE encoding

    static func transferKeepAliveCall(toAccountId: Data, value: UInt64) -> Data {
        var out = Data([balancesPalletIndex, transferKeepAliveCallIndex])
        out.append(multiAddress(accountId: toAccountId))
        out.append(compact(value))
        return out
    }

    static func signedExtra(era: Data, nonce: UInt64, tip: UInt64, includeMetadataHashMode: Bool) -> Data {
        var out = Data()
        out.append(era)
        out.append(compact(nonce))
        out.append(compact(tip))
        if includeMetadataHashMode {
            out.append(checkMetadataHashDisabledMode)
        }
        return out
    }

    static func additionalSigned(
        specVersion: UInt32,
        transactionVersion: UInt32,
        genesisHash: Data,
        blockHash: Data
    ) -> Data {
        var out = Data()
        out.append(littleEndian(specVersion))
        out.append(littleEndian(transactionVersion))
        out.append(genesisHash)
        out.append(blockHash)
        return out
    }

    static func signedExtrinsic(
        publicKey: Data,
        signature: Data,
        signedExtra: Data,
        call: Data
    ) -> Data {
        var body = Data([signedExtrinsicVersion])
        body.append(multiAddress(accountId: publicKey))
        body.append(ed25519SignatureKind)
        body.append(signature)
        body.append(signedExtra)
        body.append(call)

        var out = compact(UInt64(body.count))
        out.append(body)
        return out
    }

    static func mortalEra(blockNumber: UInt64, period requestedPeriod: UInt64) -> Data {
        let period = min(max(nextPowerOfTwo(requestedPeriod), 4), 1 << 16)
        let phase = blockNumber % period
        let quantizeFactor = max(period >> 12, 1)
        let quantizedPhase = (phase / quantizeFactor) * quantizeFactor
        let trailing = UInt64(period.trailingZeroBitCount)
        let encoded = min(15, max(1, trailing - 1)) | ((quantizedPhase / quantizeFactor) << 4)
        return Data([UInt8(encoded & 0xff), UInt8((encoded >> 8) & 0xff)])
    }

    static func compact(_ value: UInt64) -> Data {
        if value < 1 << 6 {
            return Data([UInt8(value << 2)])
        }
        if value < 1 << 14 {
            let encoded = UInt16(value << 2) | 0x01
            return Data([UInt8(encoded & 0xff), UInt8((encoded >> 8) & 0xff)])
        }
        if value < 1 << 30 {
            let encoded = UInt32(value << 2) | 0x02
            return Data([
                UInt8(encoded & 0xff),
                UInt8((encoded >> 8) & 0xff),
                UInt8((encoded >> 16) & 0xff),
                UInt8((encoded >> 24) & 0xff)
            ])
        }

        var bytes: [UInt8] = []
        var n = value
        while n > 0 {
            bytes.append(UInt8(n & 0xff))
            n >>= 8
        }
        let prefix = UInt8(((bytes.count - 4) << 2) | 0x03)
        return Data([prefix] + bytes)
    }

    private static func multiAddress(accountId: Data) -> Data {
        var out = Data([multiAddressAccountIdKind])
        out.append(accountId)
        return out
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }

    private static func nextPowerOfTwo(_ value: UInt64) -> UInt64 {
        guard value > 1 else { return 1 }
        var n: UInt64 = 1
        while n < value { n <<= 1 }
        return n
    }
}
