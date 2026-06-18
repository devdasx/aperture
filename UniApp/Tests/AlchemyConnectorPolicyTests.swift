import Testing
import Foundation
@testable import Aperture

/// **Alchemy token anti-spam policy unit tests (2026-06-19).**
///
/// Pins the heuristic that replaced the old 79-entry stablecoin allowlist:
/// a non-canonical (not registry, not user-custom) ERC-20 shows only when it
/// carries a real USD price, clears the dust floor, and has a clean name —
/// so legitimate holdings (LINK, UNI, ARB, …) surface while scam airdrops
/// (no price, junk/URL names) stay hidden. Pure, network-free seams.
struct AlchemyConnectorPolicyTests {

    // MARK: - looksLikeSpam

    @Test("looksLikeSpam flags empty symbols, URLs, and claim-bait; passes real tokens")
    func spamDetection() {
        #expect(AlchemyConnector.looksLikeSpam(symbol: "", name: "Anything") == true)
        #expect(AlchemyConnector.looksLikeSpam(symbol: "   ", name: "Anything") == true)
        #expect(AlchemyConnector.looksLikeSpam(symbol: "CLAIM", name: "claim-rewards.xyz") == true)
        #expect(AlchemyConnector.looksLikeSpam(symbol: "FREE", name: "Visit my-airdrop.com to redeem") == true)
        #expect(AlchemyConnector.looksLikeSpam(symbol: "GIFT", name: "t.me/scamchannel") == true)
        // Real tokens pass.
        #expect(AlchemyConnector.looksLikeSpam(symbol: "LINK", name: "Chainlink Token") == false)
        #expect(AlchemyConnector.looksLikeSpam(symbol: "UNI", name: "Uniswap") == false)
        #expect(AlchemyConnector.looksLikeSpam(symbol: "ARB", name: "Arbitrum") == false)
        #expect(AlchemyConnector.looksLikeSpam(symbol: "USDC", name: "USD Coin") == false)
    }

    // MARK: - heuristicDrop

    @Test("heuristicDrop hides unpriced tokens (the strongest spam signal)")
    func dropsUnpriced() {
        #expect(AlchemyConnector.heuristicDrop(amount: 1000, symbol: "SCAM", name: "Scam", priceUSD: nil) == .noPrice)
        #expect(AlchemyConnector.heuristicDrop(amount: 1000, symbol: "SCAM", name: "Scam", priceUSD: 0) == .noPrice)
    }

    @Test("heuristicDrop hides sub-cent dust even when priced")
    func dropsDust() {
        // 1 token × $0.0001 = $0.0001 < $0.01 dust floor.
        #expect(AlchemyConnector.heuristicDrop(amount: 1, symbol: "TINY", name: "Tiny", priceUSD: Decimal(string: "0.0001")) == .dust)
    }

    @Test("heuristicDrop hides a priced, above-dust token with a spam name")
    func dropsPricedSpam() {
        #expect(AlchemyConnector.heuristicDrop(amount: 100, symbol: "FREE", name: "claim at reward.xyz", priceUSD: 1) == .spam)
    }

    @Test("heuristicDrop shows a real, priced, above-dust token with a clean name")
    func showsRealToken() {
        // 0.5 LINK × $14.20 = $7.10 ≥ dust, clean name → show (nil = no drop).
        #expect(AlchemyConnector.heuristicDrop(amount: Decimal(string: "0.5")!, symbol: "LINK", name: "Chainlink Token", priceUSD: Decimal(string: "14.20")) == nil)
    }

    @Test("dust threshold is exactly one cent")
    func dustThreshold() {
        #expect(AlchemyConnector.dustThresholdUSD == Decimal(string: "0.01"))
        // Exactly at the floor shows; a hair under is dust.
        #expect(AlchemyConnector.heuristicDrop(amount: 1, symbol: "X", name: "X token", priceUSD: Decimal(string: "0.01")) == nil)
        #expect(AlchemyConnector.heuristicDrop(amount: 1, symbol: "X", name: "X token", priceUSD: Decimal(string: "0.009")) == .dust)
    }
}
