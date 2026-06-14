import Foundation
import WalletCore

/// Builds and signs Polkadot extrinsics manually with all required signed
/// extensions. Ported faithfully from the Stabro reference wallet's
/// `PolkadotTransactionBuilder.swift`.
///
/// **Why we hand-build (Rule #3 carve-out for THIS task).** wallet-core's
/// built-in Polkadot signer is missing newer extensions the current runtime
/// demands (CheckNonZeroSender, CheckWeight, CheckMetadataHash,
/// StorageWeightReclaim). This builder assembles the extrinsic byte-for-byte
/// and signs with **Ed25519** via wallet-core's `PrivateKey.sign(digest:curve:)`.
///
/// **Curve note (Ed25519, NOT sr25519).** wallet-core's `CoinType.polkadot`
/// derives Ed25519 keys, so every Aperture Polkadot wallet is Ed25519. The
/// builder therefore emits `MultiSignature::Ed25519` and the Ed25519 public
/// key as the signer. This matches Stabro exactly. (The task brief mentioned
/// sr25519; the reference implementation we port — and wallet-core's
/// `.polkadot` derivation — are Ed25519. Flagged in the final report.)
///
/// **Funds-safety (Rule #16 / #26).** The signature is self-verified locally
/// before the extrinsic is returned; a verification failure throws rather than
/// producing a payload that would be rejected (or worse) on-chain. Nothing
/// key- or signature-shaped is ever logged.
enum PolkadotExtrinsicBuilder {

    // MARK: - Errors

    enum BuilderError: Error, Sendable {
        case invalidDestination(String)
        case invalidGenesis(Int)
        case invalidBlockHash(Int)
        case zeroBlockNumber
        case shortCallData(Int)
        case signingNil
        case badSignatureLength(Int)
        case badPublicKeyLength(Int)
        case signatureSelfCheckFailed
    }

    // MARK: - Result

    struct Signed: Sendable {
        /// SCALE-encoded full extrinsic bytes.
        let rawData: Data
        /// `0x…` hex of `rawData` — the payload for `author_submitExtrinsic`.
        let rawHex: String
        /// Locally-computed tx hash = `0x` + Blake2b-256 of the full extrinsic.
        let txHash: String
        /// `true` when built for an Asset Hub parachain (relay = `false`).
        let isParachain: Bool
    }

    // MARK: - Target Chain

    /// Target chain — determines genesis, pallet index, and signed-extension
    /// order. Aperture's `.polkadot` RPC endpoints are the **relay chain**
    /// (`rpc.polkadot.io`, `polkadot.api.onfinality.io/public`), so native DOT
    /// sends use `.relay`. `.assetHub` is ported for completeness / future use.
    enum Chain: String, Sendable {
        case relay
        case assetHub
    }

    // MARK: - Genesis Hashes

    private static let relayGenesisHash =
        hexData("91b171bb158e2d3848fa23a9f1c25182fb8e20313b2c1eb49219da7a70ce90c3")
    private static let assetHubGenesisHash =
        hexData("68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f")

    // MARK: - Pallet / Call Indices

    /// `Balances::transfer_keep_alive` on the Polkadot relay chain
    /// (pallet 5, call 3).
    private static let relayBalancesTransferKeepAlive: (UInt8, UInt8) = (0x05, 0x03)

    /// `Balances::transfer_keep_alive` on Asset Hub (pallet 10 = 0x0a, call 3).
    private static let assetHubBalancesTransferKeepAlive: (UInt8, UInt8) = (0x0a, 0x03)

    /// Default mortal-era period in blocks (~6.4 min on Polkadot's 6s blocks).
    private static let eraPeriod: UInt64 = 64

    // MARK: - Public API: Native DOT Transfer

    /// Builds and signs a native DOT `Balances::transfer_keep_alive` extrinsic.
    ///
    /// Genesis hash is resolved from `chain` (so the caller passes the runtime
    /// + finalized-block context; the genesis is constant per chain). The
    /// signature exactly matches the Stabro builder's behavior, with the
    /// relay-chain pallet index + signed-extension order selected by `chain`.
    static func buildNativeTransfer(
        privateKey: PrivateKey,
        toAddress: String,
        amountPlanck: UInt64,
        nonce: UInt64,
        specVersion: UInt32,
        transactionVersion: UInt32,
        blockHash: Data,
        blockNumber: UInt64,
        chain: Chain
    ) throws -> Signed {
        guard let destAccountId = decodePolkadotAddress(toAddress) else {
            throw BuilderError.invalidDestination(toAddress)
        }

        let (palletIdx, callIdx): (UInt8, UInt8)
        let genesisHash: Data
        switch chain {
        case .relay:
            (palletIdx, callIdx) = relayBalancesTransferKeepAlive
            genesisHash = relayGenesisHash
        case .assetHub:
            (palletIdx, callIdx) = assetHubBalancesTransferKeepAlive
            genesisHash = assetHubGenesisHash
        }

        var callData = Data([palletIdx, callIdx])
        callData.append(SCALECodec.encodeMultiAddressId(destAccountId))
        callData.append(SCALECodec.encodeCompact(amountPlanck))

        return try buildAndSignExtrinsic(
            privateKey: privateKey,
            callData: callData,
            nonce: nonce,
            specVersion: specVersion,
            transactionVersion: transactionVersion,
            genesisHash: genesisHash,
            blockHash: blockHash,
            blockNumber: blockNumber,
            chain: chain
        )
    }

    // MARK: - Core Extrinsic Builder

    /// Assembles, signs, and SCALE-encodes a full signed extrinsic (version 4).
    ///
    /// Layout:
    /// ```
    /// compact(body_length) ++ body
    /// body = 0x84 ++ MultiAddress(signer) ++ MultiSignature(sig) ++ extra ++ call
    /// ```
    /// Signature covers: `call ++ extra ++ additional_signed`. If that payload
    /// exceeds 256 bytes it is hashed with Blake2b-256 first (Polkadot rule).
    private static func buildAndSignExtrinsic(
        privateKey: PrivateKey,
        callData: Data,
        nonce: UInt64,
        specVersion: UInt32,
        transactionVersion: UInt32,
        genesisHash: Data,
        blockHash: Data,
        blockNumber: UInt64,
        chain: Chain
    ) throws -> Signed {

        guard genesisHash.count == 32 else { throw BuilderError.invalidGenesis(genesisHash.count) }
        guard blockHash.count == 32 else { throw BuilderError.invalidBlockHash(blockHash.count) }
        guard blockNumber > 0 else { throw BuilderError.zeroBlockNumber }
        guard callData.count >= 2 else { throw BuilderError.shortCallData(callData.count) }

        // 1. "extra" — included in the extrinsic body AND signed over.
        let extraData = buildExtra(nonce: nonce, blockNumber: blockNumber, chain: chain)

        // 2. "additional signed" — signed over, NOT in the extrinsic body.
        let additionalData = buildAdditionalSigned(
            specVersion: specVersion,
            transactionVersion: transactionVersion,
            genesisHash: genesisHash,
            blockHash: blockHash,
            chain: chain
        )

        // 3. Signing payload = call ++ extra ++ additional_signed.
        var signingPayload = Data()
        signingPayload.append(callData)
        signingPayload.append(extraData)
        signingPayload.append(additionalData)

        // 4. Hash with Blake2b-256 if the payload exceeds 256 bytes.
        let messageToSign: Data = signingPayload.count > 256
            ? Hash.blake2b(data: signingPayload, size: 32)
            : signingPayload

        // 5. Sign with Ed25519. wallet-core's `sign(digest:curve:.ed25519)`
        //    treats the input as the full message (Ed25519 does its own
        //    internal SHA-512 per RFC 8032) — the parameter name "digest"
        //    is misleading for this curve.
        guard let signature = privateKey.sign(digest: messageToSign, curve: .ed25519) else {
            throw BuilderError.signingNil
        }
        guard signature.count == 64 else { throw BuilderError.badSignatureLength(signature.count) }

        // 6. Signer = Ed25519 public key (32 bytes).
        let pubKey = privateKey.getPublicKeyEd25519()
        let signerAccountId = pubKey.data
        guard signerAccountId.count == 32 else {
            throw BuilderError.badPublicKeyLength(signerAccountId.count)
        }

        // 6b. Self-verify before broadcasting — refuse a bad signature rather
        //     than ship a payload that fails on-chain (Rule #16 / #26).
        guard pubKey.verify(signature: signature, message: messageToSign) else {
            throw BuilderError.signatureSelfCheckFailed
        }

        // 7. Assemble the extrinsic body.
        var body = Data()
        body.append(0x84)                                               // Signed extrinsic, v4
        body.append(SCALECodec.encodeMultiAddressId(signerAccountId))   // MultiAddress::Id(signer)
        body.append(SCALECodec.encodeMultiSignatureEd25519(signature))  // MultiSignature::Ed25519(sig)
        body.append(extraData)                                          // signed-extension extra
        body.append(callData)                                           // call

        // 8. Prefix with the compact-encoded body length.
        var encoded = SCALECodec.encodeCompact(UInt64(body.count))
        encoded.append(body)

        let rawHex = "0x" + encoded.map { String(format: "%02x", $0) }.joined()
        // Tx hash = Blake2b-256 of the full encoded extrinsic.
        let txHash = "0x" + Hash.blake2b(data: encoded, size: 32)
            .map { String(format: "%02x", $0) }.joined()

        return Signed(
            rawData: encoded,
            rawHex: rawHex,
            txHash: txHash,
            isParachain: chain == .assetHub
        )
    }

    // MARK: - Signed Extensions: Extra

    /// Builds the "extra" portion (included in the extrinsic).
    ///
    /// **Relay chain order:**
    /// 1. CheckNonZeroSender → ∅
    /// 2. CheckSpecVersion → ∅
    /// 3. CheckTxVersion → ∅
    /// 4. CheckGenesis → ∅
    /// 5. CheckMortality → era (2 bytes)
    /// 6. CheckNonce → compact(nonce)
    /// 7. CheckWeight → ∅
    /// 8. ChargeTransactionPayment → compact(tip = 0)
    /// 9. PrevalidateAttests → ∅
    /// 10. CheckMetadataHash → 0x00 (Disabled)
    ///
    /// **Asset Hub order:**
    /// 1–7 same; 8. ChargeAssetTxPayment → compact(tip = 0) + Option::None;
    /// 9. CheckMetadataHash → 0x00; 10. StorageWeightReclaim → ∅.
    private static func buildExtra(nonce: UInt64, blockNumber: UInt64, chain: Chain) -> Data {
        var extra = Data()

        // 1–4: CheckNonZeroSender / CheckSpecVersion / CheckTxVersion / CheckGenesis — no extra.

        // 5. CheckMortality: mortal era.
        extra.append(SCALECodec.encodeMortalEra(period: eraPeriod, current: blockNumber))

        // 6. CheckNonce: compact(nonce).
        extra.append(SCALECodec.encodeCompact(nonce))

        // 7. CheckWeight — no extra.

        // 8. Fee payment.
        switch chain {
        case .relay:
            // ChargeTransactionPayment: compact(tip = 0).
            extra.append(SCALECodec.encodeCompact(0))
        case .assetHub:
            // ChargeAssetTxPayment: compact(tip = 0) + Option<AssetId>::None.
            extra.append(SCALECodec.encodeCompact(0))
            extra.append(0x00)
        }

        // 9. CheckMetadataHash: mode = Disabled.
        extra.append(0x00)

        // 10. StorageWeightReclaim (Asset Hub only) — no extra.

        return extra
    }

    // MARK: - Signed Extensions: Additional Signed

    /// Builds the "additional signed" portion (signed over, NOT in the body).
    ///
    /// CheckSpecVersion → u32 LE; CheckTxVersion → u32 LE; CheckGenesis →
    /// H256; CheckMortality → H256 (block hash); CheckMetadataHash →
    /// Option::None (0x00). All other extensions contribute ∅.
    private static func buildAdditionalSigned(
        specVersion: UInt32,
        transactionVersion: UInt32,
        genesisHash: Data,
        blockHash: Data,
        chain: Chain
    ) -> Data {
        var additional = Data()

        // 1. CheckNonZeroSender — none.
        // 2. CheckSpecVersion: u32 LE.
        additional.append(SCALECodec.encodeU32(specVersion))
        // 3. CheckTxVersion: u32 LE.
        additional.append(SCALECodec.encodeU32(transactionVersion))
        // 4. CheckGenesis: genesis hash (32 bytes).
        additional.append(genesisHash)
        // 5. CheckMortality: block hash (32 bytes).
        additional.append(blockHash)
        // 6. CheckNonce / 7. CheckWeight / 8. Charge*Payment — none.
        // 9. CheckMetadataHash: Option<[u8;32]>::None (mode = Disabled).
        additional.append(0x00)
        // 10. StorageWeightReclaim (Asset Hub only) — none.

        return additional
    }

    // MARK: - Address Decoding

    /// Decodes a Polkadot SS58 address to its raw 32-byte public key using
    /// wallet-core's `AnyAddress`. Returns `nil` on an invalid address.
    static func decodePolkadotAddress(_ address: String) -> Data? {
        if let anyAddr = AnyAddress(string: address, coin: .polkadot) {
            return anyAddr.data
        }
        return nil
    }

    // MARK: - Hex helper (file-private; our Data(hexString:) is file-scoped elsewhere)

    /// Decodes a hex string (no `0x`) into `Data`. Used only for the two
    /// constant genesis hashes — both are valid 64-char hex, so a force is
    /// safe; we fall back to empty (caught by the 32-byte guard) if not.
    private static func hexData(_ hex: String) -> Data {
        var bytes = [UInt8]()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return Data() }
            bytes.append(byte)
            idx = next
        }
        return Data(bytes)
    }
}
