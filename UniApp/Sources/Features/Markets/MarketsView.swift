import Foundation
import Charts
import SwiftData
import SwiftUI
import TipKit
import UIKit

// MARK: - SwiftData

@Model
final class MarketAssetRecord {
    @Attribute(.unique) var symbol: String
    var name: String
    var providerId: String
    var rank: Int
    var price: Double
    var currencyCode: String
    var priceChange24hPercent: Double
    var priceChange24hAmount: Double
    var marketCap: Double
    var volume24h: Double
    var circulatingSupply: Double
    var ath: Double
    var high24h: Double
    var low24h: Double
    var about: String
    var sparklineJSON: String
    var source: String
    var lastUpdatedAt: Date

    init(asset: MarketAsset) {
        self.symbol = asset.symbol
        self.name = asset.name
        self.providerId = asset.providerId
        self.rank = asset.rank
        self.price = asset.price
        self.currencyCode = asset.currencyCode
        self.priceChange24hPercent = asset.priceChange24hPercent
        self.priceChange24hAmount = asset.priceChange24hAmount
        self.marketCap = asset.marketCap
        self.volume24h = asset.volume24h
        self.circulatingSupply = asset.circulatingSupply
        self.ath = asset.ath
        self.high24h = asset.high24h
        self.low24h = asset.low24h
        self.about = asset.about
        self.sparklineJSON = MarketPoint.codec.encode(asset.sparkline)
        self.source = asset.source
        self.lastUpdatedAt = asset.lastUpdatedAt
    }

    func apply(_ asset: MarketAsset) {
        name = asset.name
        providerId = asset.providerId
        rank = asset.rank
        price = asset.price
        currencyCode = asset.currencyCode
        priceChange24hPercent = asset.priceChange24hPercent
        priceChange24hAmount = asset.priceChange24hAmount
        if asset.marketCap > 0 { marketCap = asset.marketCap }
        if asset.volume24h > 0 { volume24h = asset.volume24h }
        if asset.circulatingSupply > 0 { circulatingSupply = asset.circulatingSupply }
        if asset.ath > 0 { ath = asset.ath }
        if asset.high24h > 0 { high24h = asset.high24h }
        if asset.low24h > 0 { low24h = asset.low24h }
        if !asset.about.isEmpty {
            about = asset.about
        }
        if !asset.sparkline.isEmpty {
            sparklineJSON = MarketPoint.codec.encode(asset.sparkline)
        }
        source = asset.source
        lastUpdatedAt = asset.lastUpdatedAt
    }

    var snapshot: MarketAsset {
        MarketAsset(
            symbol: symbol,
            name: name,
            providerId: providerId,
            rank: rank,
            price: price,
            currencyCode: currencyCode,
            priceChange24hPercent: priceChange24hPercent,
            priceChange24hAmount: priceChange24hAmount,
            marketCap: marketCap,
            volume24h: volume24h,
            circulatingSupply: circulatingSupply,
            ath: ath,
            high24h: high24h,
            low24h: low24h,
            about: about,
            sparkline: MarketPoint.codec.decode(sparklineJSON),
            source: source,
            lastUpdatedAt: lastUpdatedAt
        )
    }
}

@Model
final class MarketChartCacheRecord {
    @Attribute(.unique) var cacheKey: String
    var symbol: String
    var rangeRaw: String
    var currencyCode: String
    var samplesJSON: String
    var source: String
    var updatedAt: Date

    init(symbol: String, range: MarketChartRange, currencyCode: String, samples: [MarketPoint], source: String) {
        let normalizedCurrency = currencyCode.uppercased()
        self.cacheKey = Self.key(symbol: symbol, range: range, currencyCode: normalizedCurrency)
        self.symbol = symbol.uppercased()
        self.rangeRaw = range.rawValue
        self.currencyCode = normalizedCurrency
        self.samplesJSON = MarketPoint.codec.encode(samples)
        self.source = source
        self.updatedAt = Date()
    }

    func apply(samples: [MarketPoint], source: String) {
        samplesJSON = MarketPoint.codec.encode(samples)
        self.source = source
        updatedAt = Date()
    }

    static func key(symbol: String, range: MarketChartRange, currencyCode: String) -> String {
        "\(symbol.uppercased())|\(range.rawValue)|\(currencyCode.uppercased())"
    }
}

@Model
final class MarketWatchlistRecord {
    @Attribute(.unique) var symbol: String
    var addedAt: Date

    init(symbol: String, addedAt: Date = Date()) {
        self.symbol = symbol.uppercased()
        self.addedAt = addedAt
    }
}

// MARK: - Models

struct MarketPoint: Codable, Hashable, Sendable {
    var timestamp: TimeInterval
    var price: Double

    var date: Date { Date(timeIntervalSince1970: timestamp) }

    init(date: Date, price: Double) {
        self.timestamp = date.timeIntervalSince1970
        self.price = price
    }

    enum codec {
        static func encode(_ points: [MarketPoint]) -> String {
            guard let data = try? JSONEncoder().encode(points),
                  let string = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return string
        }

        static func decode(_ string: String) -> [MarketPoint] {
            guard let data = string.data(using: .utf8),
                  let points = try? JSONDecoder().decode([MarketPoint].self, from: data) else {
                return []
            }
            return points
        }
    }
}

struct MarketAsset: Identifiable, Hashable, Sendable {
    var id: String { symbol }

    let symbol: String
    let name: String
    let providerId: String
    let rank: Int
    let price: Double
    let currencyCode: String
    let priceChange24hPercent: Double
    let priceChange24hAmount: Double
    let marketCap: Double
    let volume24h: Double
    let circulatingSupply: Double
    let ath: Double
    let high24h: Double
    let low24h: Double
    let about: String
    let sparkline: [MarketPoint]
    let source: String
    let lastUpdatedAt: Date

    var isPositive: Bool { priceChange24hPercent >= 0 }

    func replacing(
        about: String? = nil,
        chart: [MarketPoint]? = nil,
        marketCap: Double? = nil,
        volume24h: Double? = nil,
        circulatingSupply: Double? = nil,
        ath: Double? = nil,
        high24h: Double? = nil,
        low24h: Double? = nil
    ) -> MarketAsset {
        MarketAsset(
            symbol: symbol,
            name: name,
            providerId: providerId,
            rank: rank,
            price: price,
            currencyCode: currencyCode,
            priceChange24hPercent: priceChange24hPercent,
            priceChange24hAmount: priceChange24hAmount,
            marketCap: marketCap ?? self.marketCap,
            volume24h: volume24h ?? self.volume24h,
            circulatingSupply: circulatingSupply ?? self.circulatingSupply,
            ath: ath ?? self.ath,
            high24h: high24h ?? self.high24h,
            low24h: low24h ?? self.low24h,
            about: about ?? self.about,
            sparkline: chart ?? sparkline,
            source: source,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    func converted(to currencyCode: String, rate: Double, source: String) -> MarketAsset {
        let normalizedCurrency = currencyCode.uppercased()
        guard currencyCode.uppercased() != self.currencyCode.uppercased(),
              rate.isFinite,
              rate > 0 else {
            return self
        }

        return MarketAsset(
            symbol: symbol,
            name: name,
            providerId: providerId,
            rank: rank,
            price: price * rate,
            currencyCode: normalizedCurrency,
            priceChange24hPercent: priceChange24hPercent,
            priceChange24hAmount: priceChange24hAmount * rate,
            marketCap: marketCap * rate,
            volume24h: volume24h * rate,
            circulatingSupply: circulatingSupply,
            ath: ath * rate,
            high24h: high24h * rate,
            low24h: low24h * rate,
            about: about,
            sparkline: sparkline.converted(rate: rate),
            source: source,
            lastUpdatedAt: lastUpdatedAt
        )
    }
}

private extension Array where Element == MarketPoint {
    func converted(rate: Double) -> [MarketPoint] {
        guard rate.isFinite, rate > 0 else { return self }
        return map { MarketPoint(date: $0.date, price: $0.price * rate) }
    }
}

struct MarketChartResponse: Sendable {
    let points: [MarketPoint]
    let currencyCode: String
    let source: String
}

enum MarketsSegment: String, CaseIterable, Identifiable {
    case top = "Top"
    case gainers = "Gainers"
    case losers = "Losers"
    case watchlist = "Watchlist"

    var id: String { rawValue }
}

enum MarketChartRange: String, CaseIterable, Identifiable {
    case oneHour = "1H"
    case oneDay = "1D"
    case oneWeek = "1W"
    case oneMonth = "1M"
    case oneYear = "1Y"

    var id: String { rawValue }

    var coinGeckoDays: String {
        switch self {
        case .oneHour, .oneDay: return "1"
        case .oneWeek: return "7"
        case .oneMonth: return "30"
        case .oneYear: return "365"
        }
    }

    var binanceInterval: String {
        switch self {
        case .oneHour: return "1m"
        case .oneDay: return "30m"
        case .oneWeek: return "4h"
        case .oneMonth: return "1d"
        case .oneYear: return "1w"
        }
    }

    var binanceLimit: Int {
        switch self {
        case .oneHour: return 60
        case .oneDay: return 48
        case .oneWeek: return 42
        case .oneMonth: return 30
        case .oneYear: return 52
        }
    }

    var coinbaseGranularity: Int {
        switch self {
        case .oneHour: return 60
        case .oneDay: return 900
        case .oneWeek: return 21_600
        case .oneMonth, .oneYear: return 86_400
        }
    }
}

struct MarketAssetDetail: Sendable {
    let about: String
    let marketCap: Double
    let volume24h: Double
    let circulatingSupply: Double
    let ath: Double
    let high24h: Double
    let low24h: Double
}

private struct MarketDescriptor: Hashable, Sendable {
    let symbol: String
    let name: String
    let coinGeckoId: String
    let coinbaseProduct: String?
    let binanceSymbol: String?
    let chain: SupportedChain?
    let fallbackAbout: String

    static func descriptor(for symbol: String) -> MarketDescriptor? {
        bySymbol[symbol.uppercased()]
    }

    static let all: [MarketDescriptor] = [
        .init(symbol: "BTC", name: "Bitcoin", coinGeckoId: "bitcoin", coinbaseProduct: "BTC-USD", binanceSymbol: "BTCUSDT", chain: .bitcoin, fallbackAbout: "Bitcoin is the original peer-to-peer digital currency secured by proof-of-work."),
        .init(symbol: "ETH", name: "Ethereum", coinGeckoId: "ethereum", coinbaseProduct: "ETH-USD", binanceSymbol: "ETHUSDT", chain: .ethereum, fallbackAbout: "Ethereum is a programmable blockchain for decentralized applications and tokens."),
        .init(symbol: "SOL", name: "Solana", coinGeckoId: "solana", coinbaseProduct: "SOL-USD", binanceSymbol: "SOLUSDT", chain: .solana, fallbackAbout: "Solana is a high-throughput smart-contract network optimized for low-fee applications."),
        .init(symbol: "BNB", name: "BNB", coinGeckoId: "binancecoin", coinbaseProduct: nil, binanceSymbol: "BNBUSDT", chain: .bnbChain, fallbackAbout: "BNB is the native asset of the BNB Chain ecosystem."),
        .init(symbol: "XRP", name: "XRP", coinGeckoId: "ripple", coinbaseProduct: "XRP-USD", binanceSymbol: "XRPUSDT", chain: .ripple, fallbackAbout: "XRP is the native asset used by XRP Ledger for settlement and fees."),
        .init(symbol: "DOGE", name: "Dogecoin", coinGeckoId: "dogecoin", coinbaseProduct: "DOGE-USD", binanceSymbol: "DOGEUSDT", chain: .dogecoin, fallbackAbout: "Dogecoin is a proof-of-work digital currency with fast, low-cost transfers."),
        .init(symbol: "TON", name: "Toncoin", coinGeckoId: "the-open-network", coinbaseProduct: nil, binanceSymbol: "TONUSDT", chain: .ton, fallbackAbout: "Toncoin is the native asset of The Open Network."),
        .init(symbol: "AVAX", name: "Avalanche", coinGeckoId: "avalanche-2", coinbaseProduct: "AVAX-USD", binanceSymbol: "AVAXUSDT", chain: .avalanche, fallbackAbout: "Avalanche is a smart-contract platform built around fast finality and subnet architecture."),
        .init(symbol: "LTC", name: "Litecoin", coinGeckoId: "litecoin", coinbaseProduct: "LTC-USD", binanceSymbol: "LTCUSDT", chain: .litecoin, fallbackAbout: "Litecoin is a proof-of-work digital currency derived from Bitcoin."),
        .init(symbol: "DOT", name: "Polkadot", coinGeckoId: "polkadot", coinbaseProduct: "DOT-USD", binanceSymbol: "DOTUSDT", chain: .polkadot, fallbackAbout: "Polkadot connects specialized blockchains through a shared security model."),
        .init(symbol: "SUI", name: "Sui", coinGeckoId: "sui", coinbaseProduct: "SUI-USD", binanceSymbol: "SUIUSDT", chain: .sui, fallbackAbout: "Sui is an object-centric layer-one blockchain built for high-performance applications."),
        .init(symbol: "NEAR", name: "NEAR Protocol", coinGeckoId: "near", coinbaseProduct: "NEAR-USD", binanceSymbol: "NEARUSDT", chain: .near, fallbackAbout: "NEAR is a proof-of-stake smart-contract network using sharded infrastructure."),
        .init(symbol: "BCH", name: "Bitcoin Cash", coinGeckoId: "bitcoin-cash", coinbaseProduct: "BCH-USD", binanceSymbol: "BCHUSDT", chain: .bitcoinCash, fallbackAbout: "Bitcoin Cash is a Bitcoin-family digital currency focused on low-fee payments."),
        .init(symbol: "TRX", name: "TRON", coinGeckoId: "tron", coinbaseProduct: nil, binanceSymbol: "TRXUSDT", chain: .tron, fallbackAbout: "TRON is a smart-contract network used for token transfers and decentralized applications."),
        .init(symbol: "APT", name: "Aptos", coinGeckoId: "aptos", coinbaseProduct: "APT-USD", binanceSymbol: "APTUSDT", chain: .aptos, fallbackAbout: "Aptos is a Move-based layer-one blockchain."),
        .init(symbol: "XLM", name: "Stellar", coinGeckoId: "stellar", coinbaseProduct: "XLM-USD", binanceSymbol: "XLMUSDT", chain: .stellar, fallbackAbout: "Stellar is a payments network for asset issuance and settlement."),
        .init(symbol: "POL", name: "Polygon", coinGeckoId: "polygon-ecosystem-token", coinbaseProduct: "POL-USD", binanceSymbol: "POLUSDT", chain: .polygon, fallbackAbout: "POL is the ecosystem token for Polygon networks."),
        .init(symbol: "CELO", name: "Celo", coinGeckoId: "celo", coinbaseProduct: "CELO-USD", binanceSymbol: "CELOUSDT", chain: .celo, fallbackAbout: "Celo is a mobile-first EVM network focused on payments and public goods."),
        .init(symbol: "USDC", name: "USD Coin", coinGeckoId: "usd-coin", coinbaseProduct: "USDC-USD", binanceSymbol: "USDCUSDT", chain: nil, fallbackAbout: "USD Coin is a regulated US dollar stablecoin."),
        .init(symbol: "USDT", name: "Tether", coinGeckoId: "tether", coinbaseProduct: nil, binanceSymbol: nil, chain: nil, fallbackAbout: "Tether is a US dollar stablecoin used across multiple blockchain networks."),
        .init(symbol: "DAI", name: "Dai", coinGeckoId: "dai", coinbaseProduct: "DAI-USD", binanceSymbol: "DAIUSDT", chain: nil, fallbackAbout: "Dai is a decentralized US dollar stablecoin.")
    ]

    private static let bySymbol: [String: MarketDescriptor] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.symbol, $0) })
    }()
}

// MARK: - View model

@MainActor
final class MarketsViewModel: ObservableObject {
    @Published private(set) var assets: [MarketAsset] = []
    @Published private(set) var watchlist: Set<String> = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let service = MarketDataService()
    private var activeCurrencyCode = CurrencyPreference.defaultCode

    func loadCached(from context: ModelContext) {
        let descriptor = FetchDescriptor<MarketAssetRecord>(
            sortBy: [SortDescriptor(\.rank, order: .forward)]
        )
        if let records = try? context.fetch(descriptor) {
            assets = records.map(\.snapshot)
        }
        watchlist = fetchWatchlist(from: context)
    }

    func repriceCachedAssets(context: ModelContext, currencyCode: String) async {
        let target = normalizedCurrencyCode(currencyCode)
        activeCurrencyCode = target
        await repriceCurrentAssets(to: target, context: context)
    }

    func refresh(context: ModelContext, currencyCode: String) async {
        let target = normalizedCurrencyCode(currencyCode)
        activeCurrencyCode = target
        isLoading = assets.isEmpty
        do {
            let fresh = try await service.fetchMarkets(currencyCode: target)
            guard activeCurrencyCode == target else { return }
            try upsert(fresh, in: context)
            assets = fresh.sorted { lhs, rhs in lhs.rank < rhs.rank }
            watchlist = fetchWatchlist(from: context)
            errorMessage = nil
        } catch {
            guard activeCurrencyCode == target else { return }
            loadCached(from: context)
            await repriceCurrentAssets(to: target, context: context)
            if assets.isEmpty {
                errorMessage = "Market data is unavailable. Pull to refresh when the network is back."
            } else {
                errorMessage = "Using saved market data. Pull to refresh for live prices."
            }
        }
        if activeCurrencyCode == target {
            isLoading = false
        }
    }

    func isWatchlisted(_ symbol: String) -> Bool {
        watchlist.contains(symbol.uppercased())
    }

    func toggleWatchlist(symbol: String, context: ModelContext) {
        let normalized = symbol.uppercased()
        if let record = watchRecord(symbol: normalized, in: context) {
            context.delete(record)
            watchlist.remove(normalized)
        } else {
            context.insert(MarketWatchlistRecord(symbol: normalized))
            watchlist.insert(normalized)
        }
        try? context.save()
    }

    func cachedChart(symbol: String, range: MarketChartRange, currencyCode: String, context: ModelContext) -> MarketChartResponse? {
        let key = MarketChartCacheRecord.key(symbol: symbol, range: range, currencyCode: normalizedCurrencyCode(currencyCode))
        var descriptor = FetchDescriptor<MarketChartCacheRecord>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first else { return nil }
        let points = MarketPoint.codec.decode(record.samplesJSON)
        guard !points.isEmpty else { return nil }
        return MarketChartResponse(points: points, currencyCode: record.currencyCode, source: record.source)
    }

    func cachedOrConvertedChart(symbol: String, range: MarketChartRange, currencyCode: String, context: ModelContext) async -> MarketChartResponse? {
        let target = normalizedCurrencyCode(currencyCode)
        if let exact = cachedChart(symbol: symbol, range: range, currencyCode: target, context: context) {
            return exact
        }

        let normalizedSymbol = symbol.uppercased()
        let rangeRaw = range.rawValue
        var descriptor = FetchDescriptor<MarketChartCacheRecord>(
            predicate: #Predicate { $0.symbol == normalizedSymbol && $0.rangeRaw == rangeRaw },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let record = try? context.fetch(descriptor).first else { return nil }
        let points = MarketPoint.codec.decode(record.samplesJSON)
        guard !points.isEmpty else { return nil }

        let sourceCurrency = record.currencyCode.uppercased()
        guard sourceCurrency != target else {
            return MarketChartResponse(points: points, currencyCode: record.currencyCode, source: record.source)
        }
        guard let conversion = try? await service.crossRate(from: sourceCurrency, to: target) else {
            return nil
        }

        let converted = points.converted(rate: conversion.rate)
        let source = "Saved chart data · \(conversion.source)"
        upsertChart(symbol: normalizedSymbol, range: range, currencyCode: target, samples: converted, source: source, context: context)
        return MarketChartResponse(points: converted, currencyCode: target, source: source)
    }

    func refreshChart(symbol: String, range: MarketChartRange, currencyCode: String, context: ModelContext) async throws -> MarketChartResponse {
        let response = try await service.fetchChart(symbol: symbol, range: range, currencyCode: normalizedCurrencyCode(currencyCode))
        upsertChart(symbol: symbol, range: range, currencyCode: response.currencyCode, samples: response.points, source: response.source, context: context)
        return response
    }

    func reprice(asset: MarketAsset, currencyCode: String, context: ModelContext) async -> MarketAsset {
        let target = normalizedCurrencyCode(currencyCode)
        guard asset.currencyCode.uppercased() != target else { return asset }
        guard let conversion = try? await service.crossRate(from: asset.currencyCode, to: target) else {
            return asset
        }
        let converted = asset.converted(
            to: target,
            rate: conversion.rate,
            source: "Saved market data · \(conversion.source)"
        )
        try? upsert([converted], in: context)
        if let index = assets.firstIndex(where: { $0.symbol == converted.symbol }) {
            assets[index] = converted
            assets.sort { lhs, rhs in lhs.rank < rhs.rank }
        }
        return converted
    }

    func refreshDetail(for asset: MarketAsset, currencyCode: String, context: ModelContext) async -> MarketAsset {
        let target = normalizedCurrencyCode(currencyCode)
        let repriced = await reprice(asset: asset, currencyCode: target, context: context)
        guard let detail = try? await service.fetchDetail(symbol: repriced.symbol, currencyCode: target) else {
            return repriced
        }
        let updated = repriced.replacing(
            about: detail.about.isEmpty ? nil : detail.about,
            marketCap: detail.marketCap > 0 ? detail.marketCap : nil,
            volume24h: detail.volume24h > 0 ? detail.volume24h : nil,
            circulatingSupply: detail.circulatingSupply > 0 ? detail.circulatingSupply : nil,
            ath: detail.ath > 0 ? detail.ath : nil,
            high24h: detail.high24h > 0 ? detail.high24h : nil,
            low24h: detail.low24h > 0 ? detail.low24h : nil
        )
        let symbol = repriced.symbol
        var descriptor = FetchDescriptor<MarketAssetRecord>(
            predicate: #Predicate { $0.symbol == symbol }
        )
        descriptor.fetchLimit = 1
        if let record = try? context.fetch(descriptor).first {
            record.apply(updated)
        } else {
            context.insert(MarketAssetRecord(asset: updated))
        }
        if context.hasChanges {
            try? context.save()
        }
        return updated
    }

    private func upsertChart(
        symbol: String,
        range: MarketChartRange,
        currencyCode: String,
        samples: [MarketPoint],
        source: String,
        context: ModelContext
    ) {
        let key = MarketChartCacheRecord.key(symbol: symbol, range: range, currencyCode: currencyCode)
        var descriptor = FetchDescriptor<MarketChartCacheRecord>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        descriptor.fetchLimit = 1
        if let record = try? context.fetch(descriptor).first {
            record.apply(samples: samples, source: source)
        } else {
            context.insert(
                MarketChartCacheRecord(
                    symbol: symbol,
                    range: range,
                    currencyCode: currencyCode,
                    samples: samples,
                    source: source
                )
            )
        }
        try? context.save()
    }

    private func upsert(_ assets: [MarketAsset], in context: ModelContext) throws {
        let records = (try? context.fetch(FetchDescriptor<MarketAssetRecord>())) ?? []
        var bySymbol = Dictionary(uniqueKeysWithValues: records.map { ($0.symbol, $0) })
        for asset in assets {
            if let record = bySymbol[asset.symbol] {
                record.apply(asset)
            } else {
                let record = MarketAssetRecord(asset: asset)
                context.insert(record)
                bySymbol[asset.symbol] = record
            }
        }
        if context.hasChanges {
            try context.save()
        }
    }

    private func repriceCurrentAssets(to target: String, context: ModelContext) async {
        guard !assets.isEmpty else { return }

        let sourceCurrencies = Set(assets.map { $0.currencyCode.uppercased() })
            .filter { $0 != target }
        guard !sourceCurrencies.isEmpty else {
            watchlist = fetchWatchlist(from: context)
            return
        }

        var conversions: [String: (rate: Double, source: String)] = [:]
        for sourceCurrency in sourceCurrencies {
            if let conversion = try? await service.crossRate(from: sourceCurrency, to: target) {
                conversions[sourceCurrency] = conversion
            }
        }
        guard !conversions.isEmpty, activeCurrencyCode == target else { return }

        var didConvert = false
        let converted = assets.map { asset in
            let sourceCurrency = asset.currencyCode.uppercased()
            guard let conversion = conversions[sourceCurrency] else {
                return asset
            }
            didConvert = true
            return asset.converted(
                to: target,
                rate: conversion.rate,
                source: "Saved market data · \(conversion.source)"
            )
        }
        guard didConvert else { return }

        try? upsert(converted, in: context)
        assets = converted.sorted { lhs, rhs in lhs.rank < rhs.rank }
        watchlist = fetchWatchlist(from: context)
    }

    private func normalizedCurrencyCode(_ currencyCode: String) -> String {
        let uppercased = currencyCode.uppercased()
        return CurrencyPreference.currency(for: uppercased)?.code ?? CurrencyPreference.defaultCode
    }

    private func fetchWatchlist(from context: ModelContext) -> Set<String> {
        let records = (try? context.fetch(FetchDescriptor<MarketWatchlistRecord>())) ?? []
        return Set(records.map { $0.symbol.uppercased() })
    }

    private func watchRecord(symbol: String, in context: ModelContext) -> MarketWatchlistRecord? {
        var descriptor = FetchDescriptor<MarketWatchlistRecord>(
            predicate: #Predicate { $0.symbol == symbol }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

// MARK: - Screens

struct MarketsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @StateObject private var model = MarketsViewModel()
    @State private var segment: MarketsSegment = .top
    @State private var searchText: String = ""
    private let watchlistSwipeTip = MarketWatchlistSwipeTip()

    private var visibleAssets: [MarketAsset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = model.assets.filter { asset in
            query.isEmpty
                || asset.symbol.lowercased().contains(query)
                || asset.name.lowercased().contains(query)
        }

        switch segment {
        case .top:
            return base.sorted { lhs, rhs in lhs.rank < rhs.rank }
        case .gainers:
            return base.sorted { lhs, rhs in lhs.priceChange24hPercent > rhs.priceChange24hPercent }
        case .losers:
            return base.sorted { lhs, rhs in lhs.priceChange24hPercent < rhs.priceChange24hPercent }
        case .watchlist:
            return base
                .filter { model.isWatchlisted($0.symbol) }
                .sorted { lhs, rhs in lhs.rank < rhs.rank }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Market list", selection: $segment) {
                    ForEach(MarketsSegment.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if model.isLoading && visibleAssets.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 260)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if visibleAssets.isEmpty {
                Section {
                    marketsEmptyState
                }
            } else {
                Section {
                    TipView(watchlistSwipeTip)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: UniSpacing.m,
                            bottom: UniSpacing.s,
                            trailing: UniSpacing.m
                        ))
                        .task(id: layoutDirection) {
                            MarketWatchlistSwipeTip.isRightToLeft = layoutDirection == .rightToLeft
                        }
                }

                Section {
                    ForEach(visibleAssets) { asset in
                        NavigationLink(value: asset) {
                            MarketAssetRow(asset: asset, isWatchlisted: model.isWatchlisted(asset.symbol))
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10))
                        // `.trailing` is intentionally semantic, not a hard-coded
                        // side: iOS reveals it by swiping left in LTR languages
                        // and by swiping right in RTL languages.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                model.toggleWatchlist(symbol: asset.symbol, context: modelContext)
                            } label: {
                                Label(model.isWatchlisted(asset.symbol) ? "Remove" : "Watch", systemImage: model.isWatchlisted(asset.symbol) ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                    }
                    .listRowBackground(UniColors.List.rowBackground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle("Markets")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search coins or tokens"
        )
        .navigationDestination(for: MarketAsset.self) { asset in
            MarketDetailView(asset: asset, model: model)
        }
        .refreshable {
            await model.refresh(context: modelContext, currencyCode: currencyCode)
        }
        .task {
            model.loadCached(from: modelContext)
            await model.repriceCachedAssets(context: modelContext, currencyCode: currencyCode)
            if model.assets.isEmpty {
                await model.refresh(context: modelContext, currencyCode: currencyCode)
            }
        }
        .onChange(of: currencyCode) { _, newValue in
            Task {
                await model.repriceCachedAssets(context: modelContext, currencyCode: newValue)
                await model.refresh(context: modelContext, currencyCode: newValue)
            }
        }
        .alert("Markets", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .uniHaptic(.selection, trigger: segment)
    }

    private var marketsEmptyState: some View {
        if segment == .watchlist {
            UniListEmptyState(
                title: "Your watchlist is empty.",
                detail: "Swipe an asset in Markets to add it here.",
                mark: .icon(systemName: "star"),
                minHeight: 360
            )
        } else if model.errorMessage != nil {
            UniListEmptyState(
                title: "Markets unavailable.",
                detail: "Pull to refresh when a market data provider is reachable.",
                mark: .icon(systemName: "wifi.exclamationmark"),
                minHeight: 360
            )
        } else {
            UniListEmptyState(
                title: "No market data yet.",
                detail: "Pull to refresh live prices.",
                mark: .icon(systemName: "chart.line.uptrend.xyaxis"),
                minHeight: 360
            )
        }
    }
}

private struct MarketWatchlistSwipeTip: Tip {
    @Parameter
    static var isRightToLeft: Bool = false

    var title: Text {
        Text("Tip")
    }

    var message: Text? {
        if Self.isRightToLeft {
            Text("Swipe a coin row to the right to add or remove it from your watchlist.")
        } else {
            Text("Swipe a coin row to the left to add or remove it from your watchlist.")
        }
    }

    var image: Image? {
        Image(systemName: "star")
    }

    var options: [any TipOption] {
        [Tips.MaxDisplayCount(1)]
    }
}

struct MarketDetailView: View {
    let model: MarketsViewModel
    @Environment(\.modelContext) private var modelContext
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    @State private var asset: MarketAsset
    @State private var range: MarketChartRange = .oneDay
    @State private var chart: [MarketPoint] = []
    @State private var chartCurrencyCode: String
    @State private var scrubbedPoint: MarketPoint?
    @State private var isLoadingChart: Bool = false
    @State private var chartError: Bool = false
    @State private var isShowingSend: Bool = false
    @State private var sendPath = NavigationPath()

    init(asset: MarketAsset, model: MarketsViewModel) {
        self.model = model
        _asset = State(initialValue: asset)
        _chartCurrencyCode = State(initialValue: asset.currencyCode.uppercased())
    }

    private var displayCurrencyCode: String {
        CurrencyPreference.currency(for: currencyCode)?.code ?? CurrencyPreference.defaultCode
    }

    private var chartPointsForDisplay: [MarketPoint] {
        let normalizedDisplayCode = displayCurrencyCode.uppercased()
        if !chart.isEmpty, chartCurrencyCode.uppercased() == normalizedDisplayCode {
            return chart
        }
        if asset.currencyCode.uppercased() == normalizedDisplayCode {
            return asset.sparkline
        }
        return []
    }

    private var displayedPrice: Double {
        scrubbedPoint?.price ?? asset.price
    }

    private var displayedChangeAmount: Double {
        guard let first = chartPointsForDisplay.first?.price, let point = scrubbedPoint else {
            return asset.priceChange24hAmount
        }
        return point.price - first
    }

    private var displayedChangePercent: Double {
        guard let first = chartPointsForDisplay.first?.price, let point = scrubbedPoint, first != 0 else {
            return asset.priceChange24hPercent
        }
        return ((point.price - first) / first) * 100
    }

    private var displayedIsPositive: Bool { displayedChangePercent >= 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                detailHeader
                priceBlock
                chartBlock
                statsBlock
                aboutBlock
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 110)
        }
        .background(UniColors.Background.primary)
        .navigationTitle(asset.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.toggleWatchlist(symbol: asset.symbol, context: modelContext)
                } label: {
                    Image(systemName: model.isWatchlisted(asset.symbol) ? "star.fill" : "star")
                }
                .tint(model.isWatchlisted(asset.symbol) ? .yellow : nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            detailFooter
        }
        .sheet(isPresented: $isShowingSend, onDismiss: { sendPath = NavigationPath() }) {
            SendNetworkFirstView(navigationPath: $sendPath, assetPrefill: sendPrefill)
                .uniAppEnvironment()
                .presentationBackground(UniColors.Background.primary)
        }
        .task {
            await loadCachedOrConvertedChart()
            await refreshDetail()
        }
        .task(id: range) {
            await loadCachedOrConvertedChart()
            await refreshChart()
        }
        .onChange(of: currencyCode) { _, _ in
            scrubbedPoint = nil
            chart = []
            chartCurrencyCode = displayCurrencyCode.uppercased()
            Task {
                asset = await model.reprice(asset: asset, currencyCode: displayCurrencyCode, context: modelContext)
                await loadCachedOrConvertedChart()
                await refreshDetail()
            }
        }
        .uniHaptic(.selection, trigger: range)
    }

    private var detailHeader: some View {
        HStack(spacing: 14) {
            MarketCoinIcon(symbol: asset.symbol, size: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(UniColors.Text.primary)
                Text(asset.name)
                    .font(.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            Spacer()
        }
    }

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MarketFormatting.currency(displayedPrice, code: displayCurrencyCode))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: displayedPrice))
                .foregroundStyle(UniColors.Text.primary)

            HStack(spacing: 10) {
                Text(MarketFormatting.percent(displayedChangePercent))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(displayedIsPositive ? UniColors.Text.success : UniColors.Text.error)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((displayedIsPositive ? UniColors.Text.success : UniColors.Text.error).opacity(0.12), in: Capsule())

                Text("\(displayedIsPositive ? "+" : "")\(MarketFormatting.currency(displayedChangeAmount, code: displayCurrencyCode)) today")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(UniColors.Text.secondary)
            }
        }
        .animation(.smooth(duration: 0.22), value: displayedPrice)
    }

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            MarketAreaChart(points: chartPointsForDisplay, isPositive: displayedIsPositive, selectedPoint: $scrubbedPoint)
                .frame(maxWidth: .infinity)
                .aspectRatio(1.55, contentMode: .fit)
                .frame(minHeight: 220, maxHeight: 320)
                .overlay {
                    if isLoadingChart && chartPointsForDisplay.isEmpty {
                        ProgressView()
                    } else if chartError && chartPointsForDisplay.isEmpty {
                        ContentUnavailableView(
                            "Chart unavailable",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Saved chart data will appear here after a successful refresh.")
                        )
                    }
                }

            Picker("Chart range", selection: $range) {
                ForEach(MarketChartRange.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var statsBlock: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MarketStatTile(title: "Market cap", value: MarketFormatting.compactCurrency(asset.marketCap, code: displayCurrencyCode))
            MarketStatTile(title: "24h volume", value: MarketFormatting.compactCurrency(asset.volume24h, code: displayCurrencyCode))
            MarketStatTile(title: "Circulating", value: MarketFormatting.compactNumber(asset.circulatingSupply, suffix: asset.symbol))
            MarketStatTile(title: "ATH", value: MarketFormatting.currency(asset.ath, code: displayCurrencyCode))
            MarketStatTile(title: "24h high", value: MarketFormatting.currency(asset.high24h, code: displayCurrencyCode))
            MarketStatTile(title: "24h low", value: MarketFormatting.currency(asset.low24h, code: displayCurrencyCode))
        }
    }

    private var aboutBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About \(asset.name)")
                .font(.headline)
            Text(asset.about.isEmpty ? (MarketDescriptor.descriptor(for: asset.symbol)?.fallbackAbout ?? "") : asset.about)
                .font(.body)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detailFooter: some View {
        UniButton(verbatim: "Send \(asset.symbol)", variant: .primary) {
            isShowingSend = true
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var sendPrefill: SendView.AssetPrefill {
        SendView.AssetPrefill(
            symbol: asset.symbol,
            name: asset.name,
            nativeChain: MarketDescriptor.descriptor(for: asset.symbol)?.chain
        )
    }

    private func loadCachedChart() {
        guard let cached = model.cachedChart(symbol: asset.symbol, range: range, currencyCode: displayCurrencyCode, context: modelContext) else {
            return
        }
        chart = cached.points
        chartCurrencyCode = cached.currencyCode.uppercased()
    }

    private func loadCachedOrConvertedChart() async {
        if let cached = await model.cachedOrConvertedChart(symbol: asset.symbol, range: range, currencyCode: displayCurrencyCode, context: modelContext) {
            chart = cached.points
            chartCurrencyCode = cached.currencyCode.uppercased()
        } else {
            loadCachedChart()
        }
    }

    private func refreshDetail() async {
        asset = await model.refreshDetail(for: asset, currencyCode: displayCurrencyCode, context: modelContext)
        await refreshChart()
    }

    private func refreshChart() async {
        isLoadingChart = true
        chartError = false
        do {
            let response = try await model.refreshChart(symbol: asset.symbol, range: range, currencyCode: displayCurrencyCode, context: modelContext)
            if !response.points.isEmpty {
                chart = response.points
                chartCurrencyCode = response.currencyCode.uppercased()
                scrubbedPoint = nil
            }
        } catch {
            chartError = true
        }
        isLoadingChart = false
    }
}

// MARK: - Rows and components

private struct MarketAssetRow: View {
    let asset: MarketAsset
    let isWatchlisted: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MarketCoinIcon(symbol: asset.symbol, size: 42)
                .frame(width: 42, height: 42)

            assetIdentity
                .frame(minWidth: 82, idealWidth: 136, maxWidth: 178, alignment: .leading)
                .layoutPriority(2)

            MarketSparkline(points: asset.sparkline, isPositive: asset.isPositive)
                .frame(minWidth: 56, idealWidth: 96, maxWidth: .infinity, minHeight: 30, idealHeight: 34, maxHeight: 40, alignment: .center)
                .layoutPriority(1)

            priceStack
                .frame(minWidth: 104, idealWidth: 128, maxWidth: 170, alignment: .trailing)
                .layoutPriority(3)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var assetIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(asset.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
                if isWatchlisted {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            Text("Market cap \(MarketFormatting.compactCurrency(asset.marketCap, code: asset.currencyCode))")
                .font(.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
        }
    }

    private var priceStack: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(MarketFormatting.currency(asset.price, code: asset.currencyCode))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .allowsTightening(true)
                .contentTransition(.numericText(value: asset.price))
            Text(MarketFormatting.percent(asset.priceChange24hPercent))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(asset.isPositive ? UniColors.Text.success : UniColors.Text.error)
                .lineLimit(1)
        }
    }
}

private struct MarketCoinIcon: View {
    let symbol: String
    let size: CGFloat

    private var chain: SupportedChain? {
        MarketDescriptor.descriptor(for: symbol)?.chain
    }

    var body: some View {
        Group {
            if let chain {
                CoinMark(chain: chain, tokenSymbol: chain.ticker)
            } else if MarketDescriptor.descriptor(for: symbol) != nil {
                CoinMark(chain: .ethereum, tokenSymbol: symbol)
            } else {
                Circle()
                    .fill(UniColors.Fill.secondary)
                    .overlay {
                        Text(String(symbol.prefix(3)).uppercased())
                            .font(.system(size: max(11, size * 0.28), weight: .bold, design: .rounded))
                            .foregroundStyle(UniColors.Text.secondary)
                            .minimumScaleFactor(0.7)
                            .padding(4)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct MarketSparkline: View {
    let points: [MarketPoint]
    let isPositive: Bool

    var body: some View {
        Chart {
            ForEach(chartSamples) { sample in
                LineMark(
                    x: .value("Sample", sample.x),
                    y: .value("Price", sample.y)
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(isPositive ? UniColors.Text.success : UniColors.Text.error)
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private var chartSamples: [MarketChartSample] {
        MarketChartProjection.samples(from: points, verticalPadding: 0.04, trimsOutliers: true)
    }
}

private struct MarketAreaChart: View {
    let points: [MarketPoint]
    let isPositive: Bool
    @Binding var selectedPoint: MarketPoint?
    @State private var selectedIndex: Int = -1

    var body: some View {
        Chart {
            ForEach(chartSamples) { sample in
                AreaMark(
                    x: .value("Time", sample.x),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Price", sample.y)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(
                    .linearGradient(
                        colors: [
                            chartColor.opacity(0.20),
                            chartColor.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", sample.x),
                    y: .value("Price", sample.y)
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(chartColor)
            }

            if let selected = selectedMarketPoint {
                RuleMark(x: .value("Selected time", selected.x))
                    .foregroundStyle(UniColors.Separator.regular)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(
                    x: .value("Selected time", selected.x),
                    y: .value("Selected price", selected.y)
                )
                .symbolSize(72)
                .foregroundStyle(chartColor)
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .chartOverlay { _ in
            GeometryReader { proxy in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let samples = chartSamples
                                guard samples.count > 1 else { return }
                                let ratio = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                                let index = Int(round(ratio * CGFloat(samples.count - 1)))
                                if index != selectedIndex {
                                    selectedIndex = index
                                    selectedPoint = samples[index].point
                                }
                            }
                            .onEnded { _ in
                                selectedIndex = -1
                                selectedPoint = nil
                            }
                    )
            }
        }
        .uniHaptic(.selection, trigger: selectedIndex)
    }

    private var chartColor: Color {
        isPositive ? UniColors.Text.success : UniColors.Text.error
    }

    private var chartSamples: [MarketChartSample] {
        MarketChartProjection.samples(from: points)
    }

    private var selectedMarketPoint: MarketChartSample? {
        let samples = chartSamples
        guard selectedIndex >= 0, selectedIndex < samples.count else { return nil }
        return samples[selectedIndex]
    }
}

private struct MarketChartSample: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let point: MarketPoint
}

private enum MarketChartProjection {
    static func samples(
        from points: [MarketPoint],
        verticalPadding: Double = 0.1,
        trimsOutliers: Bool = false
    ) -> [MarketChartSample] {
        let clean = sanitized(points)
        guard !clean.isEmpty else { return [] }

        if clean.count == 1, let point = clean.first {
            return [
                MarketChartSample(id: 0, x: 0, y: 0.5, point: point),
                MarketChartSample(id: 1, x: 1, y: 0.5, point: point)
            ]
        }

        let prices = clean.map(\.price)
        let domain = priceDomain(for: prices, trimsOutliers: trimsOutliers)
        let span = domain.upper - domain.lower
        let yValues: [Double]
        if span <= max(abs(domain.upper) * 0.000_001, 0.000_001) {
            yValues = Array(repeating: 0.5, count: clean.count)
        } else {
            let padding = min(max(verticalPadding, 0), 0.45)
            let usableHeight = 1 - (padding * 2)
            yValues = prices.map { price in
                // Keep a little air at the top and bottom so the native Chart
                // never visually collapses into the card edges.
                let clamped = min(max(price, domain.lower), domain.upper)
                return padding + ((clamped - domain.lower) / span) * usableHeight
            }
        }

        let first = clean.first?.timestamp ?? 0
        let last = clean.last?.timestamp ?? first
        let timeSpan = last - first

        return clean.indices.map { index in
            let x: Double
            if timeSpan > 0 {
                x = max(0, min(1, (clean[index].timestamp - first) / timeSpan))
            } else {
                x = Double(index) / Double(max(clean.count - 1, 1))
            }
            return MarketChartSample(id: index, x: x, y: yValues[index], point: clean[index])
        }
    }

    private static func sanitized(_ points: [MarketPoint]) -> [MarketPoint] {
        let sorted = points
            .filter { $0.timestamp.isFinite && $0.price.isFinite && $0.price > 0 }
            .sorted { $0.timestamp < $1.timestamp }

        var output: [MarketPoint] = []
        output.reserveCapacity(sorted.count)
        for point in sorted {
            if let last = output.last, last.timestamp == point.timestamp {
                output[output.count - 1] = point
            } else {
                output.append(point)
            }
        }
        return output
    }

    private static func priceDomain(for prices: [Double], trimsOutliers: Bool) -> (lower: Double, upper: Double) {
        let minPrice = prices.min() ?? 0
        let maxPrice = prices.max() ?? 0
        guard trimsOutliers, prices.count >= 8 else {
            return (minPrice, maxPrice)
        }

        let sorted = prices.sorted()
        let lower = percentile(sorted, 0.08)
        let upper = percentile(sorted, 0.92)
        guard upper > lower else {
            return (minPrice, maxPrice)
        }
        return (lower, upper)
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }

        let clamped = min(max(fraction, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }

        let weight = position - Double(lowerIndex)
        return (sorted[lowerIndex] * (1 - weight)) + (sorted[upperIndex] * weight)
    }
}

private struct MarketStatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(UniColors.Text.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(UniColors.Background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Formatting

private enum MarketFormatting {
    static func currency(_ value: Double, code: String) -> String {
        if value == 0 { return Decimal(0).formatted(.currency(code: code).precision(.fractionLength(2))) }
        let absolute = abs(value)
        let decimals: Int
        if absolute >= 100 { decimals = 2 }
        else if absolute >= 1 { decimals = 3 }
        else { decimals = 6 }
        return Decimal(value).formatted(.currency(code: code).precision(.fractionLength(0...decimals)))
    }

    static func compactCurrency(_ value: Double, code: String) -> String {
        guard value > 0 else { return "—" }
        let compact = compact(value)
        return "\(currency(compact.value, code: code))\(compact.suffix)"
    }

    static func compactNumber(_ value: Double, suffix: String) -> String {
        guard value > 0 else { return "—" }
        let compact = compact(value)
        let number = compact.value.formatted(.number.precision(.fractionLength(0...2)))
        return "\(number)\(compact.suffix) \(suffix)"
    }

    static func percent(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(value.formatted(.number.precision(.fractionLength(2))))%"
    }

    private static func compact(_ value: Double) -> (value: Double, suffix: String) {
        let absolute = abs(value)
        if absolute >= 1_000_000_000_000 { return (value / 1_000_000_000_000, "T") }
        if absolute >= 1_000_000_000 { return (value / 1_000_000_000, "B") }
        if absolute >= 1_000_000 { return (value / 1_000_000, "M") }
        if absolute >= 1_000 { return (value / 1_000, "K") }
        return (value, "")
    }
}

// MARK: - Service

private actor MarketDataService {
    private let fxService = MarketFXService()

    func fetchMarkets(currencyCode: String) async throws -> [MarketAsset] {
        let normalized = currencyCode.uppercased()
        var errors: [any Error] = []

        do {
            let assets = try await fetchCoinGeckoMarkets(currencyCode: normalized)
            if !assets.isEmpty { return assets }
        } catch {
            errors.append(error)
        }

        do {
            if let assets = try await fetchCoinMarketCapMarkets(currencyCode: normalized), !assets.isEmpty {
                return assets
            }
        } catch {
            errors.append(error)
        }

        do {
            let assets = try await fetchBinanceMarkets(currencyCode: normalized)
            if !assets.isEmpty { return assets }
        } catch {
            errors.append(error)
        }

        do {
            let assets = try await fetchCoinbaseMarkets(currencyCode: normalized)
            if !assets.isEmpty { return assets }
        } catch {
            errors.append(error)
        }

        throw errors.first ?? URLError(.cannotLoadFromNetwork)
    }

    func fetchChart(symbol: String, range: MarketChartRange, currencyCode: String) async throws -> MarketChartResponse {
        let normalized = currencyCode.uppercased()
        var errors: [any Error] = []

        do {
            let conversion = try await usdConversion(to: normalized)
            let points = try await fetchCoinGeckoChart(symbol: symbol, range: range, usdRate: conversion.rate)
            if !points.isEmpty {
                return MarketChartResponse(points: points, currencyCode: conversion.currencyCode, source: "CoinGecko · \(conversion.source)")
            }
        } catch {
            errors.append(error)
        }

        do {
            let conversion = try await usdConversion(to: normalized)
            let points = try await fetchBinanceChart(symbol: symbol, range: range, usdRate: conversion.rate)
            if !points.isEmpty {
                return MarketChartResponse(points: points, currencyCode: conversion.currencyCode, source: "Binance · \(conversion.source)")
            }
        } catch {
            errors.append(error)
        }

        do {
            let conversion = try await usdConversion(to: normalized)
            let points = try await fetchCoinbaseChart(symbol: symbol, range: range, usdRate: conversion.rate)
            if !points.isEmpty {
                return MarketChartResponse(points: points, currencyCode: conversion.currencyCode, source: "Coinbase · \(conversion.source)")
            }
        } catch {
            errors.append(error)
        }

        throw errors.first ?? URLError(.cannotLoadFromNetwork)
    }

    func fetchDetail(symbol: String, currencyCode: String) async throws -> MarketAssetDetail {
        guard let descriptor = MarketDescriptor.descriptor(for: symbol) else {
            throw URLError(.badURL)
        }
        let conversion = try await usdConversion(to: currencyCode.uppercased())
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.coingecko.com"
        components.path = "/api/v3/coins/\(descriptor.coinGeckoId)"
        components.queryItems = [
            URLQueryItem(name: "localization", value: "false"),
            URLQueryItem(name: "tickers", value: "false"),
            URLQueryItem(name: "market_data", value: "true"),
            URLQueryItem(name: "community_data", value: "false"),
            URLQueryItem(name: "developer_data", value: "false"),
            URLQueryItem(name: "sparkline", value: "false")
        ]
        let row = try await decode(CoingeckoCoinDetail.self, from: components.url!)
        return MarketAssetDetail(
            about: stripHTML(row.description.en),
            marketCap: usd(row.market_data?.market_cap, rate: conversion.rate),
            volume24h: usd(row.market_data?.total_volume, rate: conversion.rate),
            circulatingSupply: row.market_data?.circulating_supply ?? 0,
            ath: usd(row.market_data?.ath, rate: conversion.rate),
            high24h: usd(row.market_data?.high_24h, rate: conversion.rate),
            low24h: usd(row.market_data?.low_24h, rate: conversion.rate)
        )
    }

    func crossRate(from sourceCode: String, to targetCode: String) async throws -> (rate: Double, source: String) {
        let source = sourceCode.uppercased()
        let target = targetCode.uppercased()
        guard source != target else { return (1, "FX") }

        if source == "USD" {
            let targetRate = try await usdConversion(to: target)
            return (targetRate.rate, targetRate.source)
        }
        if target == "USD" {
            let sourceRate = try await usdConversion(to: source)
            guard sourceRate.rate > 0 else { throw URLError(.cannotParseResponse) }
            return (1 / sourceRate.rate, sourceRate.source)
        }

        let sourceRate = try await usdConversion(to: source)
        let targetRate = try await usdConversion(to: target)
        guard sourceRate.rate > 0 else { throw URLError(.cannotParseResponse) }
        return (targetRate.rate / sourceRate.rate, "\(sourceRate.source) -> \(targetRate.source)")
    }

    private func fetchCoinGeckoMarkets(currencyCode: String) async throws -> [MarketAsset] {
        let conversion = try await usdConversion(to: currencyCode)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.coingecko.com"
        components.path = "/api/v3/coins/markets"
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: "usd"),
            URLQueryItem(name: "ids", value: MarketDescriptor.all.map(\.coinGeckoId).joined(separator: ",")),
            URLQueryItem(name: "order", value: "market_cap_desc"),
            URLQueryItem(name: "per_page", value: "250"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "sparkline", value: "true"),
            URLQueryItem(name: "price_change_percentage", value: "24h")
        ]
        let rows = try await decode([CoingeckoMarket].self, from: components.url!)
        let byId = Dictionary(uniqueKeysWithValues: MarketDescriptor.all.map { ($0.coinGeckoId, $0) })
        let now = Date()

        return rows.compactMap { row in
            guard let descriptor = byId[row.id] else { return nil }
            let sparkline = sparklinePoints(prices: row.sparkline_in_7d?.price ?? [], endingAt: now, duration: 7 * 24 * 60 * 60)
            return MarketAsset(
                symbol: descriptor.symbol,
                name: row.name,
                providerId: row.id,
                rank: row.market_cap_rank ?? 999,
                price: (row.current_price ?? 0) * conversion.rate,
                currencyCode: conversion.currencyCode,
                priceChange24hPercent: row.price_change_percentage_24h ?? 0,
                priceChange24hAmount: (row.price_change_24h ?? 0) * conversion.rate,
                marketCap: (row.market_cap ?? 0) * conversion.rate,
                volume24h: (row.total_volume ?? 0) * conversion.rate,
                circulatingSupply: row.circulating_supply ?? 0,
                ath: (row.ath ?? 0) * conversion.rate,
                high24h: (row.high_24h ?? 0) * conversion.rate,
                low24h: (row.low_24h ?? 0) * conversion.rate,
                about: descriptor.fallbackAbout,
                sparkline: sparkline.map { MarketPoint(date: $0.date, price: $0.price * conversion.rate) },
                source: "CoinGecko · \(conversion.source)",
                lastUpdatedAt: row.lastUpdatedDate ?? now
            )
        }
    }

    private func fetchCoinMarketCapMarkets(currencyCode: String) async throws -> [MarketAsset]? {
        guard let key = coinMarketCapAPIKey else { return nil }
        let conversion = try await usdConversion(to: currencyCode)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "pro-api.coinmarketcap.com"
        components.path = "/v1/cryptocurrency/quotes/latest"
        components.queryItems = [
            URLQueryItem(name: "symbol", value: MarketDescriptor.all.map(\.symbol).joined(separator: ",")),
            URLQueryItem(name: "convert", value: "USD")
        ]
        let rows = try await decode(
            CoinMarketCapQuotes.self,
            from: components.url!,
            headers: ["X-CMC_PRO_API_KEY": key]
        )
        let now = Date()
        return MarketDescriptor.all.compactMap { descriptor in
            guard let row = rows.data[descriptor.symbol] else { return nil }
            guard let quote = row.quote["USD"] else { return nil }
            let usdPrice = quote.price ?? 0
            let percent = quote.percent_change_24h ?? 0
            let previous = percent == -100 ? usdPrice : usdPrice / (1 + percent / 100)
            return MarketAsset(
                symbol: descriptor.symbol,
                name: row.name,
                providerId: descriptor.coinGeckoId,
                rank: row.cmc_rank ?? 999,
                price: usdPrice * conversion.rate,
                currencyCode: conversion.currencyCode,
                priceChange24hPercent: percent,
                priceChange24hAmount: (usdPrice - previous) * conversion.rate,
                marketCap: (quote.market_cap ?? 0) * conversion.rate,
                volume24h: (quote.volume_24h ?? 0) * conversion.rate,
                circulatingSupply: row.circulating_supply ?? 0,
                ath: 0,
                high24h: 0,
                low24h: 0,
                about: descriptor.fallbackAbout,
                sparkline: [],
                source: "CoinMarketCap · \(conversion.source)",
                lastUpdatedAt: now
            )
        }
    }

    private func fetchBinanceMarkets(currencyCode: String) async throws -> [MarketAsset] {
        let conversion = try await usdConversion(to: currencyCode)
        let descriptors = MarketDescriptor.all.filter { $0.binanceSymbol != nil }
        let symbols = "[" + descriptors.compactMap { $0.binanceSymbol }.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.binance.com"
        components.path = "/api/v3/ticker/24hr"
        components.queryItems = [URLQueryItem(name: "symbols", value: symbols)]
        let rows = try await decode([BinanceTicker].self, from: components.url!)
        let rowBySymbol = Dictionary(uniqueKeysWithValues: rows.map { ($0.symbol, $0) })

        var assets: [MarketAsset] = []
        for (index, descriptor) in descriptors.enumerated() {
            guard let binanceSymbol = descriptor.binanceSymbol,
                  let row = rowBySymbol[binanceSymbol],
                  let price = Double(row.lastPrice) else { continue }
            let sparkline = (try? await fetchBinanceChart(symbol: descriptor.symbol, range: .oneDay, usdRate: conversion.rate)) ?? []
            assets.append(
                MarketAsset(
                    symbol: descriptor.symbol,
                    name: descriptor.name,
                    providerId: descriptor.coinGeckoId,
                    rank: index + 1,
                    price: price * conversion.rate,
                    currencyCode: conversion.currencyCode,
                    priceChange24hPercent: Double(row.priceChangePercent) ?? 0,
                    priceChange24hAmount: (Double(row.priceChange) ?? 0) * conversion.rate,
                    marketCap: 0,
                    volume24h: (Double(row.quoteVolume) ?? 0) * conversion.rate,
                    circulatingSupply: 0,
                    ath: 0,
                    high24h: (Double(row.highPrice) ?? 0) * conversion.rate,
                    low24h: (Double(row.lowPrice) ?? 0) * conversion.rate,
                    about: descriptor.fallbackAbout,
                    sparkline: sparkline,
                    source: "Binance · \(conversion.source)",
                    lastUpdatedAt: Date()
                )
            )
        }
        return assets
    }

    private func fetchCoinbaseMarkets(currencyCode: String) async throws -> [MarketAsset] {
        let conversion = try await usdConversion(to: currencyCode)
        var assets: [MarketAsset] = []
        for (index, descriptor) in MarketDescriptor.all.enumerated() {
            guard let product = descriptor.coinbaseProduct else { continue }
            do {
                let stats = try await fetchCoinbaseStats(product: product)
                let last = Double(stats.last) ?? Double(stats.open) ?? 0
                let open = Double(stats.open) ?? last
                let change = last - open
                let sparkline = (try? await fetchCoinbaseChart(symbol: descriptor.symbol, range: .oneDay, usdRate: conversion.rate)) ?? []
                assets.append(
                    MarketAsset(
                        symbol: descriptor.symbol,
                        name: descriptor.name,
                        providerId: descriptor.coinGeckoId,
                        rank: index + 1,
                        price: last * conversion.rate,
                        currencyCode: conversion.currencyCode,
                        priceChange24hPercent: open == 0 ? 0 : (change / open) * 100,
                        priceChange24hAmount: change * conversion.rate,
                        marketCap: 0,
                        volume24h: (Double(stats.volume) ?? 0) * last * conversion.rate,
                        circulatingSupply: 0,
                        ath: 0,
                        high24h: (Double(stats.high) ?? 0) * conversion.rate,
                        low24h: (Double(stats.low) ?? 0) * conversion.rate,
                        about: descriptor.fallbackAbout,
                        sparkline: sparkline,
                        source: "Coinbase · \(conversion.source)",
                        lastUpdatedAt: Date()
                    )
                )
            } catch {
                continue
            }
        }
        return assets
    }

    private func fetchCoinGeckoChart(symbol: String, range: MarketChartRange, usdRate: Double) async throws -> [MarketPoint] {
        guard let descriptor = MarketDescriptor.descriptor(for: symbol) else { throw URLError(.badURL) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.coingecko.com"
        components.path = "/api/v3/coins/\(descriptor.coinGeckoId)/market_chart"
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: "usd"),
            URLQueryItem(name: "days", value: range.coinGeckoDays)
        ]
        let row = try await decode(CoingeckoChart.self, from: components.url!)
        let points = row.prices.compactMap { pair -> MarketPoint? in
            guard pair.count >= 2 else { return nil }
            return MarketPoint(date: Date(timeIntervalSince1970: pair[0] / 1000), price: pair[1] * usdRate)
        }
        if range == .oneHour {
            let cutoff = Date().addingTimeInterval(-60 * 60).timeIntervalSince1970
            return points.filter { $0.timestamp >= cutoff }
        }
        return points
    }

    private func fetchBinanceChart(symbol: String, range: MarketChartRange, usdRate: Double) async throws -> [MarketPoint] {
        guard let descriptor = MarketDescriptor.descriptor(for: symbol),
              let marketSymbol = descriptor.binanceSymbol else {
            throw URLError(.badURL)
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.binance.com"
        components.path = "/api/v3/uiKlines"
        components.queryItems = [
            URLQueryItem(name: "symbol", value: marketSymbol),
            URLQueryItem(name: "interval", value: range.binanceInterval),
            URLQueryItem(name: "limit", value: "\(range.binanceLimit)")
        ]
        let rows = try await decode([BinanceKline].self, from: components.url!)
        return rows.compactMap { row in
            guard let close = Double(row.close) else { return nil }
            return MarketPoint(date: Date(timeIntervalSince1970: row.openTime / 1000), price: close * usdRate)
        }
    }

    private func fetchCoinbaseChart(symbol: String, range: MarketChartRange, usdRate: Double) async throws -> [MarketPoint] {
        guard let descriptor = MarketDescriptor.descriptor(for: symbol),
              let product = descriptor.coinbaseProduct else {
            throw URLError(.badURL)
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.exchange.coinbase.com"
        components.path = "/products/\(product)/candles"
        components.queryItems = [
            URLQueryItem(name: "granularity", value: "\(range.coinbaseGranularity)")
        ]
        let rows = try await decode([CoinbaseCandle].self, from: components.url!)
        return rows
            .sorted { $0.timestamp < $1.timestamp }
            .map { MarketPoint(date: Date(timeIntervalSince1970: $0.timestamp), price: $0.close * usdRate) }
    }

    private func fetchCoinbaseStats(product: String) async throws -> CoinbaseStats {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.exchange.coinbase.com"
        components.path = "/products/\(product)/stats"
        return try await decode(CoinbaseStats.self, from: components.url!)
    }

    private func usdConversion(to currencyCode: String) async throws -> (rate: Double, currencyCode: String, source: String) {
        let normalized = currencyCode.uppercased()
        guard normalized != "USD" else { return (1, "USD", "USD") }
        let fx = try await fxService.usdRate(to: normalized)
        return (fx.rate, fx.currencyCode, fx.source)
    }
}

private actor MarketFXService {
    struct FXRate: Sendable {
        let rate: Double
        let currencyCode: String
        let source: String
        let fetchedAt: Date
    }

    private var memory: [String: FXRate] = [:]

    func usdRate(to currencyCode: String) async throws -> FXRate {
        let normalized = currencyCode.uppercased()
        if normalized == "USD" {
            return FXRate(rate: 1, currencyCode: "USD", source: "USD", fetchedAt: Date())
        }
        if let cached = memory[normalized],
           Date().timeIntervalSince(cached.fetchedAt) < 10 * 60 {
            return cached
        }

        var errors: [any Error] = []
        do {
            let rate = try await fetchCoinbaseRate(to: normalized)
            memory[normalized] = rate
            return rate
        } catch {
            errors.append(error)
        }
        do {
            let rate = try await fetchOpenERRate(to: normalized)
            memory[normalized] = rate
            return rate
        } catch {
            errors.append(error)
        }
        do {
            let rate = try await fetchFrankfurterRate(to: normalized)
            memory[normalized] = rate
            return rate
        } catch {
            errors.append(error)
        }
        throw errors.first ?? URLError(.cannotLoadFromNetwork)
    }

    private func fetchCoinbaseRate(to currencyCode: String) async throws -> FXRate {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.coinbase.com"
        components.path = "/v2/exchange-rates"
        components.queryItems = [URLQueryItem(name: "currency", value: "USD")]
        let row = try await decode(CoinbaseFiatRates.self, from: components.url!)
        guard let value = row.data.rates[currencyCode], let rate = Double(value), rate > 0 else {
            throw URLError(.cannotParseResponse)
        }
        return FXRate(rate: rate, currencyCode: currencyCode, source: "Coinbase FX", fetchedAt: Date())
    }

    private func fetchOpenERRate(to currencyCode: String) async throws -> FXRate {
        let url = URL(string: "https://open.er-api.com/v6/latest/USD")!
        let row = try await decode(OpenERAPIResponse.self, from: url)
        guard row.result == "success",
              let rate = row.rates[currencyCode],
              rate > 0 else {
            throw URLError(.cannotParseResponse)
        }
        return FXRate(rate: rate, currencyCode: currencyCode, source: "OpenER FX", fetchedAt: Date())
    }

    private func fetchFrankfurterRate(to currencyCode: String) async throws -> FXRate {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.frankfurter.dev"
        components.path = "/v1/latest"
        components.queryItems = [
            URLQueryItem(name: "from", value: "USD"),
            URLQueryItem(name: "to", value: currencyCode)
        ]
        let row = try await decode(FrankfurterResponse.self, from: components.url!)
        guard let rate = row.rates[currencyCode], rate > 0 else {
            throw URLError(.cannotParseResponse)
        }
        return FXRate(rate: rate, currencyCode: currencyCode, source: "Frankfurter FX", fetchedAt: Date())
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.apertureData(
            for: request,
            family: "fx",
            operation: "\(url.host ?? "api") \(url.path)",
            metadata: ["source": "MarketFXService"]
        )
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension MarketDataService {
    var coinMarketCapAPIKey: String? {
        let defaults = UserDefaults.standard.string(forKey: "CoinMarketCapAPIKey")
        let plist = Bundle.main.object(forInfoDictionaryKey: "CoinMarketCapAPIKey") as? String
        let key = (defaults?.isEmpty == false ? defaults : plist)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    private func sparklinePoints(prices: [Double], endingAt end: Date, duration: TimeInterval) -> [MarketPoint] {
        guard prices.count > 1 else { return [] }
        let start = end.addingTimeInterval(-duration)
        let step = duration / Double(prices.count - 1)
        return prices.enumerated().map { index, price in
            MarketPoint(date: start.addingTimeInterval(Double(index) * step), price: price)
        }
    }

    private func stripHTML(_ input: String) -> String {
        input
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func usd(_ values: [String: Double]?, rate: Double) -> Double {
        guard let value = values?["usd"], value > 0 else { return 0 }
        return value * rate
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.apertureData(
            for: request,
            family: "markets",
            operation: "\(url.host ?? "api") \(url.path)",
            metadata: ["source": "MarketDataService"]
        )
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - DTOs

private struct CoingeckoMarket: Decodable {
    let id: String
    let symbol: String
    let name: String
    let current_price: Double?
    let market_cap: Double?
    let market_cap_rank: Int?
    let total_volume: Double?
    let high_24h: Double?
    let low_24h: Double?
    let price_change_24h: Double?
    let price_change_percentage_24h: Double?
    let circulating_supply: Double?
    let ath: Double?
    let last_updated: String?
    let sparkline_in_7d: Sparkline?

    var lastUpdatedDate: Date? {
        guard let last_updated else { return nil }
        return ISO8601DateFormatter().date(from: last_updated)
    }

    struct Sparkline: Decodable {
        let price: [Double]
    }
}

private struct CoingeckoChart: Decodable {
    let prices: [[Double]]
}

private struct CoingeckoCoinDetail: Decodable {
    let description: Description
    let market_data: MarketData?

    struct Description: Decodable {
        let en: String
    }

    struct MarketData: Decodable {
        let market_cap: [String: Double]?
        let total_volume: [String: Double]?
        let circulating_supply: Double?
        let ath: [String: Double]?
        let high_24h: [String: Double]?
        let low_24h: [String: Double]?
    }
}

private struct CoinMarketCapQuotes: Decodable {
    let data: [String: Coin]

    struct Coin: Decodable {
        let name: String
        let cmc_rank: Int?
        let circulating_supply: Double?
        let quote: [String: Quote]
    }

    struct Quote: Decodable {
        let price: Double?
        let volume_24h: Double?
        let percent_change_24h: Double?
        let market_cap: Double?
        let last_updated: String?

        var currencyCode: String? { nil }
    }
}

private struct BinanceTicker: Decodable {
    let symbol: String
    let priceChange: String
    let priceChangePercent: String
    let lastPrice: String
    let highPrice: String
    let lowPrice: String
    let quoteVolume: String
}

private struct BinanceKline: Decodable {
    let openTime: Double
    let close: String

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        openTime = try container.decode(Double.self)
        _ = try container.decode(String.self)
        _ = try container.decode(String.self)
        _ = try container.decode(String.self)
        close = try container.decode(String.self)
    }
}

private struct CoinbaseStats: Decodable {
    let open: String
    let high: String
    let low: String
    let last: String
    let volume: String
}

private struct CoinbaseCandle: Decodable {
    let timestamp: Double
    let close: Double

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        timestamp = try container.decode(Double.self)
        _ = try container.decode(Double.self)
        _ = try container.decode(Double.self)
        _ = try container.decode(Double.self)
        close = try container.decode(Double.self)
    }
}

private struct CoinbaseFiatRates: Decodable {
    let data: Rates

    struct Rates: Decodable {
        let rates: [String: String]
    }
}

private struct OpenERAPIResponse: Decodable {
    let result: String
    let rates: [String: Double]
}

private struct FrankfurterResponse: Decodable {
    let rates: [String: Double]
}
