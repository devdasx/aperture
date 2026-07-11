import SwiftUI
import UIKit

/// Canonical visual size for coin, token, and network marks in app
/// content. The Markets list established this as the row-logo size;
/// other wallet surfaces use the same value so asset identity does not
/// jump between screens.
enum AssetLogoMetrics {
    static let standard: CGFloat = 42
}

/// Stabro-style logo renderer for coins, tokens, and networks.
///
/// Resolution order is intentionally simple and shared everywhere:
/// local asset catalog name (`token_*`, `coin_*`, `network_*`) first,
/// then one Trust Wallet CDN URL cached through `AssetLogoDiskCache`,
/// then a neutral initials chip. No alternate-provider probing and no
/// symbol-cross-chain fallback.
struct CoinMark: View {
    let chain: SupportedChain
    let tokenSymbol: String
    var contract: String? = nil

    @State private var cachedImage: UIImage?
    @State private var loadFailed = false

    private var logoURL: URL? {
        if let contract, !contract.isEmpty {
            return AssetLogoSource.tokenLogoURL(chain: chain, contract: contract)
        }
        if let stablecoinURL = AssetLogoSource.stablecoinLogoURL(symbol: tokenSymbol) {
            return stablecoinURL
        }
        return AssetLogoSource.networkLogoURL(chain: chain)
    }

    var body: some View {
        Group {
            if let cachedImage {
                Image(uiImage: cachedImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                localFallback
            }
        }
        .task(id: logoURL) {
            guard !loadFailed else { return }
            await loadImage()
        }
    }

    @ViewBuilder
    private var localFallback: some View {
        if let assetName = localAssetName, UIImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            initialsChip
        }
    }

    private var localAssetName: String? {
        if isNativeCoin {
            if let networkName = chain.logoAssetName, UIImage(named: networkName) != nil {
                return networkName
            }
            return AssetLogoSource.nativeTokenAssetName(symbol: tokenSymbol)
        }
        if let stablecoin = AssetLogoSource.stablecoinAssetName(symbol: tokenSymbol) {
            return stablecoin
        }
        return AssetLogoSource.nativeTokenAssetName(symbol: tokenSymbol)
    }

    private var isNativeCoin: Bool {
        contract == nil && tokenSymbol.uppercased() == chain.ticker.uppercased()
    }

    private func loadImage() async {
        guard let logoURL else {
            await MainActor.run { loadFailed = true }
            return
        }
        if let image = AssetLogoDiskCache.shared.image(for: logoURL) {
            await MainActor.run {
                cachedImage = image
                loadFailed = false
            }
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: logoURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else {
                await MainActor.run { loadFailed = true }
                return
            }
            AssetLogoDiskCache.shared.store(image, for: logoURL)
            await MainActor.run {
                cachedImage = image
                loadFailed = false
            }
        } catch {
            await MainActor.run { loadFailed = true }
        }
    }

    private var initialsChip: some View {
        Circle()
            .fill(AssetLogoSource.brandColor(symbol: tokenSymbol, chain: chain).opacity(0.14))
            .overlay {
                Text(initials)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(AssetLogoSource.brandColor(symbol: tokenSymbol, chain: chain))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 2)
            }
    }

    private var initials: String {
        let trimmed = tokenSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "-" }
        return String(trimmed.prefix(3)).uppercased()
    }
}

// MARK: - Stabro-style GRDB cache

final class AssetLogoDiskCache: @unchecked Sendable {
    static let shared = AssetLogoDiskCache()

    private let memoryCache = NSCache<NSString, UIImage>()

    private init() {
        memoryCache.countLimit = 100
    }

    func image(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        guard let image = AssetLogoCacheStore.image(for: url) else {
            return nil
        }
        memoryCache.setObject(image, forKey: key as NSString)
        return image
    }

    func store(_ image: UIImage, for url: URL) {
        let key = cacheKey(for: url)
        memoryCache.setObject(image, forKey: key as NSString)
        AssetLogoCacheStore.store(image, for: url)
    }

    private func cacheKey(for url: URL) -> String {
        let hash = url.absoluteString.utf8.reduce(into: UInt64(5381)) { result, byte in
            result = result &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }
}

// MARK: - Source mapping

enum AssetLogoSource {
    private static let cdnBase = "https://assets-cdn.trustwallet.com/blockchains"

    static func tokenLogoURL(chain: SupportedChain, contract: String) -> URL? {
        guard let slug = trustWalletSlug(for: chain) else { return nil }
        let normalized = chain.family == .evm
            ? Keccak256.eip55Checksum(contract: contract)
            : contract
        return URL(string: "\(cdnBase)/\(slug)/assets/\(normalized)/logo.png")
    }

    static func networkLogoURL(chain: SupportedChain) -> URL? {
        guard let slug = trustWalletSlug(for: chain) else { return nil }
        return URL(string: "\(cdnBase)/\(slug)/info/logo.png")
    }

    static func stablecoinLogoURL(symbol: String) -> URL? {
        switch symbol.uppercased() {
        case "USDT": return URL(string: "\(cdnBase)/ethereum/assets/0xdAC17F958D2ee523a2206206994597C13D831ec7/logo.png")
        case "USDC": return URL(string: "\(cdnBase)/ethereum/assets/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/logo.png")
        case "USDS": return URL(string: "\(cdnBase)/ethereum/assets/0xdC035D45d973E3EC169d2276DDab16f1e407384F/logo.png")
        case "DAI": return URL(string: "\(cdnBase)/ethereum/assets/0x6B175474E89094C44Da98b954EedeAC495271d0F/logo.png")
        case "USDE": return URL(string: "\(cdnBase)/ethereum/assets/0x4c9EDD5852cd905f086C759E8383e09bff1E68B3/logo.png")
        case "TUSD": return URL(string: "\(cdnBase)/ethereum/assets/0x0000000000085d4780B73119b644AE5ecd22b376/logo.png")
        case "USDP": return URL(string: "\(cdnBase)/ethereum/assets/0x8E870D67F660D95d5be530380D0eC0bd388289E1/logo.png")
        case "PYUSD": return URL(string: "\(cdnBase)/ethereum/assets/0x6c3ea9036406852006290770BEdFcAbA0e23A0e8/logo.png")
        case "FDUSD": return URL(string: "\(cdnBase)/ethereum/assets/0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409/logo.png")
        case "USD1": return URL(string: "\(cdnBase)/ethereum/assets/0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5/logo.png")
        case "USDD": return URL(string: "\(cdnBase)/tron/assets/TPYmHEhy5n8TCEfYGqW2rPxsghSfzghPDn/logo.png")
        case "STETH": return URL(string: "\(cdnBase)/ethereum/assets/0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84/logo.png")
        case "WETH": return URL(string: "\(cdnBase)/ethereum/assets/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2/logo.png")
        case "WBTC": return URL(string: "\(cdnBase)/ethereum/assets/0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599/logo.png")
        case "USDG": return URL(string: "\(cdnBase)/ethereum/assets/0xe343167631d89b6ffc58b88d6b7fb0228795491d/logo.png")
        case "EURC": return URL(string: "\(cdnBase)/ethereum/assets/0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c/logo.png")
        case "FRAX": return URL(string: "\(cdnBase)/ethereum/assets/0x853d955aCEf822Db058eb8505911ED77F175b99e/logo.png")
        case "GUSD": return URL(string: "\(cdnBase)/ethereum/assets/0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd/logo.png")
        case "AUSD": return URL(string: "\(cdnBase)/ethereum/assets/0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a/logo.png")
        case "USD0": return URL(string: "\(cdnBase)/ethereum/assets/0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5/logo.png")
        case "USDF": return URL(string: "\(cdnBase)/ethereum/assets/0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2/logo.png")
        case "USDAI": return URL(string: "\(cdnBase)/arbitrum/assets/0x0a1a1a107e45b7ced86833863f482bc5f4ed82ef/logo.png")
        case "DUSD": return URL(string: "\(cdnBase)/smartchain/assets/0xaF44a1E76f56eE12ADBB7Ba8AcD3CBD474888122/logo.png")
        case "LISUSD": return URL(string: "\(cdnBase)/smartchain/assets/0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5/logo.png")
        case "RLUSD": return URL(string: "https://coin-images.coingecko.com/coins/images/39651/large/RLUSD_200x200_%281%29.png")
        default: return nil
        }
    }

    static func stablecoinAssetName(symbol: String) -> String? {
        let key = symbol.lowercased()
        let names = ["usdt", "usdc", "usds", "dai", "usde", "tusd", "usdp", "pyusd", "fdusd", "usd1", "usdd", "steth", "weth", "wbtc", "usdg", "eurc", "frax", "gusd", "ausd", "usd0", "usdf", "usdai", "dusd", "lisusd", "rlusd"]
        return names.contains(key) ? "coin_\(key)" : nil
    }

    static func nativeTokenAssetName(symbol: String) -> String? {
        switch symbol.uppercased() {
        case "BTC": return "token_btc"
        case "ETH": return "token_eth"
        case "BNB": return "token_bnb"
        case "SOL": return "token_sol"
        case "TRX": return "token_trx"
        case "APT": return "token_apt"
        case "NEAR": return "token_near"
        case "DOT": return "token_dot"
        case "TON": return "token_ton"
        case "POL": return "token_pol"
        case "AVAX": return "token_avax"
        case "CELO": return "token_celo"

        default: return nil
        }
    }

    static func brandColor(symbol: String, chain: SupportedChain) -> Color {
        let key = symbol.uppercased()
        switch key {
        case "BTC": return rgb(0xF7931A)
        case "ETH", "WETH", "STETH": return rgb(0x627EEA)
        case "BNB": return rgb(0xF3BA2F)
        case "SOL": return rgb(0x9945FF)
        case "TRX": return rgb(0xFF0013)
        case "APT": return rgb(0x2DD8A3)
        case "NEAR": return .black
        case "DOT": return rgb(0xE6007A)
        case "TON": return rgb(0x0098EA)
        case "POL": return rgb(0x8247E5)
        case "AVAX": return rgb(0xE84142)
        case "CELO": return rgb(0x8CA100)

        case "XRP", "XLM": return rgb(0x23292F)
        case "DOGE": return rgb(0xC2A633)
        case "LTC": return rgb(0x345D9D)
        case "BCH": return rgb(0x8DC351)
        case "SUI": return rgb(0x6FBCF0)
        case "USDT": return rgb(0x26A17B)
        case "USDC", "EURC": return rgb(0x2775CA)
        case "DAI": return rgb(0xF5AC37)
        default: return chainAccent(chain)
        }
    }

    static func trustWalletSlug(for chain: SupportedChain) -> String? {
        switch chain {
        case .bitcoin: return "bitcoin"
        case .bitcoinCash: return "bitcoincash"
        case .litecoin: return "litecoin"
        case .dogecoin: return "doge"
        case .ethereum: return "ethereum"
        case .arbitrum: return "arbitrum"
        case .base: return "base"
        case .optimism: return "optimism"
        case .scroll: return "scroll"
        case .zkSync: return "zksync"
        case .polygon: return "polygon"
        case .bnbChain: return "smartchain"
        case .opBNB: return "opbnb"
        case .avalanche: return "avalanchec"
        case .celo: return "celo"
        case .aptos: return "aptos"
        case .near: return "near"
        case .polkadot: return "polkadot"
        case .ripple: return "ripple"
        case .solana: return "solana"
        case .stellar: return "stellar"
        case .sui: return "sui"
        case .ton: return "ton"
        case .tron: return "tron"
        }
    }

    private static func chainAccent(_ chain: SupportedChain) -> Color {
        switch chain {
        case .arbitrum: return rgb(0x2D374B)
        case .base: return rgb(0x0052FF)
        case .optimism: return rgb(0xFF0420)
        case .scroll: return rgb(0xA87F4D)
        case .zkSync: return rgb(0x7878FA)
        case .opBNB: return rgb(0xF0B90B)
        default: return UniColors.Text.secondary
        }
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1
        )
    }
}
