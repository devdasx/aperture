import Foundation

/// Curated registry of ERC-20 tokens per EVM chain — the complete
/// `(symbol, network)` token table from `SUPPORTED_ASSETS.md`
/// (the single source of truth — see Rule #21 + M-012). Every entry
/// is verbatim from the doc; no agent additions, no agent removals.
///
/// **Token-balance reads use `eth_call` against the contract's
/// `balanceOf(address)` selector (`0x70a08231`).** Same code path
/// for every EVM chain — no per-chain RPC fork.
///
/// **Adding a new token:** edit `SUPPORTED_ASSETS.md` first (it is
/// the source of truth), then mirror the new row here. Do NOT add
/// a token here without it being in the spec — Rule #21's spec
/// discipline.
enum EVMTokenRegistry {

    struct Entry: Sendable, Hashable {
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    static func tokens(for chain: SupportedChain) -> [Entry] {
        switch chain {

        case .ethereum: return [
            Entry(contract: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", symbol: "USDC",  name: "USD Coin",                    decimals: 6),
            Entry(contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7", symbol: "USDT",  name: "Tether USD",                  decimals: 6),
            Entry(contract: "0x6B175474E89094C44Da98b954EedeAC495271d0F", symbol: "DAI",   name: "Dai",                         decimals: 18),
            Entry(contract: "0xdC035D45d973E3EC169d2276DDab16f1e407384F", symbol: "USDS",  name: "USDS",                        decimals: 18),
            Entry(contract: "0x4c9EDD5852cd905f086C759E8383e09bff1E68B3", symbol: "USDe",  name: "Ethena USDe",                 decimals: 18),
            Entry(contract: "0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5", symbol: "USD0",  name: "Usual USD",                   decimals: 18),
            Entry(contract: "0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d", symbol: "USD1",  name: "World Liberty Financial USD", decimals: 18),
            Entry(contract: "0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2", symbol: "USDf",  name: "Falcon USD",                  decimals: 18),
            Entry(contract: "0xe343167631d89B6Ffc58B88d6b7fB0228795491D", symbol: "USDG",  name: "Global Dollar",               decimals: 6),
            Entry(contract: "0x8E870D67F660D95d5be530380D0eC0bd388289E1", symbol: "USDP",  name: "Pax Dollar",                  decimals: 18),
            Entry(contract: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", symbol: "AUSD",  name: "Agora Dollar",                decimals: 6),
            Entry(contract: "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c", symbol: "EURC",  name: "EURC",                        decimals: 6),
            Entry(contract: "0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409", symbol: "FDUSD", name: "First Digital USD",           decimals: 18),
            Entry(contract: "0x853d955aCEf822Db058eb8505911ED77F175b99e", symbol: "FRAX",  name: "Legacy Frax Dollar",          decimals: 18),
            Entry(contract: "0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd", symbol: "GUSD",  name: "Gemini Dollar",               decimals: 2),
            Entry(contract: "0x6c3ea9036406852006290770BEdFcAbA0e23A0e8", symbol: "PYUSD", name: "PayPal USD",                  decimals: 6),
            Entry(contract: "0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD", symbol: "RLUSD", name: "Ripple USD",                  decimals: 18),
            Entry(contract: "0x0000000000085d4780B73119b644AE5ecd22b376", symbol: "TUSD",  name: "TrueUSD",                     decimals: 18),
            Entry(contract: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", symbol: "WBTC",  name: "Wrapped Bitcoin",             decimals: 8),
            Entry(contract: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", symbol: "WETH",  name: "Wrapped Ether",               decimals: 18),
            Entry(contract: "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84", symbol: "stETH", name: "Lido Staked ETH",             decimals: 18),
        ]

        case .arbitrum: return [
            Entry(contract: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", symbol: "USDC",  name: "USD Coin",       decimals: 6),
            Entry(contract: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", symbol: "USDT",  name: "Tether USD",     decimals: 6),
            Entry(contract: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", symbol: "DAI",   name: "Dai",            decimals: 18),
            Entry(contract: "0x35f1C5cB7Fb977E669fD244C567Da99d8a3a6850", symbol: "USD0",  name: "Usual USD",      decimals: 18),
            Entry(contract: "0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF", symbol: "USDai", name: "USDai",          decimals: 18),
            Entry(contract: "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", symbol: "USDe",  name: "Ethena USDe",    decimals: 18),
            Entry(contract: "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", symbol: "WBTC",  name: "Wrapped Bitcoin", decimals: 8),
            Entry(contract: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", symbol: "WETH",  name: "Wrapped Ether",   decimals: 18),
        ]

        case .base: return [
            Entry(contract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", symbol: "USDC", name: "USD Coin",     decimals: 6),
            Entry(contract: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2", symbol: "USDT", name: "Tether USD",   decimals: 6),
            Entry(contract: "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb", symbol: "DAI",  name: "Dai",          decimals: 18),
            Entry(contract: "0x820C137fa70C8691f0e44Dc420a5e53c168921Dc", symbol: "USDS", name: "USDS",         decimals: 18),
            Entry(contract: "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", symbol: "USDe", name: "Ethena USDe",  decimals: 18),
            Entry(contract: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", symbol: "AUSD", name: "Agora Dollar", decimals: 6),
            Entry(contract: "0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42", symbol: "EURC", name: "EURC",         decimals: 6),
            Entry(contract: "0x4200000000000000000000000000000000000006", symbol: "WETH", name: "Wrapped Ether", decimals: 18),
        ]

        case .optimism: return [
            Entry(contract: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", symbol: "USDC", name: "USD Coin",          decimals: 6),
            Entry(contract: "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58", symbol: "USDT", name: "Tether USD",        decimals: 6),
            Entry(contract: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", symbol: "DAI",  name: "Dai",               decimals: 18),
            Entry(contract: "0x2E3D870790dC77A83DD1d18184Acc7439A53f475", symbol: "FRAX", name: "Legacy Frax Dollar", decimals: 18),
            Entry(contract: "0x68f180fcCe6836688e9084f035309E29Bf0A2095", symbol: "WBTC", name: "Wrapped Bitcoin",   decimals: 8),
            Entry(contract: "0x4200000000000000000000000000000000000006", symbol: "WETH", name: "Wrapped Ether",     decimals: 18),
        ]

        case .scroll: return [
            Entry(contract: "0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4", symbol: "USDC", name: "USD Coin",   decimals: 6),
            Entry(contract: "0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df", symbol: "USDT", name: "Tether USD", decimals: 6),
        ]

        case .zkSync: return [
            Entry(contract: "0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4", symbol: "USDC", name: "USD Coin",   decimals: 6),
            Entry(contract: "0x493257fD37EDB34451f62EDf8D2a0C418852bA4C", symbol: "USDT", name: "Tether USD", decimals: 6),
        ]

        case .polygon: return [
            Entry(contract: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", symbol: "USDC", name: "USD Coin",          decimals: 6),
            Entry(contract: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", symbol: "USDT", name: "Tether USD",        decimals: 6),
            Entry(contract: "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063", symbol: "DAI",  name: "Dai",               decimals: 18),
            Entry(contract: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", symbol: "AUSD", name: "Agora Dollar",      decimals: 6),
            Entry(contract: "0x45c32fA6DF82ead1e2EF74d17b76547EDdFaFF89", symbol: "FRAX", name: "Legacy Frax Dollar", decimals: 18),
            Entry(contract: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619", symbol: "WETH", name: "Wrapped Ether",     decimals: 18),
        ]

        case .bnbChain: return [
            Entry(contract: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", symbol: "USDC",   name: "USD Coin",                    decimals: 18),
            Entry(contract: "0x55d398326f99059fF775485246999027B3197955", symbol: "USDT",   name: "Tether USD",                  decimals: 18),
            Entry(contract: "0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3", symbol: "DAI",    name: "Dai",                         decimals: 18),
            Entry(contract: "0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d", symbol: "USD1",   name: "World Liberty Financial USD", decimals: 18),
            Entry(contract: "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", symbol: "USDe",   name: "Ethena USDe",                 decimals: 18),
            Entry(contract: "0xb3b02E4A9Fb2bD28CC2ff97B0aB3F6B3Ec1eE9D2", symbol: "USDf",   name: "Falcon USD",                  decimals: 18),
            Entry(contract: "0xb3c11196A4f3b1da7c23d9FB0A3dDE9c6340934F", symbol: "USDP",   name: "Pax Dollar",                  decimals: 18),
            Entry(contract: "0xaf44A1E76F56eE12ADBB7ba8acD3CbD474888122", symbol: "DUSD",   name: "StandX DUSD",                 decimals: 6),
            Entry(contract: "0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409", symbol: "FDUSD",  name: "First Digital USD",           decimals: 18),
            Entry(contract: "0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40", symbol: "FRAX",   name: "Legacy Frax Dollar",          decimals: 18),
            Entry(contract: "0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9", symbol: "TUSD",   name: "TrueUSD",                     decimals: 18),
            Entry(contract: "0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5", symbol: "lisUSD", name: "Lista USD",                   decimals: 18),
            Entry(contract: "0x2170Ed0880ac9A755fd29B2688956BD959F933F8", symbol: "WETH",   name: "Wrapped Ether",               decimals: 18),
        ]

        case .opBNB: return [
            Entry(contract: "0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3", symbol: "USDT", name: "Tether USD", decimals: 18),
        ]

        case .avalanche: return [
            Entry(contract: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", symbol: "USDC", name: "USD Coin",          decimals: 6),
            Entry(contract: "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7", symbol: "USDT", name: "Tether USD",        decimals: 6),
            Entry(contract: "0xd586E7F844cEa2F87f50152665BCbc2C279D8d70", symbol: "DAI",  name: "Dai",               decimals: 18),
            Entry(contract: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", symbol: "AUSD", name: "Agora Dollar",      decimals: 6),
            Entry(contract: "0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD", symbol: "EURC", name: "EURC",              decimals: 6),
            Entry(contract: "0xD24C2Ad096400B6FBcd2ad8B24E7acBc21A1da64", symbol: "FRAX", name: "Legacy Frax Dollar", decimals: 18),
            Entry(contract: "0x1C20E891Bab6b1727d14Da358FAe2984Ed9B59EB", symbol: "TUSD", name: "TrueUSD",           decimals: 18),
            Entry(contract: "0x50b7545627a5162F82A992c33b87aDc75187B218", symbol: "WBTC", name: "Wrapped Bitcoin",   decimals: 8),
            Entry(contract: "0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB", symbol: "WETH", name: "Wrapped Ether",     decimals: 18),
        ]

        case .celo: return [
            Entry(contract: "0xcebA9300f2b948710d2653dD7B07f33A8B32118C", symbol: "USDC", name: "USD Coin",   decimals: 6),
            Entry(contract: "0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e", symbol: "USDT", name: "Tether USD", decimals: 6),
        ]

        case .kavaEvm: return [
            Entry(contract: "0x919C1c267BC06a7039e03fcc2eF738525769109c", symbol: "USDT", name: "Tether USD", decimals: 6),
        ]

        default:
            return []
        }
    }

    /// `eth_call`-style calldata for `balanceOf(address)`.
    /// Selector `0x70a08231` + 32-byte left-padded holder address.
    static func balanceOfCallData(holder: String) -> String {
        let trimmed = holder.hasPrefix("0x") ? String(holder.dropFirst(2)) : holder
        let padded = String(repeating: "0", count: 24) + trimmed.lowercased()
        return "0x70a08231" + padded
    }
}
