# Stabro Wallet — Supported Assets & Networks

> **Source of truth:** `/Users/thuglifex/Desktop/stabro_assets.csv`
>
> **Scope rule (HARD):** The wallet supports **ONLY** the coins, tokens, and networks listed in this document. Do **not** add, remove, or substitute any asset/network without updating the CSV first. No "extra" chains (e.g., no Cardano, Cosmos Hub, Fantom, Linea, Mantle, etc.) unless they appear in the CSV.
>
> Each (Symbol, Network) pair is a distinct asset row. The same symbol on a different network is a different asset (e.g., `USDT@ethereum` ≠ `USDT@tron`).

---

## 1. Networks (24 total)

### 1.1 Bitcoin family (UTXO, non-EVM)
| Network ID    | Display Name  | Native Coin | Decimals |
|---------------|---------------|-------------|----------|
| `bitcoin`     | Bitcoin       | BTC         | 8        |
| `bitcoinCash` | Bitcoin Cash  | BCH         | 8        |
| `dogecoin`    | Dogecoin      | DOGE        | 8        |
| `litecoin`    | Litecoin      | LTC         | 8        |

### 1.2 EVM chains (12)
| Network ID   | Display Name | Native Coin | Chain ID | L2  |
|--------------|--------------|-------------|----------|-----|
| `ethereum`   | Ethereum     | ETH         | 1        | No  |
| `arbitrum`   | Arbitrum     | ETH         | 42161    | Yes |
| `base`       | Base         | ETH         | 8453     | Yes |
| `optimism`   | Optimism     | ETH         | 10       | Yes |
| `scroll`     | Scroll       | ETH         | 534352   | Yes |
| `zkSync`     | zkSync Era   | ETH         | 324      | Yes |
| `polygon`    | Polygon      | POL         | 137      | No  |
| `bnbChain`   | BNB Chain    | BNB         | 56       | No  |
| `opBNB`      | opBNB        | BNB         | 204      | Yes |
| `avalanche`  | Avalanche    | AVAX        | 43114    | No  |
| `celo`       | Celo         | CELO        | 42220    | No  |
| `kavaEvm`    | Kava EVM     | KAVA        | 2222     | No  |

Token standard on every EVM chain: **ERC-20**.

### 1.3 Non-EVM L1s (8)
| Network ID  | Display Name | Family    | Native Coin | Decimals | Token Standard      |
|-------------|--------------|-----------|-------------|----------|---------------------|
| `aptos`     | Aptos        | aptos     | APT         | 8        | Aptos Coin          |
| `near`      | NEAR         | near      | NEAR        | 24       | NEP-141             |
| `polkadot`  | Polkadot     | polkadot  | DOT         | 10       | Asset Hub Asset     |
| `ripple`    | XRP Ledger   | ripple    | XRP         | 6        | XRPL IOU            |
| `solana`    | Solana       | solana    | SOL         | 9        | SPL Token / Token-2022 |
| `stellar`   | Stellar      | stellar   | XLM         | 7        | (native only)       |
| `sui`       | Sui          | sui       | SUI         | 9        | (native only)       |
| `ton`       | TON          | ton       | TON         | 9        | TIP-3 Jetton        |
| `tron`      | TRON         | tron      | TRX         | 6        | TRC-20              |
| `kava`      | Kava         | cosmos    | KAVA        | 6        | Cosmos SDK / IBC    |

---

## 2. Native Coins (27 rows)

| Symbol | Display Name   | Network(s)                                                                |
|--------|----------------|---------------------------------------------------------------------------|
| BTC    | Bitcoin        | bitcoin                                                                   |
| BCH    | Bitcoin Cash   | bitcoinCash                                                               |
| DOGE   | Dogecoin       | dogecoin                                                                  |
| LTC    | Litecoin       | litecoin                                                                  |
| ETH    | Ether          | ethereum, arbitrum, base, optimism, scroll, zkSync                        |
| POL    | Polygon        | polygon                                                                   |
| BNB    | BNB            | bnbChain, opBNB                                                           |
| AVAX   | Avalanche      | avalanche                                                                 |
| CELO   | Celo           | celo                                                                      |
| KAVA   | Kava           | kava (Cosmos), kavaEvm                                                    |
| APT    | Aptos          | aptos                                                                     |
| NEAR   | NEAR           | near                                                                      |
| DOT    | Polkadot       | polkadot                                                                  |
| XRP    | XRP            | ripple                                                                    |
| SOL    | Solana         | solana                                                                    |
| XLM    | Stellar Lumens | stellar                                                                   |
| SUI    | Sui            | sui                                                                       |
| TON    | Toncoin        | ton                                                                       |
| TRX    | TRON           | tron                                                                      |

> ETH appears on 6 networks but is **one logical asset with 6 balances**. UI should group by symbol while preserving per-network balances.

---

## 3. Tokens by Network

Contract addresses are authoritative. Always use the exact address from the CSV for transfers/swaps.

### 3.1 Ethereum (chain 1)
| Symbol | Name                          | Decimals | Contract |
|--------|-------------------------------|----------|----------|
| USDC   | USD Coin                      | 6        | 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 |
| USDT   | Tether USD                    | 6        | 0xdAC17F958D2ee523a2206206994597C13D831ec7 |
| DAI    | Dai                           | 18       | 0x6B175474E89094C44Da98b954EedeAC495271d0F |
| USDS   | USDS                          | 18       | 0xdC035D45d973E3EC169d2276DDab16f1e407384F |
| USDe   | Ethena USDe                   | 18       | 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 |
| USD0   | Usual USD                     | 18       | 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5 |
| USD1   | World Liberty Financial USD   | 18       | 0x8d0D000Ee44948fC98c9B98A4FA4921476f08B0d |
| USDf   | Falcon USD                    | 18       | 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2 |
| USDG   | Global Dollar                 | 6        | 0xe343167631d89b6ffc58b88d6b7fb0228795491d |
| USDP   | Pax Dollar                    | 18       | 0x8E870D67F660D95d5be530380D0eC0bd388289E1 |
| AUSD   | Agora Dollar                  | 6        | 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a |
| EURC   | EURC                          | 6        | 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c |
| FDUSD  | First Digital USD             | 18       | 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409 |
| FRAX   | Legacy Frax Dollar            | 18       | 0x853d955aCEf822Db058eb8505911ED77F175b99e |
| GUSD   | Gemini Dollar                 | 2        | 0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd |
| PYUSD  | PayPal USD                    | 6        | 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8 |
| RLUSD  | Ripple USD                    | 18       | 0x8292bb45bf1ee4d140127049757c2e0ff06317ed |
| TUSD   | TrueUSD                       | 18       | 0x0000000000085d4780B73119b644AE5ecd22b376 |
| WBTC   | Wrapped Bitcoin               | 8        | 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 |
| WETH   | Wrapped Ether                 | 18       | 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 |
| stETH  | Lido Staked ETH               | 18       | 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 |

### 3.2 Arbitrum (chain 42161, L2)
| Symbol | Name              | Decimals | Contract |
|--------|-------------------|----------|----------|
| USDC   | USD Coin          | 6        | 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 |
| USDT   | Tether USD        | 6        | 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 |
| DAI    | Dai               | 18       | 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1 |
| USD0   | Usual USD         | 18       | 0x35f1C5cB7FB977E669FD244C567Da99d8a3a6850 |
| USDai  | USDai             | 18       | 0x0a1a1a107e45b7ced86833863f482bc5f4ed82ef |
| USDe   | Ethena USDe       | 18       | 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34 |
| WBTC   | Wrapped Bitcoin   | 8        | 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f |
| WETH   | Wrapped Ether     | 18       | 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 |

### 3.3 Base (chain 8453, L2)
| Symbol | Name              | Decimals | Contract |
|--------|-------------------|----------|----------|
| USDC   | USD Coin          | 6        | 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 |
| USDT   | Tether USD        | 6        | 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2 |
| DAI    | Dai               | 18       | 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb |
| USDS   | USDS              | 18       | 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc |
| USDe   | Ethena USDe       | 18       | 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34 |
| AUSD   | Agora Dollar      | 6        | 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a |
| EURC   | EURC              | 6        | 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42 |
| WETH   | Wrapped Ether     | 18       | 0x4200000000000000000000000000000000000006 |

### 3.4 Optimism (chain 10, L2)
| Symbol | Name              | Decimals | Contract |
|--------|-------------------|----------|----------|
| USDC   | USD Coin          | 6        | 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85 |
| USDT   | Tether USD        | 6        | 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58 |
| DAI    | Dai               | 18       | 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1 |
| FRAX   | Legacy Frax Dollar| 18       | 0x2E3D870790dC77A83DD1d18184Acc7439A53f475 |
| WBTC   | Wrapped Bitcoin   | 8        | 0x68f180fcCe6836688e9084f035309E29Bf0A2095 |
| WETH   | Wrapped Ether     | 18       | 0x4200000000000000000000000000000000000006 |

### 3.5 Scroll (chain 534352, L2)
| Symbol | Name        | Decimals | Contract |
|--------|-------------|----------|----------|
| USDC   | USD Coin    | 6        | 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4 |
| USDT   | Tether USD  | 6        | 0xf55BEC9cafDbE8730f096Aa55DAd6D22d44099dF |

### 3.6 zkSync Era (chain 324, L2)
| Symbol | Name        | Decimals | Contract |
|--------|-------------|----------|----------|
| USDC   | USD Coin    | 6        | 0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4 |
| USDT   | Tether USD  | 6        | 0x493257fD37EDB34451f62EDf8D2a0C418852bA4C |

### 3.7 Polygon (chain 137)
| Symbol | Name               | Decimals | Contract |
|--------|--------------------|----------|----------|
| USDC   | USD Coin           | 6        | 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 |
| USDT   | Tether USD         | 6        | 0xc2132D05D31c914a87C6611C10748AEb04B58e8F |
| DAI    | Dai                | 18       | 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063 |
| AUSD   | Agora Dollar       | 6        | 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a |
| FRAX   | Legacy Frax Dollar | 18       | 0x45c32fA6DF82ead1e2EF74d17b76547EDdFaFF89 |
| WETH   | Wrapped Ether      | 18       | 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619 |

### 3.8 BNB Chain (chain 56)
| Symbol | Name                          | Decimals | Contract |
|--------|-------------------------------|----------|----------|
| USDC   | USD Coin                      | 18       | 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d |
| USDT   | Tether USD                    | 18       | 0x55d398326f99059fF775485246999027B3197955 |
| DAI    | Dai                           | 18       | 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3 |
| USD1   | World Liberty Financial USD   | 18       | 0x8d0D000Ee44948fC98c9B98A4FA4921476f08B0d |
| USDe   | Ethena USDe                   | 18       | 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34 |
| USDf   | Falcon USD                    | 18       | 0xb3b02e4a9fb2bd28cc2ff97b0ab3f6b3ec1ee9d2 |
| USDP   | Pax Dollar                    | 18       | 0xb3c11196A4f3b1da7c23d9FB0A3dDE9c6340934F |
| DUSD   | StandX DUSD                   | 6        | 0xaF44a1E76f56eE12ADBB7Ba8AcD3CBD474888122 |
| FDUSD  | First Digital USD             | 18       | 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409 |
| FRAX   | Legacy Frax Dollar            | 18       | 0x90C97F71E18723b0cf0dfa30ee176Ab653E89F40 |
| TUSD   | TrueUSD                       | 18       | 0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9 |
| lisUSD | Lista USD                     | 18       | 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5 |
| WETH   | Wrapped Ether                 | 18       | 0x2170Ed0880ac9A755fd29B2688956BD959F933F8 |

### 3.9 opBNB (chain 204, L2)
| Symbol | Name        | Decimals | Contract |
|--------|-------------|----------|----------|
| USDT   | Tether USD  | 18       | 0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3 |

### 3.10 Avalanche (chain 43114)
| Symbol | Name               | Decimals | Contract |
|--------|--------------------|----------|----------|
| USDC   | USD Coin           | 6        | 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E |
| USDT   | Tether USD         | 6        | 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7 |
| DAI    | Dai                | 18       | 0xd586E7F844cEa2F87f50152665BCbc2C279D8d70 |
| AUSD   | Agora Dollar       | 6        | 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a |
| EURC   | EURC               | 6        | 0xC891EB4CbDEFf6e073e859e987815Ed1505c2ACD |
| FRAX   | Legacy Frax Dollar | 18       | 0xD24C2Ad096400B6FBcd2ad8B24E7acBc21A1da64 |
| TUSD   | TrueUSD            | 18       | 0x1C20E891Bab6b1727d14Da358FAe2984Ed9B59EB |
| WBTC   | Wrapped Bitcoin    | 8        | 0x50b7545627a5162F82A992c33b87aDc75187B218 |
| WETH   | Wrapped Ether      | 18       | 0x49D5c2BDFfac6CE2BFdB6640F4F80f226bc10bAB |

### 3.11 Celo (chain 42220)
| Symbol | Name        | Decimals | Contract |
|--------|-------------|----------|----------|
| USDC   | USD Coin    | 6        | 0xcebA9300f2b948710d2653dD7B07f33A8B32118C |
| USDT   | Tether USD  | 6        | 0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e |

### 3.12 Kava EVM (chain 2222)
| Symbol | Name        | Decimals | Contract |
|--------|-------------|----------|----------|
| USDT   | Tether USD  | 6        | 0x919C1c267BC06a7039e03fcc2eF738525769109c |

### 3.13 Kava (Cosmos)
| Symbol | Name        | Decimals | Identifier              | Notes              |
|--------|-------------|----------|-------------------------|--------------------|
| USDT   | Tether USD  | 6        | `erc20/tether/usdt`     | Cosmos IBC denom   |

### 3.14 Aptos
| Symbol | Name        | Decimals | Contract |
|--------|-------------|----------|----------|
| USDC   | USD Coin    | 6        | 0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b |
| USDT   | Tether USD  | 6        | 0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b |

### 3.15 Solana (SPL Token / Token-2022)
| Symbol | Name                          | Decimals | Standard       | Mint |
|--------|-------------------------------|----------|----------------|------|
| USDC   | USD Coin                      | 6        | SPL Token      | EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v |
| USDT   | Tether USD                    | 6        | SPL Token      | Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB |
| USD1   | World Liberty Financial USD   | 6        | SPL Token      | USD1ttGY1N17NEEHLmELoaybftRBUSErhqYiQzvEmuB |
| AUSD   | Agora Dollar                  | 6        | SPL Token-2022 | AUSD1jCcCyPLybk1YnvPWsHQSrZ46dxwoMniN4N2UEB9 |
| DUSD   | StandX DUSD                   | 6        | SPL Token-2022 | DUSDt4AeLZHWYmcXnVGYdgAzjtzU5mXUVnTMdnSzAttM |
| PYUSD  | PayPal USD                    | 6        | SPL Token-2022 | 2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo |
| USDG   | Global Dollar                 | 6        | SPL Token-2022 | 2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH |
| EURC   | EURC                          | 6        | SPL Token      | HzwqbKZw8HxMN6bF2yFZNrht3c2iXXzpKcFu7uBEDKtr |
| WBTC   | Wrapped Bitcoin               | 8        | SPL Token      | 3NZ9JMVBmGAqocybic2c7LQCJScmgsAZ6vQqTDzcqmJh |
| WETH   | Wrapped Ether                 | 8        | SPL Token      | 7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs |

### 3.16 TRON (TRC-20)
| Symbol | Name                          | Decimals | Contract |
|--------|-------------------------------|----------|----------|
| USDT   | Tether USD                    | 6        | TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t |
| USD1   | World Liberty Financial USD   | 18       | TPFqcBAaaUMCSVRCqPaQ9QnzKhmuoLR6Rc |
| USDD   | Decentralized USD             | 18       | TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz |
| TUSD   | TrueUSD                       | 18       | TUpMhErZL2fhh4sVNULAbNKLokS4GjC1F4 |
| WBTC   | Wrapped Bitcoin               | 8        | TXpw8XeWYeTUd4quDskoUqeQPowRh4jY65 |

### 3.17 NEAR (NEP-141)
| Symbol | Name        | Decimals | Token Account |
|--------|-------------|----------|---------------|
| USDC   | USD Coin    | 6        | 17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1 |
| USDT   | Tether USD  | 6        | usdt.tether-token.near |

### 3.18 Polkadot (Asset Hub)
| Symbol | Name        | Decimals | Asset ID | Notes              |
|--------|-------------|----------|----------|--------------------|
| USDC   | USD Coin    | 6        | 1337     | Asset Hub asset id |

### 3.19 XRP Ledger (XRPL IOU)
| Symbol | Name         | Decimals | currency.issuer |
|--------|--------------|----------|-----------------|
| RLUSD  | Ripple USD   | 6        | 524C555344000000000000000000000000000000.rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De |

### 3.20 TON (TIP-3 Jetton)
| Symbol | Name        | Decimals | Master Contract |
|--------|-------------|----------|-----------------|
| USDT   | Tether USD  | 6        | EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs |

### 3.21 Stellar / Sui / Bitcoin family
Native coin only. **No tokens** supported on `stellar`, `sui`, `bitcoin`, `bitcoinCash`, `dogecoin`, `litecoin`.

---

## 4. Engineering rules for agents

1. **Single source of truth** — `stabro_assets.csv` wins over any in-code list. If a discrepancy appears, treat the CSV row as correct and update code/docs to match.
2. **Asset identity = `(Symbol, Network)`** — never collapse cross-chain duplicates into one row at the data layer; only group in the UI.
3. **Decimals matter** — USDC on BNB Chain is **18 decimals**, not 6. Same symbol can have different decimals on different chains. Always read decimals from the CSV / on-chain `decimals()`.
4. **Contract addresses are case-sensitive on non-EVM chains** (Solana mints, Aptos resources, TRON addresses, TON contracts). Use exact strings; do not normalize case.
5. **EVM addresses** — accept any casing for input but render in EIP-55 checksummed form.
6. **L2 vs L1 ETH** — six different "ETH" balances exist (Ethereum, Arbitrum, Base, Optimism, Scroll, zkSync). Sends/receives must respect the chain; no automatic bridging.
7. **Stablecoin flag** — many tokens are flagged `IsStablecoin=Yes`; surface this in UI sorting/filters but do **not** treat it as a guarantee of peg.
8. **Token standards per chain** (use only these):
   - EVM → ERC-20
   - Solana → SPL Token or SPL Token-2022 (per row)
   - TRON → TRC-20
   - NEAR → NEP-141
   - Aptos → Aptos Coin (Move resource)
   - TON → TIP-3 Jetton
   - Polkadot → Asset Hub Asset (by id)
   - XRPL → IOU (currency.issuer pair)
   - Kava (Cosmos) → Cosmos SDK / IBC denom
9. **No autoswap of similar names** — `USDS` (Sky/MakerDAO) ≠ `USDC` ≠ `USDe` ≠ `USDai` ≠ `USDf` ≠ `USD0` ≠ `USD1` ≠ `USDP` ≠ `USDG` ≠ `USDD`. Treat each as distinct.
10. **Adding/removing assets** — must be CSV-first: edit `stabro_assets.csv`, regenerate this doc, then update code. No silent additions.

---

## 5. Summary counts

- **Networks:** 24 (4 Bitcoin-family, 12 EVM, 8 non-EVM L1 / Cosmos)
- **Native coin rows:** 27 (19 unique symbols; ETH/BNB/KAVA appear on multiple networks)
- **Token rows:** 101 distinct `(symbol, network)` pairs
- **Total asset rows in CSV:** 128
