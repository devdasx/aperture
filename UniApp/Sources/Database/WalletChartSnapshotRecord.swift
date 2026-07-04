import Foundation

final class WalletChartSnapshotRecord: Identifiable, Hashable {
    var id: UUID
    var walletId: UUID
    var currencyCode: String
    var fiatValue: Decimal
    var capturedAt: Date
    var dayKey: Int

    init(id: UUID = UUID(), walletId: UUID, currencyCode: String, fiatValue: Decimal, capturedAt: Date = Date()) {
        self.id = id
        self.walletId = walletId
        self.currencyCode = currencyCode.uppercased()
        self.fiatValue = fiatValue
        self.capturedAt = capturedAt
        self.dayKey = DayKey.from(date: capturedAt)
    }

    static func == (lhs: WalletChartSnapshotRecord, rhs: WalletChartSnapshotRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
