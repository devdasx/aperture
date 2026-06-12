import Foundation

/// **Design-time placeholder data for the Send flow.**
///
/// Everything in here is MOCK — sample balances, a fixed fiat rate, a
/// single recognised ENS name, sample fee numbers, and a sample recents
/// list. It exists so the design can be reviewed on-device with realistic
/// figures before the functional layer is wired. Each consumer carries a
/// `// TODO:` pointing at the real-data task:
///
/// - balances + rates → `T-061` (balance + price reads)
/// - name resolution → `T-062`
/// - fee numbers → `T-063`
/// - recents / address book → `T-062`
/// - transaction hash → `T-066`
///
/// When the real layer lands, this whole file is deleted and the
/// `SendDraft` accessors point at the live services.
enum SendMockData {

    // MARK: - Recipient resolution (T-062)

    /// The one sample name the mock resolver recognises, so the design
    /// can show the positive "Resolves to 0x…6045 · Ethereum" row exactly
    /// as the handoff specifies. Real ENS/SNS/name resolution replaces
    /// this entirely.
    static let resolvableNames: Set<String> = ["vitalik.eth"]

    static func isResolvableName(_ input: String) -> Bool {
        resolvableNames.contains(input.lowercased())
    }

    /// MOCK resolved address for the sample name.
    static let sampleResolvedAddress = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

    // MARK: - Recents (T-062)

    /// A sample recents list for the recipient step. Real recents come
    /// from the wallet's transaction history + address book.
    struct Recent: Hashable, Identifiable, Sendable {
        let id = UUID()
        let name: String
        let address: String
        let network: SupportedChain
        var monogram: String {
            String(name.prefix(2)).uppercased()
        }
    }

    static let recents: [Recent] = [
        .init(name: "Lena · Savings", address: "0x42a1F3c9B7e8D5a2C4f6E8b1D3A5c7E9F1b2d39F", network: .ethereum),
        .init(name: "Marko", address: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh", network: .bitcoin),
        .init(name: "Coinbase", address: "0x71C7656EC7ab88b098defB751B7401B5f6d8976F", network: .base)
    ]

    // MARK: - Balances + rates (T-061)

    /// MOCK available balance per asset, in chain units. A small lookup
    /// keyed by ticker so the design shows believable figures for the
    /// common assets and a sane default for the rest.
    static func sampleBalance(for asset: SendAsset?) -> Decimal {
        guard let asset else { return 0 }
        switch asset.unitTicker.uppercased() {
        case "ETH":  return Decimal(string: "2.41") ?? 0
        case "BTC":  return Decimal(string: "0.0487") ?? 0
        case "SOL":  return Decimal(string: "61.2") ?? 0
        case "USDC", "USDT", "DAI": return Decimal(string: "1840.50") ?? 0
        case "POL":  return Decimal(string: "920.0") ?? 0
        case "BNB":  return Decimal(string: "3.8") ?? 0
        case "AVAX": return Decimal(string: "54.0") ?? 0
        case "TRX":  return Decimal(string: "12500.0") ?? 0
        default:     return Decimal(string: "100.0") ?? 0
        }
    }

    /// MOCK unit → fiat rate (in the user's active currency's nominal
    /// terms — the design treats the rate as already in the active
    /// currency). Real pricing comes from `CoinbasePriceService`.
    static func sampleFiatRate(for asset: SendAsset?) -> Decimal {
        guard let asset else { return 0 }
        switch asset.unitTicker.uppercased() {
        case "ETH":  return Decimal(string: "6940.0") ?? 0
        case "BTC":  return Decimal(string: "98000.0") ?? 0
        case "SOL":  return Decimal(string: "240.0") ?? 0
        case "USDC", "USDT", "DAI": return Decimal(string: "1.0") ?? 0
        case "POL":  return Decimal(string: "0.72") ?? 0
        case "BNB":  return Decimal(string: "1080.0") ?? 0
        case "AVAX": return Decimal(string: "62.0") ?? 0
        case "TRX":  return Decimal(string: "0.27") ?? 0
        default:     return Decimal(string: "1.0") ?? 0
        }
    }

    // MARK: - Fees (T-063)

    /// MOCK network fee in fiat for the Review row + total, varying a
    /// little by preset so the Advanced sheet has a visible effect.
    static func sampleFeeFiat(for network: SupportedChain?, selection: SendFeeSelection) -> Decimal {
        let base: Decimal
        switch network?.family {
        case .bitcoin: base = Decimal(string: "1.48") ?? 0
        case .evm:     base = Decimal(string: "1.20") ?? 0
        case .ed25519: base = Decimal(string: "0.01") ?? 0
        default:       base = Decimal(string: "0.05") ?? 0
        }
        switch selection {
        case .economy:     return base * (Decimal(string: "0.55") ?? 1)
        case .recommended: return base
        case .custom:      return base * (Decimal(string: "1.2") ?? 1)
        }
    }

    /// MOCK network fee in native units for the simple-fee-display
    /// chains (XRPL / TON / Tron / Near / Aptos / Polkadot / Kava /
    /// Stellar) that don't get an Advanced sheet.
    static func sampleFeeNative(for network: SupportedChain?, selection: SendFeeSelection) -> Decimal {
        switch network {
        case .ripple:  return Decimal(string: "0.00001") ?? 0
        case .ton:     return Decimal(string: "0.0055") ?? 0
        case .tron:    return Decimal(string: "1.1") ?? 0
        case .near:    return Decimal(string: "0.0004") ?? 0
        case .aptos:   return Decimal(string: "0.0001") ?? 0
        case .polkadot:return Decimal(string: "0.0156") ?? 0
        case .kava:    return Decimal(string: "0.002") ?? 0
        case .stellar: return Decimal(string: "0.00001") ?? 0
        default:       return Decimal(string: "0.001") ?? 0
        }
    }

    // MARK: - Bitcoin coin control (T-063 / T-065)

    /// A sample UTXO set for the Bitcoin coin-control sheet.
    struct UTXO: Hashable, Identifiable, Sendable {
        let id: String           // "txid:vout" short form
        let amount: Decimal      // BTC
    }

    static let sampleUTXOs: [UTXO] = [
        .init(id: "e3b0…c442 : 0", amount: Decimal(string: "0.250") ?? 0),
        .init(id: "9f86…d081 : 1", amount: Decimal(string: "0.180") ?? 0),
        .init(id: "2c62…4e0f : 0", amount: Decimal(string: "0.045") ?? 0),
        .init(id: "a1b2…77aa : 3", amount: Decimal(string: "0.012") ?? 0)
    ]

    /// Default-selected UTXO ids (the first two — covers a typical send).
    static let defaultSelectedUTXOIds: Set<String> = [
        "e3b0…c442 : 0", "9f86…d081 : 1"
    ]

    // MARK: - Transaction hash (T-066)

    static let sampleTransactionHash =
        "0x88df016429689c079f3b2f6ad39fa052532c56795b733da78a91ebe6a713944b"
}
