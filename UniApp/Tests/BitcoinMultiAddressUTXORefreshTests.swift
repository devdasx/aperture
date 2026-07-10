import Foundation
import Testing
@testable import Aperture

/// BUG-005: sign-time UTXO refresh must cover every wallet address for a
/// Bitcoin-family chain, not only `draft.fromAddress`.
struct BitcoinMultiAddressUTXORefreshTests {

    // MARK: - Address set (shared by compose + JIT)

    @Test("walletAddresses prefers fromAddress and dedupes receive/change paths")
    func walletAddressesDedupesAndOrders() {
        let preferred = "bc1qprefer"
        let persisted = [
            "bc1qprefer",          // duplicate of preferred
            "bc1qreceive0",
            "bc1qchange0",
            "bc1qreceive0",        // duplicate
            "  ",                  // empty after trim
            "bc1qreceive1"
        ]
        let addresses = UTXOService.walletAddresses(preferred: preferred, persisted: persisted)
        #expect(addresses == [
            "bc1qprefer",
            "bc1qreceive0",
            "bc1qchange0",
            "bc1qreceive1"
        ])
        #expect(addresses.first == preferred)
        #expect(Set(addresses).count == addresses.count)
    }

    @Test("walletAddresses falls back to preferred alone when no persisted paths")
    func walletAddressesPreferredOnly() {
        let addresses = UTXOService.walletAddresses(preferred: "bc1qonly", persisted: [])
        #expect(addresses == ["bc1qonly"])
    }

    // MARK: - Outpoint rebind

    @Test("rebindSelected returns full live set when nothing is pinned")
    func rebindAutoSelect() throws {
        let live = [
            utxo(owner: "bc1qa", txid: "aa", vout: 0, sats: 10_000),
            utxo(owner: "bc1qb", txid: "bb", vout: 1, sats: 20_000)
        ]
        let rebound = try UTXOService.rebindSelected(selected: nil, live: live)
        #expect(rebound.map(\.id) == live.map(\.id))

        let emptySelected = try UTXOService.rebindSelected(selected: [], live: live)
        #expect(emptySelected.map(\.id) == live.map(\.id))
    }

    @Test("rebindSelected keeps multi-address selection after live refresh")
    func rebindMultiAddressSelection() throws {
        // Compose selected one coin on fromAddress and one on a change path.
        let from = "bc1qfrom"
        let change = "bc1qchange"
        let selected = [
            utxo(owner: from, txid: "tx_from", vout: 0, sats: 50_000, confirmed: true),
            utxo(owner: change, txid: "tx_change", vout: 2, sats: 12_000, confirmed: true)
        ]
        // Live set is wallet-wide (all addresses) with refreshed confirmed flags.
        let live = [
            utxo(owner: change, txid: "tx_change", vout: 2, sats: 12_000, confirmed: true),
            utxo(owner: from, txid: "tx_from", vout: 0, sats: 50_000, confirmed: false),
            utxo(owner: "bc1qother", txid: "tx_other", vout: 0, sats: 99_000, confirmed: true)
        ]

        let rebound = try UTXOService.rebindSelected(selected: selected, live: live)
        #expect(rebound.count == 2)
        #expect(rebound.map(\.id) == ["tx_from:0", "tx_change:2"])
        // Live fields win (e.g. confirmation flipped).
        #expect(rebound[0].confirmed == false)
        #expect(rebound[0].ownerAddress == from)
        #expect(rebound[1].ownerAddress == change)
    }

    @Test("rebindSelected fails when a selected outpoint is missing from live set")
    func rebindMissingOutpoint() {
        let selected = [utxo(owner: "bc1qa", txid: "spent", vout: 0, sats: 1_000)]
        let live = [utxo(owner: "bc1qa", txid: "other", vout: 0, sats: 1_000)]
        #expect(throws: SigningError.self) {
            _ = try UTXOService.rebindSelected(selected: selected, live: live)
        }
    }

    @Test("BUG-005 regression: fromAddress-only live set cannot rebind change-path coins")
    func fromAddressOnlyMissesChangePathSelection() throws {
        let from = "bc1qfrom"
        let change = "bc1qchange"
        let selected = [
            utxo(owner: from, txid: "tx_from", vout: 0, sats: 50_000),
            utxo(owner: change, txid: "tx_change", vout: 1, sats: 12_000)
        ]
        // Old JIT bug: only refreshed draft.fromAddress → change outpoint gone.
        let fromOnlyLive = [
            utxo(owner: from, txid: "tx_from", vout: 0, sats: 50_000)
        ]
        #expect(throws: SigningError.self) {
            _ = try UTXOService.rebindSelected(selected: selected, live: fromOnlyLive)
        }

        // Fixed path: multi-address live set rebinds both.
        let multiLive = fromOnlyLive + [
            utxo(owner: change, txid: "tx_change", vout: 1, sats: 12_000)
        ]
        let rebound = try UTXOService.rebindSelected(selected: selected, live: multiLive)
        #expect(rebound.count == 2)
        #expect(Set(rebound.map(\.ownerAddress)) == Set([from, change]))
    }

    // MARK: - Cache-miss decision (same logic as SendExecutor JIT)

    @Test("cache incomplete vs selection forces multi-address network refresh path")
    func incompleteCacheTriggersNetworkPath() {
        let from = "bc1qfrom"
        let change = "bc1qchange"
        let selected = [
            utxo(owner: from, txid: "a", vout: 0, sats: 10_000),
            utxo(owner: change, txid: "b", vout: 0, sats: 10_000)
        ]
        let cachedFromOnly = [utxo(owner: from, txid: "a", vout: 0, sats: 10_000)]

        // Mirrors SendExecutor: use cache only when rebind succeeds.
        let canUseCache = (try? UTXOService.rebindSelected(
            selected: selected,
            live: cachedFromOnly
        )) != nil
        #expect(canUseCache == false)

        let fullCache = cachedFromOnly + [utxo(owner: change, txid: "b", vout: 0, sats: 10_000)]
        let canUseFullCache = (try? UTXOService.rebindSelected(
            selected: selected,
            live: fullCache
        )) != nil
        #expect(canUseFullCache == true)
    }

    @Test("empty cache cannot satisfy selection — network multi-address required")
    func emptyCacheRequiresNetwork() throws {
        let selected = [utxo(owner: "bc1qa", txid: "x", vout: 0, sats: 1)]
        let empty: [SelectedUTXO] = []
        // Empty live with selection: rebind throws (nothing spendable).
        #expect(throws: SigningError.self) {
            _ = try UTXOService.rebindSelected(selected: selected, live: empty)
        }
        // Empty live + no selection: auto-select returns empty (honest).
        let auto = try UTXOService.rebindSelected(selected: nil, live: empty)
        #expect(auto.isEmpty)
    }

    // MARK: - Helpers

    private func utxo(
        owner: String,
        txid: String,
        vout: Int,
        sats: Int64,
        confirmed: Bool = true
    ) -> SelectedUTXO {
        SelectedUTXO(
            ownerAddress: owner,
            txid: txid,
            vout: vout,
            valueSats: sats,
            scriptHex: nil,
            confirmed: confirmed
        )
    }
}
