import Foundation
import Testing
@testable import Aperture

struct TonBalanceHistoryProbeTests {
    @Test("TON balance, supported jetton balance, and history live read")
    func tonBalanceHistoryLiveRead() async throws {
        let owner = "0:23fa979918f1fe702db9100bf843e87c7015eccd39a4721e9b6bac170bc04ce3"
        let client = TonBalanceHistoryClient()
        let start = ContinuousClock.now

        async let snapshotTask = client.accountSnapshot(
            address: owner,
            supportedTokens: TONJettonRegistry.tokens
        )
        async let eventsTask = client.recentEvents(
            address: owner,
            supportedTokens: TONJettonRegistry.tokens
        )

        let snapshot = try await snapshotTask
        let events = try await eventsTask
        let elapsed = start.duration(to: ContinuousClock.now)

        #expect(Decimal(string: snapshot.rawTON) ?? 0 > 0, "known TON treasury account should hold native TON")
        let usdt = try #require(snapshot.jettonBalances.first { $0.entry.symbol == "USDT" })
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0, "known TON treasury account should hold supported USDT jetton")
        #expect(events.contains { $0.tokenSymbol == SupportedChain.ton.ticker }, "history should include native TON transfers")
        #expect(events.contains { $0.tokenSymbol == "USDT" }, "history should include supported USDT jetton transfers")
        #expect(events.allSatisfy { !$0.txHash.isEmpty && !$0.amount.isEmpty }, "history rows should be persisted-ready")
        #expect(elapsed < .seconds(20), "TON balance/history probe should stay responsive; elapsed \(elapsed)")
    }
}
