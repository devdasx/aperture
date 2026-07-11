import Foundation

final class PriceSnapshotRecord: Identifiable, Hashable {
    var id: UUID
    var symbol: String
    var currencyCode: String
    var price: Decimal
    var fetchedAt: Date
    var source: String
    var dayKey: Int

    init(id: UUID = UUID(), symbol: String, currencyCode: String, price: Decimal, fetchedAt: Date = Date(), source: String) {
        self.id = id
        self.symbol = symbol.uppercased()
        self.currencyCode = currencyCode.uppercased()
        self.price = price
        self.fetchedAt = fetchedAt
        self.source = source
        self.dayKey = DayKey.from(date: fetchedAt)
    }

    static func == (lhs: PriceSnapshotRecord, rhs: PriceSnapshotRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
