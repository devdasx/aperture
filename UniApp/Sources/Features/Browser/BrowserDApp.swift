import Foundation
import SwiftUI

/// A browsable dApp in Aperture's in-app directory. The directory is a
/// curated catalog of real, currently-live dApps across categories — the
/// user filters it with the category chips on `BrowserHomeView` and taps a
/// tile to open the dApp in `BrowserSessionView` (where the real EIP-1193
/// provider injects `window.ethereum` / `window.solana`).
///
    /// **Logos.** The favicon resolves at runtime from the dApp's own host,
    /// with the letter-chip fallback in `BrowserFaviconView`. The eight
    /// curated `BrowserFavorite`s additionally ship bundled logos so they're
    /// always present even offline.
///
/// Generated 2026-06-17 from a parallel category-by-category compilation
/// (268 dApps). Curated, not exhaustive — real entries only.
struct BrowserDApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let host: String
    let category: BrowserDAppCategory

    /// Site-owned favicon, with letter fallback handled by
    /// `BrowserFaviconView`. Build-time-agnostic — fetched on demand + cached.
    var faviconURL: URL? {
        URL(string: "https://\(host)/favicon.ico")
    }

    init(_ name: String, _ urlString: String, _ host: String, _ category: BrowserDAppCategory) {
        self.id = host
        self.name = name
        // Compile-time-constant URLs validated by the generator; a typo is
        // caught on first build, never at runtime.
        self.url = URL(string: urlString)!
        self.host = host
        self.category = category
    }
}

/// dApp directory categories — the Browser home's filter chips.
enum BrowserDAppCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case swap
    case bridge
    case lend
    case earn
    case perps
    case nft
    case stablecoin
    case naming
    case social
    case gaming
    case tools

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .swap: return "Swap"
        case .bridge: return "Bridge"
        case .lend: return "Lend"
        case .earn: return "Earn"
        case .perps: return "Perps"
        case .nft: return "NFT"
        case .stablecoin: return "Stablecoins"
        case .naming: return "Names"
        case .social: return "Social"
        case .gaming: return "Gaming"
        case .tools: return "Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .swap: return "arrow.left.arrow.right"
        case .bridge: return "arrow.triangle.swap"
        case .lend: return "building.columns"
        case .earn: return "percent"
        case .perps: return "chart.line.uptrend.xyaxis"
        case .nft: return "sparkles"
        case .stablecoin: return "dollarsign.circle"
        case .naming: return "at"
        case .social: return "bubble.left.and.bubble.right"
        case .gaming: return "gamecontroller"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

extension BrowserDApp {
    /// Every curated dApp, deduplicated by host.
    static let directory: [BrowserDApp] = [
        BrowserDApp("Uniswap", "https://app.uniswap.org", "app.uniswap.org", .swap),
        BrowserDApp("Jupiter", "https://jup.ag", "jup.ag", .swap),
        BrowserDApp("PancakeSwap", "https://pancakeswap.finance/swap", "pancakeswap.finance", .swap),
        BrowserDApp("1inch", "https://app.1inch.io", "app.1inch.io", .swap),
        BrowserDApp("Curve", "https://curve.finance", "curve.finance", .swap),
        BrowserDApp("SushiSwap", "https://www.sushi.com/swap", "www.sushi.com", .swap),
        BrowserDApp("Raydium", "https://raydium.io/swap", "raydium.io", .swap),
        BrowserDApp("Balancer", "https://balancer.fi", "balancer.fi", .swap),
        BrowserDApp("Matcha (0x)", "https://matcha.xyz", "matcha.xyz", .swap),
        BrowserDApp("CowSwap", "https://swap.cow.fi", "swap.cow.fi", .swap),
        BrowserDApp("ParaSwap", "https://app.paraswap.io", "app.paraswap.io", .swap),
        BrowserDApp("Aerodrome", "https://aerodrome.finance", "aerodrome.finance", .swap),
        BrowserDApp("Velodrome", "https://velodrome.finance", "velodrome.finance", .swap),
        BrowserDApp("Orca", "https://www.orca.so", "www.orca.so", .swap),
        BrowserDApp("Camelot", "https://app.camelot.exchange", "app.camelot.exchange", .swap),
        BrowserDApp("GMX", "https://app.gmx.io", "app.gmx.io", .swap),
        BrowserDApp("Trader Joe (LFJ)", "https://lfj.gg/avalanche/trade", "lfj.gg", .swap),
        BrowserDApp("KyberSwap", "https://kyberswap.com", "kyberswap.com", .swap),
        BrowserDApp("Cetus", "https://app.cetus.zone", "app.cetus.zone", .swap),
        BrowserDApp("DODO", "https://app.dodoex.io", "app.dodoex.io", .swap),
        BrowserDApp("Maverick", "https://app.mav.xyz", "app.mav.xyz", .swap),
        BrowserDApp("Ref Finance", "https://app.ref.finance", "app.ref.finance", .swap),
        BrowserDApp("Osmosis", "https://app.osmosis.zone", "app.osmosis.zone", .swap),
        BrowserDApp("SunSwap", "https://sunswap.com", "sunswap.com", .swap),
        BrowserDApp("STON.fi", "https://app.ston.fi", "app.ston.fi", .swap),
        BrowserDApp("Meteora", "https://app.meteora.ag", "app.meteora.ag", .swap),
        BrowserDApp("OpenOcean", "https://app.openocean.finance", "app.openocean.finance", .swap),
        BrowserDApp("Drift", "https://app.drift.trade", "app.drift.trade", .swap),
        BrowserDApp("Stargate Finance", "https://stargate.finance/bridge", "stargate.finance", .bridge),
        BrowserDApp("Across Protocol", "https://app.across.to", "app.across.to", .bridge),
        BrowserDApp("Synapse Protocol", "https://synapseprotocol.com", "synapseprotocol.com", .bridge),
        BrowserDApp("Hop Protocol", "https://app.hop.exchange", "app.hop.exchange", .bridge),
        BrowserDApp("Celer cBridge", "https://cbridge.celer.network", "cbridge.celer.network", .bridge),
        BrowserDApp("Wormhole Portal", "https://portalbridge.com", "portalbridge.com", .bridge),
        BrowserDApp("Allbridge", "https://core.allbridge.io", "core.allbridge.io", .bridge),
        BrowserDApp("Orbiter Finance", "https://www.orbiter.finance", "www.orbiter.finance", .bridge),
        BrowserDApp("deBridge", "https://app.debridge.finance", "app.debridge.finance", .bridge),
        BrowserDApp("Rhino.fi", "https://app.rhino.fi", "app.rhino.fi", .bridge),
        BrowserDApp("Bungee (Socket)", "https://www.bungee.exchange", "www.bungee.exchange", .bridge),
        BrowserDApp("Jumper Exchange", "https://jumper.exchange", "jumper.exchange", .bridge),
        BrowserDApp("Squid", "https://app.squidrouter.com", "app.squidrouter.com", .bridge),
        BrowserDApp("Polygon Portal", "https://portal.polygon.technology", "portal.polygon.technology", .bridge),
        BrowserDApp("Arbitrum Bridge", "https://bridge.arbitrum.io", "bridge.arbitrum.io", .bridge),
        BrowserDApp("Optimism Bridge", "https://app.optimism.io/bridge", "app.optimism.io", .bridge),
        BrowserDApp("Base Bridge", "https://bridge.base.org", "bridge.base.org", .bridge),
        BrowserDApp("zkSync Bridge", "https://portal.zksync.io/bridge", "portal.zksync.io", .bridge),
        BrowserDApp("Scroll Bridge", "https://scroll.io/bridge", "scroll.io", .bridge),
        BrowserDApp("Multichain Wan (Wanchain)", "https://bridge.wanchain.org", "bridge.wanchain.org", .bridge),
        BrowserDApp("Mayan Finance", "https://swap.mayan.finance", "swap.mayan.finance", .bridge),
        BrowserDApp("Portal Bridge (Wormhole Connect)", "https://www.portalbridge.com", "www.portalbridge.com", .bridge),
        BrowserDApp("Symbiosis", "https://app.symbiosis.finance", "app.symbiosis.finance", .bridge),
        BrowserDApp("Owlto Finance", "https://owlto.finance", "owlto.finance", .bridge),
        BrowserDApp("Meson", "https://app.meson.fi", "app.meson.fi", .bridge),
        BrowserDApp("THORChain (THORSwap)", "https://thorswap.finance", "thorswap.finance", .bridge),
        BrowserDApp("Chainflip (Swap)", "https://swap.chainflip.io", "swap.chainflip.io", .bridge),
        BrowserDApp("Gas.zip", "https://www.gas.zip", "www.gas.zip", .bridge),
        BrowserDApp("Aave", "https://app.aave.com", "app.aave.com", .lend),
        BrowserDApp("Compound", "https://app.compound.finance", "app.compound.finance", .lend),
        BrowserDApp("MakerDAO (Sky)", "https://app.sky.money", "app.sky.money", .lend),
        BrowserDApp("Morpho", "https://app.morpho.org", "app.morpho.org", .lend),
        BrowserDApp("Spark", "https://app.spark.fi", "app.spark.fi", .lend),
        BrowserDApp("Venus", "https://app.venus.io", "app.venus.io", .lend),
        BrowserDApp("Euler", "https://app.euler.finance", "app.euler.finance", .lend),
        BrowserDApp("Fluid (Instadapp)", "https://fluid.io", "fluid.io", .lend),
        BrowserDApp("Liquity", "https://app.liquity.org", "app.liquity.org", .lend),
        BrowserDApp("Radiant Capital", "https://app.radiant.capital", "app.radiant.capital", .lend),
        BrowserDApp("Benqi", "https://app.benqi.fi", "app.benqi.fi", .lend),
        BrowserDApp("JustLend", "https://justlend.just.network", "justlend.just.network", .lend),
        BrowserDApp("Kamino", "https://app.kamino.finance", "app.kamino.finance", .lend),
        BrowserDApp("Save (Solend)", "https://save.finance", "save.finance", .lend),
        BrowserDApp("MarginFi", "https://app.marginfi.com", "app.marginfi.com", .lend),
        BrowserDApp("Aries Markets", "https://ariesmarkets.xyz", "ariesmarkets.xyz", .lend),
        BrowserDApp("Echelon Market", "https://app.echelon.market", "app.echelon.market", .lend),
        BrowserDApp("SuiLend", "https://suilend.fi", "suilend.fi", .lend),
        BrowserDApp("Scallop", "https://app.scallop.io", "app.scallop.io", .lend),
        BrowserDApp("Navi Protocol", "https://app.naviprotocol.io", "app.naviprotocol.io", .lend),
        BrowserDApp("Moonwell", "https://moonwell.fi", "moonwell.fi", .lend),
        BrowserDApp("Silo Finance", "https://app.silo.finance", "app.silo.finance", .lend),
        BrowserDApp("Dolomite", "https://app.dolomite.io", "app.dolomite.io", .lend),
        BrowserDApp("Layerbank", "https://layerbank.finance", "layerbank.finance", .lend),
        BrowserDApp("Lido", "https://stake.lido.fi", "stake.lido.fi", .earn),
        BrowserDApp("Rocket Pool", "https://stake.rocketpool.net", "stake.rocketpool.net", .earn),
        BrowserDApp("EigenLayer", "https://app.eigenlayer.xyz", "app.eigenlayer.xyz", .earn),
        BrowserDApp("ether.fi", "https://app.ether.fi", "app.ether.fi", .earn),
        BrowserDApp("Renzo", "https://app.renzoprotocol.com", "app.renzoprotocol.com", .earn),
        BrowserDApp("Kelp DAO", "https://kelpdao.xyz", "kelpdao.xyz", .earn),
        BrowserDApp("Pendle", "https://app.pendle.finance", "app.pendle.finance", .earn),
        BrowserDApp("Yearn", "https://yearn.fi", "yearn.fi", .earn),
        BrowserDApp("Beefy", "https://app.beefy.com", "app.beefy.com", .earn),
        BrowserDApp("Convex Finance", "https://www.convexfinance.com", "www.convexfinance.com", .earn),
        BrowserDApp("Frax Finance", "https://app.frax.finance", "app.frax.finance", .earn),
        BrowserDApp("Stader", "https://www.staderlabs.com", "www.staderlabs.com", .earn),
        BrowserDApp("Marinade", "https://app.marinade.finance", "app.marinade.finance", .earn),
        BrowserDApp("Jito", "https://www.jito.network", "www.jito.network", .earn),
        BrowserDApp("Sanctum", "https://app.sanctum.so", "app.sanctum.so", .earn),
        BrowserDApp("Symbiotic", "https://app.symbiotic.fi", "app.symbiotic.fi", .earn),
        BrowserDApp("Babylon", "https://btcstaking.babylonlabs.io", "btcstaking.babylonlabs.io", .earn),
        BrowserDApp("Lombard", "https://www.lombard.finance", "www.lombard.finance", .earn),
        BrowserDApp("Origin Protocol", "https://app.originprotocol.com", "app.originprotocol.com", .earn),
        BrowserDApp("Coinbase Wrapped Staked ETH (cbETH)", "https://www.coinbase.com/earn", "www.coinbase.com", .earn),
        BrowserDApp("Binance Staked ETH (WBETH)", "https://www.binance.com/en/wbeth", "www.binance.com", .earn),
        BrowserDApp("Mantle Staked ETH (Methamorphosis)", "https://www.mantle.xyz/meth", "www.mantle.xyz", .earn),
        BrowserDApp("Swell Network", "https://app.swellnetwork.io", "app.swellnetwork.io", .earn),
        BrowserDApp("Haedal Protocol", "https://www.haedal.xyz", "www.haedal.xyz", .earn),
        BrowserDApp("Tortuga / Amnis Finance", "https://stake.amnis.finance", "stake.amnis.finance", .earn),
        BrowserDApp("pStake Finance", "https://app.pstake.finance", "app.pstake.finance", .earn),
        BrowserDApp("Hyperliquid", "https://app.hyperliquid.xyz/trade", "app.hyperliquid.xyz", .perps),
        BrowserDApp("dYdX", "https://dydx.trade", "dydx.trade", .perps),
        BrowserDApp("Vertex Protocol", "https://app.vertexprotocol.com", "app.vertexprotocol.com", .perps),
        BrowserDApp("Aevo", "https://app.aevo.xyz", "app.aevo.xyz", .perps),
        BrowserDApp("Gains Network (gTrade)", "https://gains.trade", "gains.trade", .perps),
        BrowserDApp("Hyperliquid HyperEVM (HyperSwap)", "https://app.hyperswap.exchange", "app.hyperswap.exchange", .perps),
        BrowserDApp("ApeX Protocol", "https://pro.apex.exchange", "pro.apex.exchange", .perps),
        BrowserDApp("Lighter", "https://app.lighter.xyz", "app.lighter.xyz", .perps),
        BrowserDApp("Ostium", "https://ostium.app", "ostium.app", .perps),
        BrowserDApp("Avantis", "https://avantisfi.com/trade", "avantisfi.com", .perps),
        BrowserDApp("Synthetix", "https://app.synthetix.io", "app.synthetix.io", .perps),
        BrowserDApp("Kwenta", "https://kwenta.eth.limo", "kwenta.eth.limo", .perps),
        BrowserDApp("Polynomial", "https://trade.polynomial.fi", "trade.polynomial.fi", .perps),
        BrowserDApp("Derive (Lyra)", "https://www.derive.xyz", "www.derive.xyz", .perps),
        BrowserDApp("Premia", "https://app.premia.blue", "app.premia.blue", .perps),
        BrowserDApp("Thales", "https://thalesmarket.io", "thalesmarket.io", .perps),
        BrowserDApp("Zeta Markets", "https://dex.zeta.markets", "dex.zeta.markets", .perps),
        BrowserDApp("Mango Markets", "https://app.mango.markets", "app.mango.markets", .perps),
        BrowserDApp("Helix (Injective)", "https://helixapp.com", "helixapp.com", .perps),
        BrowserDApp("Levana", "https://trade.levana.finance", "trade.levana.finance", .perps),
        BrowserDApp("Bluefin", "https://trade.bluefin.io", "trade.bluefin.io", .perps),
        BrowserDApp("MUX Protocol", "https://app.mux.network", "app.mux.network", .perps),
        BrowserDApp("Paradex", "https://app.paradex.trade", "app.paradex.trade", .perps),
        BrowserDApp("OpenSea", "https://opensea.io", "opensea.io", .nft),
        BrowserDApp("Blur", "https://blur.io", "blur.io", .nft),
        BrowserDApp("Magic Eden", "https://magiceden.io", "magiceden.io", .nft),
        BrowserDApp("Tensor", "https://www.tensor.trade", "www.tensor.trade", .nft),
        BrowserDApp("Rarible", "https://rarible.com", "rarible.com", .nft),
        BrowserDApp("LooksRare", "https://looksrare.org", "looksrare.org", .nft),
        BrowserDApp("X2Y2", "https://x2y2.io", "x2y2.io", .nft),
        BrowserDApp("Foundation", "https://foundation.app", "foundation.app", .nft),
        BrowserDApp("SuperRare", "https://superrare.com", "superrare.com", .nft),
        BrowserDApp("Zora", "https://zora.co", "zora.co", .nft),
        BrowserDApp("Element", "https://element.market", "element.market", .nft),
        BrowserDApp("OKX NFT Marketplace", "https://www.okx.com/web3/marketplace/nft", "www.okx.com", .nft),
        BrowserDApp("Mintify", "https://mintify.xyz", "mintify.xyz", .nft),
        BrowserDApp("Tradeport", "https://www.tradeport.xyz", "www.tradeport.xyz", .nft),
        BrowserDApp("BlockApe (Clutch)", "https://www.clutchplay.gg", "www.clutchplay.gg", .nft),
        BrowserDApp("Wapal", "https://wapal.io", "wapal.io", .nft),
        BrowserDApp("Mercado (Aptos)", "https://www.mercato.partners", "www.mercato.partners", .nft),
        BrowserDApp("Bullish (Mooar)", "https://mooar.com", "mooar.com", .nft),
        BrowserDApp("Nifty Gateway", "https://www.niftygateway.com", "www.niftygateway.com", .nft),
        BrowserDApp("objkt", "https://objkt.com", "objkt.com", .nft),
        BrowserDApp("Sudoswap", "https://sudoswap.xyz", "sudoswap.xyz", .nft),
        BrowserDApp("KnownOrigin", "https://knownorigin.io", "knownorigin.io", .nft),
        BrowserDApp("Fractal", "https://www.fractal.is", "www.fractal.is", .nft),
        BrowserDApp("Hyperspace", "https://hyperspace.xyz", "hyperspace.xyz", .nft),
        BrowserDApp("Ethena", "https://app.ethena.fi", "app.ethena.fi", .stablecoin),
        BrowserDApp("Ondo Finance", "https://ondo.finance", "ondo.finance", .stablecoin),
        BrowserDApp("Liquity", "https://www.liquity.org", "www.liquity.org", .stablecoin),
        BrowserDApp("Curve (crvUSD)", "https://crvusd.curve.fi", "crvusd.curve.fi", .stablecoin),
        BrowserDApp("Mountain Protocol", "https://mountainprotocol.com", "mountainprotocol.com", .stablecoin),
        BrowserDApp("Maple Finance", "https://app.maple.finance", "app.maple.finance", .stablecoin),
        BrowserDApp("Centrifuge", "https://app.centrifuge.io", "app.centrifuge.io", .stablecoin),
        BrowserDApp("Goldfinch", "https://app.goldfinch.finance", "app.goldfinch.finance", .stablecoin),
        BrowserDApp("Angle Protocol", "https://app.angle.money", "app.angle.money", .stablecoin),
        BrowserDApp("Usual", "https://app.usual.money", "app.usual.money", .stablecoin),
        BrowserDApp("Resolv", "https://app.resolv.xyz", "app.resolv.xyz", .stablecoin),
        BrowserDApp("Lybra Finance", "https://app.lybra.finance", "app.lybra.finance", .stablecoin),
        BrowserDApp("Backed Finance", "https://app.backed.fi", "app.backed.fi", .stablecoin),
        BrowserDApp("Inverse Finance (DOLA)", "https://www.inverse.finance", "www.inverse.finance", .stablecoin),
        BrowserDApp("Reserve Protocol", "https://app.reserve.org", "app.reserve.org", .stablecoin),
        BrowserDApp("Solv Protocol", "https://app.solv.finance", "app.solv.finance", .stablecoin),
        BrowserDApp("Lista DAO (lisUSD)", "https://lista.org", "lista.org", .stablecoin),
        BrowserDApp("Perena", "https://app.perena.org", "app.perena.org", .stablecoin),
        BrowserDApp("Flux Finance", "https://fluxfinance.com", "fluxfinance.com", .stablecoin),
        BrowserDApp("ENS (Ethereum Name Service)", "https://app.ens.domains", "app.ens.domains", .naming),
        BrowserDApp("Space ID", "https://space.id", "space.id", .naming),
        BrowserDApp("Unstoppable Domains", "https://unstoppabledomains.com", "unstoppabledomains.com", .naming),
        BrowserDApp("Solana Name Service (SNS)", "https://www.sns.id", "www.sns.id", .naming),
        BrowserDApp("AllDomains", "https://app.alldomains.id", "app.alldomains.id", .naming),
        BrowserDApp("SuiNS (Sui Name Service)", "https://suins.io", "suins.io", .naming),
        BrowserDApp("Aptos Names (ANS)", "https://www.aptosnames.com", "www.aptosnames.com", .naming),
        BrowserDApp("Base Names (Basenames)", "https://www.base.org/names", "www.base.org", .naming),
        BrowserDApp("Lens (Handles)", "https://hey.xyz", "hey.xyz", .naming),
        BrowserDApp("Farcaster (Warpcast)", "https://farcaster.xyz", "farcaster.xyz", .naming),
        BrowserDApp("Bonfida", "https://bonfida.org", "bonfida.org", .naming),
        BrowserDApp("TON DNS (Tonkeeper)", "https://dns.ton.org", "dns.ton.org", .naming),
        BrowserDApp("Freename", "https://freename.io", "freename.io", .naming),
        BrowserDApp("Arbitrum Name Service (ARB ID)", "https://arbid.space.id", "arbid.space.id", .naming),
        BrowserDApp("Polkadot Name System (PNS / Polkadot.id)", "https://www.dotters.network", "www.dotters.network", .naming),
        BrowserDApp("Stellar (Soroban Domains)", "https://sorobandomains.org", "sorobandomains.org", .naming),
        BrowserDApp("Tezos Domains", "https://app.tezos.domains", "app.tezos.domains", .naming),
        BrowserDApp("BNS (Bitcoin Name System)", "https://btc.us", "btc.us", .naming),
        BrowserDApp("Starknet ID", "https://app.starknet.id", "app.starknet.id", .naming),
        BrowserDApp("Avvy Domains", "https://avvy.domains", "avvy.domains", .naming),
        BrowserDApp("NNS (NEAR / .near accounts via MyNearWallet)", "https://app.mynearwallet.com", "app.mynearwallet.com", .naming),
        BrowserDApp("ZNS Connect", "https://znsconnect.io", "znsconnect.io", .naming),
        BrowserDApp("AZERO ID (Aleph Zero)", "https://azero.id", "azero.id", .naming),
        BrowserDApp("TNS (Tron Name Service)", "https://tns.network", "tns.network", .naming),
        BrowserDApp("Lens", "https://lens.xyz", "lens.xyz", .social),
        BrowserDApp("Paragraph", "https://paragraph.com", "paragraph.com", .social),
        BrowserDApp("Mirror", "https://mirror.xyz", "mirror.xyz", .social),
        BrowserDApp("Phaver", "https://phaver.com", "phaver.com", .social),
        BrowserDApp("Tako", "https://tako.so", "tako.so", .social),
        BrowserDApp("Towns", "https://app.towns.com", "app.towns.com", .social),
        BrowserDApp("Drakula", "https://drakula.app", "drakula.app", .social),
        BrowserDApp("Audius", "https://audius.co", "audius.co", .social),
        BrowserDApp("Sound.xyz", "https://sound.xyz", "sound.xyz", .social),
        BrowserDApp("Pump.fun", "https://pump.fun", "pump.fun", .social),
        BrowserDApp("Time.fun", "https://time.fun", "time.fun", .social),
        BrowserDApp("Vector", "https://vector.fun", "vector.fun", .social),
        BrowserDApp("Tribe.run", "https://tribe.run", "tribe.run", .social),
        BrowserDApp("Mint.club", "https://mint.club", "mint.club", .social),
        BrowserDApp("Galxe", "https://app.galxe.com", "app.galxe.com", .social),
        BrowserDApp("Rally (deBridge Stories)", "https://debank.com", "debank.com", .social),
        BrowserDApp("Yup", "https://yup.io", "yup.io", .social),
        BrowserDApp("Suipiens", "https://suipiens.com", "suipiens.com", .social),
        BrowserDApp("Tip.cc Solcial", "https://solcial.io", "solcial.io", .social),
        BrowserDApp("Interface", "https://interface.social", "interface.social", .social),
        BrowserDApp("Unlonely", "https://unlonely.app", "unlonely.app", .social),
        BrowserDApp("Decentraland", "https://play.decentraland.org", "play.decentraland.org", .gaming),
        BrowserDApp("The Sandbox", "https://www.sandbox.game/en/map", "www.sandbox.game", .gaming),
        BrowserDApp("Axie Infinity", "https://app.axieinfinity.com", "app.axieinfinity.com", .gaming),
        BrowserDApp("Pixels", "https://play.pixels.xyz", "play.pixels.xyz", .gaming),
        BrowserDApp("Gods Unchained", "https://play.godsunchained.com", "play.godsunchained.com", .gaming),
        BrowserDApp("Illuvium", "https://play.illuvium.io", "play.illuvium.io", .gaming),
        BrowserDApp("Gala Games", "https://app.gala.games", "app.gala.games", .gaming),
        BrowserDApp("Splinterlands", "https://splinterlands.com", "splinterlands.com", .gaming),
        BrowserDApp("Star Atlas", "https://play.staratlas.com", "play.staratlas.com", .gaming),
        BrowserDApp("Aurory", "https://app.aurory.io", "app.aurory.io", .gaming),
        BrowserDApp("Genopets", "https://app.genopets.me", "app.genopets.me", .gaming),
        BrowserDApp("Stepn", "https://www.stepn.com", "www.stepn.com", .gaming),
        BrowserDApp("DeFi Kingdoms", "https://game.defikingdoms.com", "game.defikingdoms.com", .gaming),
        BrowserDApp("Big Time", "https://www.bigtime.gg", "www.bigtime.gg", .gaming),
        BrowserDApp("Guild of Heroes", "https://playembr.io", "playembr.io", .gaming),
        BrowserDApp("Otherside", "https://otherside.xyz", "otherside.xyz", .gaming),
        BrowserDApp("Shrapnel", "https://www.shrapnel.com", "www.shrapnel.com", .gaming),
        BrowserDApp("Ronin (Mavis)", "https://app.roninchain.com", "app.roninchain.com", .gaming),
        BrowserDApp("Sorare", "https://sorare.com", "sorare.com", .gaming),
        BrowserDApp("Parallel", "https://parallel.life", "parallel.life", .gaming),
        BrowserDApp("MOBOX", "https://www.mobox.io", "www.mobox.io", .gaming),
        BrowserDApp("Heroes of Mavia", "https://www.mavia.com", "www.mavia.com", .gaming),
        BrowserDApp("Off The Grid", "https://gameofficial.gameofficial.com", "gameofficial.gameofficial.com", .gaming),
        BrowserDApp("Wilder World", "https://www.wilderworld.com", "www.wilderworld.com", .gaming),
        BrowserDApp("Alien Worlds", "https://alienworlds.io", "alienworlds.io", .gaming),
        BrowserDApp("Zapper", "https://zapper.xyz", "zapper.xyz", .tools),
        BrowserDApp("Zerion", "https://app.zerion.io", "app.zerion.io", .tools),
        BrowserDApp("DefiLlama", "https://defillama.com", "defillama.com", .tools),
        BrowserDApp("Etherscan", "https://etherscan.io", "etherscan.io", .tools),
        BrowserDApp("Arbiscan", "https://arbiscan.io", "arbiscan.io", .tools),
        BrowserDApp("Basescan", "https://basescan.org", "basescan.org", .tools),
        BrowserDApp("Polygonscan", "https://polygonscan.com", "polygonscan.com", .tools),
        BrowserDApp("BscScan", "https://bscscan.com", "bscscan.com", .tools),
        BrowserDApp("Solscan", "https://solscan.io", "solscan.io", .tools),
        BrowserDApp("Solana Explorer", "https://explorer.solana.com", "explorer.solana.com", .tools),
        BrowserDApp("SolanaFM", "https://solana.fm", "solana.fm", .tools),
        BrowserDApp("Step Finance", "https://app.step.finance", "app.step.finance", .tools),
        BrowserDApp("Sonarwatch", "https://sonar.watch", "sonar.watch", .tools),
        BrowserDApp("Suiscan", "https://suiscan.xyz", "suiscan.xyz", .tools),
        BrowserDApp("SuiVision", "https://suivision.xyz", "suivision.xyz", .tools),
        BrowserDApp("Aptos Explorer", "https://explorer.aptoslabs.com", "explorer.aptoslabs.com", .tools),
        BrowserDApp("Tonviewer", "https://tonviewer.com", "tonviewer.com", .tools),
        BrowserDApp("Tronscan", "https://tronscan.org", "tronscan.org", .tools),
        BrowserDApp("XRPSCAN", "https://xrpscan.com", "xrpscan.com", .tools),
        BrowserDApp("Stellar Expert", "https://stellar.expert/explorer/public", "stellar.expert", .tools),
        BrowserDApp("Mempool.space", "https://mempool.space", "mempool.space", .tools),
        BrowserDApp("Subscan", "https://www.subscan.io", "www.subscan.io", .tools),
        BrowserDApp("Tally", "https://www.tally.xyz", "www.tally.xyz", .tools),
        BrowserDApp("Snapshot", "https://snapshot.box", "snapshot.box", .tools),
        BrowserDApp("Dune", "https://dune.com", "dune.com", .tools),
        BrowserDApp("Arkham", "https://intel.arkm.com", "intel.arkm.com", .tools),
    ]

    /// The directory filtered to one category (`.all` returns everything).
    static func directory(for category: BrowserDAppCategory) -> [BrowserDApp] {
        category == .all ? directory : directory.filter { $0.category == category }
    }
}
