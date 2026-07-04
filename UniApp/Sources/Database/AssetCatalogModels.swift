import Foundation

final class ChainRecord: Identifiable, Hashable {
    var id: String { chainRaw }
    var chainRaw: String
    var ticker: String
    var displayName: String
    var sortIndex: Int

    init(chainRaw: String, ticker: String, displayName: String, sortIndex: Int) {
        self.chainRaw = chainRaw
        self.ticker = ticker
        self.displayName = displayName
        self.sortIndex = sortIndex
    }

    static func == (lhs: ChainRecord, rhs: ChainRecord) -> Bool { lhs.chainRaw == rhs.chainRaw }
    func hash(into hasher: inout Hasher) { hasher.combine(chainRaw) }

    var catalogChain: CatalogChain? {
        guard let chain = SupportedChain(rawValue: chainRaw) else { return nil }
        return CatalogChain(chain: chain)
    }
}

final class AssetRecord: Identifiable, Hashable {
    var id: String { catalogId }
    var catalogId: String
    var chainRaw: String
    var symbol: String
    var name: String
    var contract: String
    var decimals: Int

    init(catalogId: String, chainRaw: String, symbol: String, name: String, contract: String, decimals: Int) {
        self.catalogId = catalogId
        self.chainRaw = chainRaw
        self.symbol = symbol
        self.name = name
        self.contract = contract
        self.decimals = decimals
    }

    static func == (lhs: AssetRecord, rhs: AssetRecord) -> Bool { lhs.catalogId == rhs.catalogId }
    func hash(into hasher: inout Hasher) { hasher.combine(catalogId) }

    var catalogAsset: CatalogAsset? {
        guard let chain = SupportedChain(rawValue: chainRaw) else { return nil }
        return CatalogAsset(id: catalogId, chain: chain, symbol: symbol, name: name, contract: contract, decimals: decimals)
    }
}
