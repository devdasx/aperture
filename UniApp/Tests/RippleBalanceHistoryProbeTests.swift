import Foundation
import Testing
@testable import Aperture

struct RippleBalanceHistoryProbeTests {
    @Test("XRP Ledger native balance, supported IOU balance, and history live read")
    func rippleBalanceHistoryLiveRead() async throws {
        let owner = "rMwNibdiFaEzsTaFCG1NnmAM3Rv3vHUy5L"
        let client = RippleBalanceHistoryClient()
        let start = ContinuousClock.now

        async let snapshotTask = client.accountSnapshot(
            address: owner,
            supportedTokens: XRPLTokenRegistry.tokens
        )
        async let eventsTask = client.recentEvents(
            address: owner,
            supportedTokens: XRPLTokenRegistry.tokens
        )

        let snapshot = try await snapshotTask
        let events = try await eventsTask
        let elapsed = start.duration(to: ContinuousClock.now)

        #expect(Decimal(string: snapshot.rawXRP) ?? 0 > 0, "known XRP Ledger account should hold native XRP drops")
        let rlusd = try #require(snapshot.tokenBalances.first { $0.entry.symbol == "RLUSD" })
        #expect(Decimal(string: rlusd.rawBalance) ?? 0 > 0, "known XRP Ledger account should hold supported RLUSD IOU")
        #expect(events.contains { $0.tokenSymbol == SupportedChain.ripple.ticker }, "history should include native XRP payments")
        #expect(events.contains { $0.tokenSymbol == "RLUSD" }, "history should include supported RLUSD payments")
        #expect(events.allSatisfy { !$0.txHash.isEmpty && !$0.amount.isEmpty }, "history rows should be persisted-ready")
        #expect(elapsed < .seconds(20), "XRP Ledger balance/history probe should stay responsive; elapsed \(elapsed)")

        print("""
        [RippleProbe] account=\(owner) elapsed=\(elapsed)
        [RippleProbe] rawXRP=\(snapshot.rawXRP)
        [RippleProbe] tokenBalances=\(snapshot.tokenBalances.map { "\($0.entry.symbol)=\($0.rawBalance)" }.joined(separator: ","))
        [RippleProbe] events=\(events.count) native=\(events.filter { $0.tokenContract == nil }.count) tokens=\(events.filter { $0.tokenContract != nil }.count)
        """)
    }
}
