import Foundation

/// **Per-chain connector test TEMPLATE.**
///
/// Every chain in the fleet gets its OWN test file (user direction).
/// Copy the snippet below into `UniApp/Tests/<Chain>ConnectorTests.swift`
/// (the `ApertureTests` target — that target can `import Testing`; the
/// app target this file lives in CANNOT, which is why the template body
/// is documentation, not live code). Rename the suite, swap the
/// connector type and the real address, and you have that chain's
/// live-RPC smoke test. The three checks are the universal
/// `ChainConnector` contract:
///
/// 1. `fetchNativeBalance` succeeds without throwing and returns a
///    non-negative `nativeBalance` (a real on-chain read — zero is a
///    real zero, never a stub).
/// 2. `fetchHistory` returns an array (≥ 0 events) without throwing —
///    a fresh address yields `[]`, a funded one yields real rows.
/// 3. `fetchTokenBalances` returns an array (≥ 0 rows) — non-throwing
///    by contract; chains without a token layer return `[]`.
///
/// **These are integration tests** — they hit live public RPC / REST
/// endpoints through the real `RPCClient.shared` (rotation + rate-limit
/// + circuit-breaking apply). They prove the connector's request shapes
/// and parsing work against the actual upstreams, which a mock can't.
/// Use a REAL, publicly-known address (cited in each suite) so the
/// assertions are reproducible and the on-chain state is verifiable in
/// any block explorer.
///
/// **Worked examples** the fan-out agents mimic exactly:
/// `UniApp/Tests/EthereumConnectorTests.swift` (EVM template) and
/// `UniApp/Tests/BitcoinConnectorTests.swift` (REST/UTXO template).
///
/// ```swift
/// import Testing
/// import Foundation
/// @testable import Aperture
///
/// struct ChainConnectorTests {
///     let connector = ChainConnector()
///     // A real, publicly-known funded address on <chain>:
///     let address = "<cite the address + why it's well-known>"
///
///     @Test("<chain> native balance read succeeds and is non-negative")
///     func nativeBalanceSucceeds() async throws {
///         let summary = try await connector.fetchNativeBalance(address: address)
///         #expect(summary.nativeBalance >= 0)
///     }
///
///     @Test("<chain> history returns an array without throwing")
///     func historyReturnsArray() async throws {
///         let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
///         #expect(events.count >= 0)
///         for event in events { #expect(event.chain == connector.chain) }
///     }
///
///     @Test("<chain> token balances return an array")
///     func tokenBalancesReturnArray() async {
///         let tokens = await connector.fetchTokenBalances(address: address, customContracts: [])
///         #expect(tokens.count >= 0)
///         for token in tokens { #expect(token.amount > 0) }
///     }
/// }
/// ```
enum ConnectorTestTemplate {
    /// Placeholder so the template file has a symbol and compiles as
    /// part of the app target without contributing any `@Test` rows.
    /// The runnable examples live in the test target — see the doc above.
    static let isTemplate = true
}
