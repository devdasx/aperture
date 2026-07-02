import Foundation
import SwiftData

// MARK: - WalletBalanceCardPointSnapshot

struct WalletBalanceCardPointSnapshot: Codable, Hashable, Sendable {
    let timestamp: Date
    let fiatRaw: String

    init(timestamp: Date, fiat: Decimal) {
        self.timestamp = timestamp
        self.fiatRaw = Self.string(fiat)
    }

    var fiat: Decimal { Decimal(string: fiatRaw) ?? 0 }

    private static func string(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

// MARK: - WalletBalanceCardRangeSnapshot

struct WalletBalanceCardRangeSnapshot: Codable, Hashable, Sendable {
    let rangeRaw: String
    let points: [WalletBalanceCardPointSnapshot]
    let xFractions: [Double]
    let minValue: Double
    let maxValue: Double
    let baselineFiatRaw: String
    let changeFiatRaw: String
    let changePercent: Double
    let signRaw: String

    init(
        rangeRaw: String,
        points: [WalletBalanceCardPointSnapshot],
        xFractions: [Double],
        minValue: Double,
        maxValue: Double,
        baselineFiat: Decimal,
        changeFiat: Decimal,
        changePercent: Double,
        signRaw: String
    ) {
        self.rangeRaw = rangeRaw
        self.points = points
        self.xFractions = xFractions
        self.minValue = minValue
        self.maxValue = maxValue
        self.baselineFiatRaw = NSDecimalNumber(decimal: baselineFiat).stringValue
        self.changeFiatRaw = NSDecimalNumber(decimal: changeFiat).stringValue
        self.changePercent = changePercent
        self.signRaw = signRaw
    }

    var baselineFiat: Decimal { Decimal(string: baselineFiatRaw) ?? 0 }
    var changeFiat: Decimal { Decimal(string: changeFiatRaw) ?? 0 }
    var balancePoints: [BalancePoint] {
        points.map { BalancePoint(timestamp: $0.timestamp, fiat: $0.fiat) }
    }
    var values: [Double] {
        points.map { NSDecimalNumber(decimal: $0.fiat).doubleValue }
    }
}

// MARK: - WalletBalanceCardDisplaySnapshot

struct WalletBalanceCardDisplaySnapshot: Hashable, Sendable {
    let walletId: UUID
    let currencyCode: String
    let totalFiat: Decimal
    let lastUpdatedAt: Date?
    let selectedRangeRaw: String
    let isBalanceHidden: Bool
    let updatedAt: Date
    let ranges: [WalletBalanceCardRangeSnapshot]

    func range(_ range: BalanceHistoryRange) -> WalletBalanceCardRangeSnapshot? {
        ranges.first { $0.rangeRaw == range.rawValue }
    }
}

// MARK: - WalletBalanceCardSnapshotRecord

@Model
final class WalletBalanceCardSnapshotRecord {
    #Index<WalletBalanceCardSnapshotRecord>(
        [\.walletId],
        [\.walletId, \.currencyCode]
    )

    @Attribute(.unique) var id: String
    var walletId: UUID
    var currencyCode: String
    var totalFiat: Decimal
    var lastUpdatedAt: Date?
    var selectedRangeRaw: String
    var isBalanceHidden: Bool
    var rangesData: Data
    var updatedAt: Date

    init(
        walletId: UUID,
        currencyCode: String,
        totalFiat: Decimal,
        lastUpdatedAt: Date?,
        selectedRangeRaw: String,
        isBalanceHidden: Bool,
        ranges: [WalletBalanceCardRangeSnapshot],
        updatedAt: Date = Date()
    ) {
        let code = currencyCode.uppercased()
        self.id = Self.key(walletId: walletId, currencyCode: code)
        self.walletId = walletId
        self.currencyCode = code
        self.totalFiat = totalFiat
        self.lastUpdatedAt = lastUpdatedAt
        self.selectedRangeRaw = selectedRangeRaw
        self.isBalanceHidden = isBalanceHidden
        self.rangesData = (try? Self.encoder.encode(ranges)) ?? Data()
        self.updatedAt = updatedAt
    }

    static func key(walletId: UUID, currencyCode: String) -> String {
        "\(walletId.uuidString)|\(currencyCode.uppercased())"
    }

    func update(
        totalFiat: Decimal,
        lastUpdatedAt: Date?,
        selectedRangeRaw: String,
        isBalanceHidden: Bool,
        ranges: [WalletBalanceCardRangeSnapshot],
        updatedAt: Date
    ) {
        self.totalFiat = totalFiat
        self.lastUpdatedAt = lastUpdatedAt
        self.selectedRangeRaw = selectedRangeRaw
        self.isBalanceHidden = isBalanceHidden
        self.rangesData = (try? Self.encoder.encode(ranges)) ?? Data()
        self.updatedAt = updatedAt
    }

    func displaySnapshot() -> WalletBalanceCardDisplaySnapshot {
        let ranges = (try? Self.decoder.decode([WalletBalanceCardRangeSnapshot].self, from: rangesData)) ?? []
        return WalletBalanceCardDisplaySnapshot(
            walletId: walletId,
            currencyCode: currencyCode,
            totalFiat: totalFiat,
            lastUpdatedAt: lastUpdatedAt,
            selectedRangeRaw: selectedRangeRaw,
            isBalanceHidden: isBalanceHidden,
            updatedAt: updatedAt,
            ranges: ranges
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
