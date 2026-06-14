import Foundation

// MARK: - Send v2 design-time placeholder data
//
// **Everything here is MOCK** — realistic placeholder data behind the
// `SendV2Model` seams so the v2 screens are fully navigable for design
// review. Each block names the real-data task it stands in for. When the
// domain layer lands, the seams in `SendV2Model` point at the live
// services and this file is deleted (alongside `SendMockData`).
//
// - contacts / recents → T-062 (address book + tx history)
// - fee tiers → T-063 (per-chain fee endpoints)
// - cross-network suggestions → T-062 (recipient-aware asset routing)
// - required confirmations → T-066 (the handoff's per-chain "Watching" table)

enum SendV2MockData {

    // MARK: - Contacts + recents (T-062)

    /// A saved contact (address book) — some ENS-named (green ENS ✓ chip
    /// per the handoff A1 address-book section).
    struct Contact: Hashable, Identifiable, Sendable {
        let id = UUID()
        let name: String
        let address: String
        let network: SupportedChain
        let ensVerified: Bool
        var monogram: String { String(name.prefix(1)).uppercased() }
    }

    /// A recent counterparty (from tx history) — name, address, when.
    struct Recent: Hashable, Identifiable, Sendable {
        let id = UUID()
        let name: String
        let address: String
        let network: SupportedChain
        let relativeWhen: String   // "2d ago", "5h ago" — design-time literal
        var monogram: String { String(name.prefix(1)).uppercased() }
    }

    static let recents: [Recent] = [
        .init(name: "Lina", address: "0x42a1F3c9B7e8D5a2C4f6E8b1D3A5c7E942a1F39F", network: .ethereum, relativeWhen: "2d ago"),
        .init(name: "Marko", address: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh", network: .bitcoin, relativeWhen: "5d ago"),
        .init(name: "Coinbase", address: "0x71C7656EC7ab88b098defB751B7401B5f6d8976F", network: .base, relativeWhen: "1w ago")
    ]

    static let contacts: [Contact] = [
        .init(name: "rami.eth", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", network: .ethereum, ensVerified: true),
        .init(name: "Lina", address: "0x42a1F3c9B7e8D5a2C4f6E8b1D3A5c7E942a1F39F", network: .ethereum, ensVerified: false),
        .init(name: "omar.eth", address: "0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97", network: .ethereum, ensVerified: true),
        .init(name: "Maya", address: "0x1F98431c8aD98523631AE4a59f267346ea31F984", network: .polygon, ensVerified: false)
    ]

    /// Every address the wallet "knows" (recents ∪ contacts), for
    /// first-send detection.
    static var allKnownAddresses: Set<String> {
        Set(recents.map(\.address) + contacts.map(\.address))
    }

    // MARK: - Fee tiers (T-063)

    static func feeTiers(for network: SupportedChain?, fiatPerNative: Decimal) -> [SendV2Model.FeeTier] {
        // Native-fee bases per family (chain units), shaped so the three
        // tiers read believably. fiat = nativeFee × the asset's rate when
        // we have one, else a small flat fiat.
        let (slowNat, normNat, fastNat): (Decimal, Decimal, Decimal)
        switch network?.family {
        case .bitcoin:
            (slowNat, normNat, fastNat) = (d("0.000045"), d("0.000082"), d("0.000140"))
        case .evm:
            (slowNat, normNat, fastNat) = (d("0.00041"), d("0.00072"), d("0.00120"))
        case .ed25519:
            (slowNat, normNat, fastNat) = (d("0.000005"), d("0.000008"), d("0.000012"))
        default:
            (slowNat, normNat, fastNat) = (d("0.0008"), d("0.0012"), d("0.0020"))
        }
        // Rough native→fiat: for token sends we don't have the native
        // rate here, so use a small flat fiat per family when rate is 0.
        let rate = fiatPerNative > 0 ? fiatPerNative : flatNativeFiat(for: network)
        func fiat(_ n: Decimal) -> Decimal { n * rate }
        return [
            .init(speed: .slow,   title: "Slow",   etaSeconds: 180, feeNative: slowNat, feeFiat: fiat(slowNat)),
            .init(speed: .normal, title: "Normal", etaSeconds: 30,  feeNative: normNat, feeFiat: fiat(normNat)),
            .init(speed: .fast,   title: "Fast",   etaSeconds: 10,  feeNative: fastNat, feeFiat: fiat(fastNat))
        ]
    }

    /// A small per-family flat native→fiat used only when the live rate
    /// isn't available in this design layer (token sends).
    private static func flatNativeFiat(for network: SupportedChain?) -> Decimal {
        switch network?.family {
        case .bitcoin: return d("98000")
        case .evm:     return d("6940")
        case .ed25519: return d("240")
        default:       return d("1")
        }
    }

    // MARK: - Fee-aware Max note (T-063)

    static func maxFeeNote(for asset: SendAsset?, feeNative: Decimal) -> String {
        guard let asset else { return "" }
        switch asset {
        case .native(let chain):
            let amount = WalletFormatting.native(feeNative, decimals: chain.nativeDecimals)
            switch chain.family {
            case .bitcoin:
                return "Max sends everything minus the \(amount) \(chain.ticker) network fee."
            case .ed25519 where chain == .solana:
                return "Max keeps ~0.002 SOL for rent and the network fee."
            default:
                return "Max keeps \(amount) \(chain.ticker) for network fees."
            }
        case .token(_, _, let network, _):
            // Token send: fee is paid in the native asset, Max sends the
            // full token. Solana adds an ATA-creation rent notice.
            if network == .solana {
                return "Max sends your full balance. The recipient may need ~0.002 SOL of rent to receive it."
            }
            return "Max sends your full balance. The \(network.ticker) fee is paid separately."
        }
    }

    // MARK: - Cross-network suggestion (T-062)

    /// A "did you mean" suggestion when a recipient's address is for a
    /// different network than the asset selected (handoff D2).
    struct CrossNetworkSuggestion: Equatable, Hashable, Sendable {
        let symbol: String
        let network: SupportedChain
        let balanceLabel: String
        let feeLabel: String
    }

    static func crossNetworkSuggestion(for asset: SendAsset?) -> CrossNetworkSuggestion? {
        guard let asset else { return nil }
        // Design heuristic: if sending a token that also exists on Solana,
        // suggest the Solana variant (the handoff's USDT-on-Ethereum →
        // USDT-on-Solana example).
        if case let .token(symbol, _, network, _) = asset, network != .solana {
            return CrossNetworkSuggestion(
                symbol: symbol,
                network: .solana,
                balanceLabel: "1,840.50 \(symbol)",
                feeLabel: "≈ $0.01 fee"
            )
        }
        return nil
    }

    // MARK: - Required confirmations (T-066 — handoff "Watching" table)

    static func requiredConfirmations(for network: SupportedChain?) -> Int {
        switch network {
        case .ethereum:                    return 12
        case .base, .optimism, .arbitrum:  return 1
        case .polygon:                     return 30
        case .bnbChain, .opBNB:            return 15
        case .avalanche:                   return 1
        case .solana:                      return 32
        case .bitcoin:                     return 3
        default:                           return 6
        }
    }

    // MARK: - Test send (handoff Flow I)

    /// Default test amount in the user's display currency (handoff I:
    /// *"1 unit of the user's display currency"*). The token equivalent is
    /// computed at the asset's rate.
    static let testFiatUnits: [Int] = [1, 2, 5]

    // MARK: - Helper

    private static func d(_ s: String) -> Decimal { Decimal(string: s) ?? 0 }
}
