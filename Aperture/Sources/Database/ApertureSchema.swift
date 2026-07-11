import Foundation

// MARK: - WalletRecord

final class WalletRecord: Identifiable, Hashable {
    var id: UUID
    var name: String
    var kindRaw: String
    var mnemonicWordCount: Int?
    var hasPassphrase: Bool
    var colorTag: String
    var iconSymbol: String
    var iconColorHex: String
    var avatarGradient: String
    var avatarSymbolType: String
    var avatarGlyph: String?
    var avatarMonogram: String?
    var avatarCustomSvg: String?
    var avatarCustomTint: String?
    var avatarBadge: String?
    var sortOrder: Int
    var isHidden: Bool
    var requiresBackup: Bool
    var manualBackupCompleted: Bool?
    var createdAt: Date
    var updatedAt: Date
    var addresses: [WalletAddressRecord]

    init(
        id: UUID = UUID(),
        name: String,
        kind: WalletKind,
        mnemonicWordCount: Int?,
        hasPassphrase: Bool,
        colorTag: String,
        sortOrder: Int,
        requiresBackup: Bool,
        manualBackupCompleted: Bool = false,
        iconSymbol: String = WalletAvatarDefaults.legacySymbol,
        iconColorHex: String = WalletAvatarDefaults.legacyColorHex,
        avatarGradient: String? = nil,
        avatarSymbolType: String? = nil,
        avatarGlyph: String? = nil,
        avatarMonogram: String? = nil,
        avatarCustomSvg: String? = nil,
        avatarCustomTint: String? = nil,
        avatarBadge: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        addresses: [WalletAddressRecord] = []
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.mnemonicWordCount = mnemonicWordCount
        self.hasPassphrase = hasPassphrase
        self.colorTag = colorTag
        self.iconSymbol = iconSymbol
        self.iconColorHex = iconColorHex
        self.sortOrder = sortOrder
        self.isHidden = false
        self.requiresBackup = requiresBackup
        self.manualBackupCompleted = manualBackupCompleted
        let auto = WalletAvatarDefaults.spec(forName: name, kind: kind)
        self.avatarGradient = avatarGradient ?? auto.gradient
        self.avatarSymbolType = avatarSymbolType ?? auto.symbolType
        self.avatarGlyph = avatarGlyph ?? auto.glyph
        self.avatarMonogram = avatarMonogram ?? auto.monogram
        self.avatarCustomSvg = avatarCustomSvg
        self.avatarCustomTint = avatarCustomTint
        self.avatarBadge = avatarBadge ?? auto.badge
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.addresses = addresses
    }

    static func == (lhs: WalletRecord, rhs: WalletRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var kind: WalletKind { WalletKind(rawValue: kindRaw) ?? .watchOnly }

    var avatarSpec: WalletAvatarSpec {
        WalletAvatarSpec.hydrate(
            gradient: avatarGradient,
            symbolType: avatarSymbolType,
            glyph: avatarGlyph,
            monogram: avatarMonogram,
            customSvg: avatarCustomSvg,
            customTint: avatarCustomTint,
            badge: avatarBadge,
            walletName: name,
            walletKind: kind
        )
    }
}

final class WalletSecretRecord {
    var key: String
    var walletId: UUID
    var kindRaw: String
    var cipherData: Data
    var createdAt: Date
    var updatedAt: Date

    init(walletId: UUID, kind: WalletSecretKind, cipherData: Data, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.key = WalletSecretRecord.storageKey(walletId: walletId, kind: kind)
        self.walletId = walletId
        self.kindRaw = kind.rawValue
        self.cipherData = cipherData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func storageKey(walletId: UUID, kind: WalletSecretKind) -> String {
        "\(walletId.uuidString)|\(kind.rawValue)"
    }
}

enum WalletSecretKind: String, Codable, Sendable, CaseIterable {
    case seed
    case mnemonic
    case privateKey
}

enum WalletKind: String, Codable, CaseIterable, Sendable {
    case created
    case importedMnemonic
    case importedKey
    case watchOnly
}

enum WalletAvatarDefaults {
    static let legacySymbol = "wallet.pass.fill"
    static let legacyColorHex = "#0B0D11"
    static var symbol: String { legacySymbol }
    static var colorHex: String { legacyColorHex }

    static func spec(
        forName name: String,
        kind: WalletKind
    ) -> (gradient: String, symbolType: String, glyph: String?, monogram: String?, badge: String?) {
        let spec = WalletAvatarSpec.randomDefault()
        _ = name
        return (
            gradient: spec.gradient.rawValue,
            symbolType: spec.symbolType.rawValue,
            glyph: spec.glyph?.rawValue,
            monogram: spec.monogram,
            badge: WalletAvatarBadge.derive(from: kind)?.rawValue
        )
    }
}

// MARK: - WalletAddressRecord

final class WalletAddressRecord: Identifiable, Hashable {
    var id: UUID
    var walletId: UUID?
    var chainRaw: String
    var address: String
    var derivationPath: String
    var isUsed: Bool
    var isReceivePreferred: Bool
    var lastScannedAt: Date?
    var wallet: WalletRecord?
    var transactions: [TransactionRecord]
    var balances: [TokenBalanceRecord]

    init(
        id: UUID = UUID(),
        walletId: UUID? = nil,
        chainRaw: String,
        address: String,
        derivationPath: String = "",
        isUsed: Bool = false,
        isReceivePreferred: Bool = false,
        lastScannedAt: Date? = nil,
        transactions: [TransactionRecord] = [],
        balances: [TokenBalanceRecord] = []
    ) {
        self.id = id
        self.walletId = walletId
        self.chainRaw = chainRaw
        self.address = address
        self.derivationPath = derivationPath
        self.isUsed = isUsed
        self.isReceivePreferred = isReceivePreferred
        self.lastScannedAt = lastScannedAt
        self.transactions = transactions
        self.balances = balances
    }

    static func == (lhs: WalletAddressRecord, rhs: WalletAddressRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - TransactionRecord

final class TransactionRecord: Identifiable, Hashable {
    var id: UUID
    var txHash: String
    var directionRaw: String
    var amountRaw: String
    var tokenSymbol: String
    var tokenContract: String?
    var blockNumber: Int64?
    var occurredAt: Date
    var statusRaw: String
    var counterparty: String
    var feeRaw: String?
    var address: WalletAddressRecord?
    var addressId: UUID?
    var kindRaw: String?

    init(
        id: UUID = UUID(),
        txHash: String,
        direction: TransactionDirection,
        amountRaw: String,
        tokenSymbol: String,
        tokenContract: String? = nil,
        blockNumber: Int64? = nil,
        occurredAt: Date,
        status: TransactionStatus,
        counterparty: String,
        feeRaw: String? = nil,
        addressId: UUID? = nil,
        kindRaw: String? = nil
    ) {
        self.id = id
        self.txHash = txHash
        self.directionRaw = direction.rawValue
        self.amountRaw = amountRaw
        self.tokenSymbol = tokenSymbol
        self.tokenContract = tokenContract
        self.blockNumber = blockNumber
        self.occurredAt = occurredAt
        self.statusRaw = status.rawValue
        self.counterparty = counterparty
        self.feeRaw = feeRaw
        self.addressId = addressId
        self.kindRaw = kindRaw
    }

    static func == (lhs: TransactionRecord, rhs: TransactionRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum TransactionDirection: String, Codable, Sendable { case incoming, outgoing, `internal` }
enum TransactionStatus: String, Codable, Sendable { case pending, confirmed, failed }

// MARK: - TokenBalanceRecord

final class TokenBalanceRecord: Identifiable, Hashable {
    var id: UUID
    var tokenSymbol: String
    var tokenContract: String?
    var decimals: Int
    var rawBalance: String
    var fiatValueCached: Decimal
    var fiatCurrencyCode: String
    var updatedAt: Date
    var address: WalletAddressRecord?
    var addressId: UUID?

    init(
        id: UUID = UUID(),
        tokenSymbol: String,
        tokenContract: String? = nil,
        decimals: Int,
        rawBalance: String,
        fiatValueCached: Decimal = 0,
        fiatCurrencyCode: String = "USD",
        updatedAt: Date = Date(),
        addressId: UUID? = nil
    ) {
        self.id = id
        self.tokenSymbol = tokenSymbol
        self.tokenContract = tokenContract
        self.decimals = decimals
        self.rawBalance = rawBalance
        self.fiatValueCached = fiatValueCached
        self.fiatCurrencyCode = fiatCurrencyCode
        self.updatedAt = updatedAt
        self.addressId = addressId
    }

    static func == (lhs: TokenBalanceRecord, rhs: TokenBalanceRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - CachedPriceRecord

final class CachedPriceRecord: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var symbol: String
    var fiat: String
    var price: Decimal
    var fetchedAt: Date
    var source: String

    init(symbol: String, fiat: String, price: Decimal, fetchedAt: Date = Date(), source: String) {
        let normalizedSymbol = symbol.uppercased()
        let normalizedFiat = fiat.uppercased()
        self.key = "\(normalizedSymbol)-\(normalizedFiat)"
        self.symbol = normalizedSymbol
        self.fiat = normalizedFiat
        self.price = price
        self.fetchedAt = fetchedAt
        self.source = source
    }

    static func == (lhs: CachedPriceRecord, rhs: CachedPriceRecord) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

final class BiometricEnrollmentRecord: Identifiable {
    var id: UUID
    var domainStateSnapshot: Data?
    var updatedAt: Date

    init(id: UUID = UUID(), domainStateSnapshot: Data?, updatedAt: Date = Date()) {
        self.id = id
        self.domainStateSnapshot = domainStateSnapshot
        self.updatedAt = updatedAt
    }
}

final class AppMetadataRecord: Identifiable {
    var id: UUID
    var schemaVersion: Int
    var firstLaunchAt: Date
    var lastOpenedAt: Date
    var requiresBiometricReenrollment: Bool

    init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        firstLaunchAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        requiresBiometricReenrollment: Bool = false
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.firstLaunchAt = firstLaunchAt
        self.lastOpenedAt = lastOpenedAt
        self.requiresBiometricReenrollment = requiresBiometricReenrollment
    }
}

// MARK: - CustomTokenRecord

final class CustomTokenRecord: Identifiable, Hashable {
    var id: UUID
    var chainRaw: String
    var contract: String
    var symbol: String
    var name: String
    var decimals: Int
    var iconURL: String?
    var addedAt: Date
    var metadataFromChain: Bool

    init(
        id: UUID = UUID(),
        chainRaw: String,
        contract: String,
        symbol: String,
        name: String,
        decimals: Int,
        iconURL: String? = nil,
        addedAt: Date = Date(),
        metadataFromChain: Bool = true
    ) {
        self.id = id
        self.chainRaw = chainRaw
        self.contract = contract
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.iconURL = iconURL
        self.addedAt = addedAt
        self.metadataFromChain = metadataFromChain
    }

    static func == (lhs: CustomTokenRecord, rhs: CustomTokenRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var dedupKey: String { "\(chainRaw)|\(contract.lowercased())" }
    var hasKnownChain: Bool { SupportedChain(rawValue: chainRaw) != nil }
    var chain: SupportedChain { SupportedChain(rawValue: chainRaw) ?? .ethereum }
}

// MARK: - HistoricalPriceRecord

final class HistoricalPriceRecord: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var symbol: String
    var fiat: String
    var dayKey: Int
    var price: Decimal
    var fetchedAt: Date

    init(symbol: String, fiat: String, dayKey: Int, price: Decimal, fetchedAt: Date = Date()) {
        let upperSymbol = symbol.uppercased()
        let upperFiat = fiat.uppercased()
        self.symbol = upperSymbol
        self.fiat = upperFiat
        self.dayKey = dayKey
        self.price = price
        self.fetchedAt = fetchedAt
        self.key = "\(upperSymbol)-\(upperFiat)-\(dayKey)"
    }

    static func == (lhs: HistoricalPriceRecord, rhs: HistoricalPriceRecord) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}
