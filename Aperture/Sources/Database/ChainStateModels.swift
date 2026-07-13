import Foundation

/// Per-chain portfolio rollup for a wallet (`chain_states` table).
///
/// **One row per chain** (`UNIQUE(wallet_id, chain_raw)`). The `address` column
/// is the **preferred** send/receive address only — never the full set.
///
/// Multi-path chains store every path in `wallet_addresses`:
/// - Bitcoin-family: receive/change gap addresses
/// - Solana: Phantom + Trust account-0 paths
///
/// Use `WalletRepository.addresses(walletId:chain:)` (or preferred helpers)
/// when you need every address. Do **not** assume `address` is the only
/// funded or spendable path on the chain.
///
/// Balance fields (`nativeBalanceRaw`, `totalFiat`) are aggregates defined by
/// rebuild: BTC sums all paths; Solana is preferred-path only (product rule).
final class ChainStateRecord: Identifiable, Hashable {
    var id: UUID
    var walletId: UUID
    var chainRaw: String
    /// Preferred send/receive address for this chain (see type doc).
    var address: String
    var derivationPath: String
    var nativeBalanceRaw: String
    var nativeDecimals: Int
    var nativeFiat: Decimal
    var totalFiat: Decimal
    var tokenCount: Int
    var fiatCurrencyCode: String
    var txSentCount: Int
    var txReceivedCount: Int
    var txSelfTransferCount: Int
    var txBridgeCount: Int
    var txFailedCount: Int
    var txPendingCount: Int
    var txTotalCount: Int
    var utxoCount: Int
    var utxoTotalRaw: String
    var isUsed: Bool
    var lastSyncedAt: Date?
    var syncStateRaw: String
    var encryptedPrivateKey: Data?
    var keyEncryptionScheme: String?

    init(
        id: UUID = UUID(),
        walletId: UUID,
        chainRaw: String,
        address: String,
        derivationPath: String = "",
        nativeBalanceRaw: String = "0",
        nativeDecimals: Int = 0,
        nativeFiat: Decimal = 0,
        totalFiat: Decimal = 0,
        tokenCount: Int = 0,
        fiatCurrencyCode: String = "USD",
        txSentCount: Int = 0,
        txReceivedCount: Int = 0,
        txSelfTransferCount: Int = 0,
        txBridgeCount: Int = 0,
        txFailedCount: Int = 0,
        txPendingCount: Int = 0,
        txTotalCount: Int = 0,
        utxoCount: Int = 0,
        utxoTotalRaw: String = "0",
        isUsed: Bool = false,
        lastSyncedAt: Date? = nil,
        syncState: ChainSyncState = .idle,
        encryptedPrivateKey: Data? = nil,
        keyEncryptionScheme: String? = nil
    ) {
        self.id = id
        self.walletId = walletId
        self.chainRaw = chainRaw
        self.address = address
        self.derivationPath = derivationPath
        self.nativeBalanceRaw = nativeBalanceRaw
        self.nativeDecimals = nativeDecimals
        self.nativeFiat = nativeFiat
        self.totalFiat = totalFiat
        self.tokenCount = tokenCount
        self.fiatCurrencyCode = fiatCurrencyCode
        self.txSentCount = txSentCount
        self.txReceivedCount = txReceivedCount
        self.txSelfTransferCount = txSelfTransferCount
        self.txBridgeCount = txBridgeCount
        self.txFailedCount = txFailedCount
        self.txPendingCount = txPendingCount
        self.txTotalCount = txTotalCount
        self.utxoCount = utxoCount
        self.utxoTotalRaw = utxoTotalRaw
        self.isUsed = isUsed
        self.lastSyncedAt = lastSyncedAt
        self.syncStateRaw = syncState.rawValue
        self.encryptedPrivateKey = encryptedPrivateKey
        self.keyEncryptionScheme = keyEncryptionScheme
    }

    static func == (lhs: ChainStateRecord, rhs: ChainStateRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var chain: SupportedChain? { SupportedChain(rawValue: chainRaw) }
    var syncState: ChainSyncState { ChainSyncState(rawValue: syncStateRaw) ?? .idle }
    var nativeBalance: Decimal { Decimal(string: nativeBalanceRaw) ?? 0 }

    /// Explicit name for `address` — preferred path only, not the full set.
    var preferredAddress: String { address }
}

enum ChainSyncState: String, Codable, Sendable {
    case idle
    case syncing
    case synced
    case failed
}

final class WalletPortfolioSummaryRecord: Identifiable, Hashable {
    var id: UUID
    var lookupKey: String
    var walletId: UUID
    var currencyCode: String
    var totalFiat: Decimal
    var positiveChainCount: Int
    var positiveAssetCount: Int
    var positiveTokenCount: Int
    var sourceChainCount: Int
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        walletId: UUID,
        currencyCode: String,
        totalFiat: Decimal = 0,
        positiveChainCount: Int = 0,
        positiveAssetCount: Int = 0,
        positiveTokenCount: Int = 0,
        sourceChainCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.lookupKey = Self.makeLookupKey(walletId: walletId, currencyCode: currencyCode)
        self.walletId = walletId
        self.currencyCode = currencyCode.uppercased()
        self.totalFiat = totalFiat
        self.positiveChainCount = positiveChainCount
        self.positiveAssetCount = positiveAssetCount
        self.positiveTokenCount = positiveTokenCount
        self.sourceChainCount = sourceChainCount
        self.updatedAt = updatedAt
    }

    static func == (lhs: WalletPortfolioSummaryRecord, rhs: WalletPortfolioSummaryRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func makeLookupKey(walletId: UUID, currencyCode: String) -> String {
        "\(walletId.uuidString.lowercased()):\(currencyCode.uppercased())"
    }
}

final class ChainUTXORecord: Identifiable, Hashable {
    var id: UUID
    var walletId: UUID
    var addressId: UUID?
    var chainRaw: String
    var address: String
    var txid: String
    var vout: Int
    var valueSatsRaw: String
    var scriptHex: String?
    var confirmed: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        walletId: UUID,
        addressId: UUID? = nil,
        chainRaw: String,
        address: String,
        txid: String,
        vout: Int,
        valueSatsRaw: String,
        scriptHex: String? = nil,
        confirmed: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.walletId = walletId
        self.addressId = addressId
        self.chainRaw = chainRaw
        self.address = address
        self.txid = txid
        self.vout = vout
        self.valueSatsRaw = valueSatsRaw
        self.scriptHex = scriptHex
        self.confirmed = confirmed
        self.updatedAt = updatedAt
    }

    static func == (lhs: ChainUTXORecord, rhs: ChainUTXORecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var valueSats: Int64 { Int64(valueSatsRaw) ?? 0 }
}
