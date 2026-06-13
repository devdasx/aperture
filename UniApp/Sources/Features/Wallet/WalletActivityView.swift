import SwiftUI
import SwiftData

/// **"View all" destination** behind the wallet-home "Recent activity"
/// header's `View all` link. Lists EVERY transaction across EVERY
/// address of the active wallet — newest first — without the five-row
/// cap the home surfaces.
///
/// **Design intent (Rule #2 §D.1):** when the user wants their whole
/// history, give them the same rows they already recognize from the
/// home — the same `ActivityRow` — unbounded and in time order. No new
/// visual vocabulary; the screen is "the home's activity list, longer."
/// This mirrors `AssetActivityView` (the per-asset "View all") so the
/// two histories read as one family.
///
/// **Scope.** This is the wallet-wide counterpart to
/// `AssetActivityView`. That screen is asset-scoped — it carries an
/// `AssetIdentity`, resolves asset networks, and presents an
/// asset-coupled filter sheet. None of that generalizes to "all
/// assets" without rewriting the filter plumbing, so this view ships
/// the clean wallet-wide form: every transaction, sorted, no filter.
/// The core ask — "see ALL transactions" — is met in full. A future
/// turn can add a sort/direction filter here if the user asks for it.
///
/// **Layout (Rule #15 — pushed-screen contract).** Inherits the
/// wallet-home's `NavigationStack`. Title via `.navigationTitle` so
/// the system handles scroll compression natively. Native
/// `List(.insetGrouped)`; rows route to the shared
/// `WalletHomeDestination.transaction(_:)` detail.
///
/// **Wallet truth (matches `WalletHomeView`).** The active wallet is
/// resolved the same hardened store-truth way the home does — the
/// `@Query`-backed `allWallets` lags repository inserts/switches, so a
/// freshly-switched or freshly-imported wallet would otherwise show
/// the *previous* wallet's history for one merge window. Asking the
/// store directly (`modelContext.fetch`) closes that gap, so this
/// screen never shows the wrong wallet's transactions.
struct WalletActivityView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    /// Memoized newest-first feed. Rebuilt only when the wallet's data
    /// fingerprint changes (a confirmed tx, a new import, a switch) —
    /// not per body pass — so the `flatMap` + `sort` over a 1,000-tx
    /// per-chain history doesn't run on every render.
    @State private var sortedTransactions: [TransactionRecord] = []

    var body: some View {
        List {
            if sortedTransactions.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(sortedTransactions, id: \.id) { tx in
                        if let chain = chainFor(tx) {
                            NavigationLink(value: WalletHomeDestination.transaction(tx.id)) {
                                activityRow(tx, chain: chain)
                            }
                        } else {
                            // The parent address record is missing or
                            // carries an unrecognized chain — render the
                            // row plain, with NO NavigationLink, so the
                            // user is never routed against wrong-chain
                            // data. (Same guard `AssetActivityView`
                            // uses — a silent `.ethereum` fallback once
                            // showed users the wrong chain's detail.)
                            activityRow(tx, chain: .ethereum)
                        }
                    }
                } header: {
                    Text(headerLabel(count: sortedTransactions.count))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: WalletDataFingerprint.make(for: activeWallet)) {
            rebuild()
        }
    }

    // MARK: - Empty state

    /// Mirrors `AssetActivityView`'s empty state — same component, same
    /// register. Reached only when the active wallet has zero
    /// transactions across every address (the "View all" link that
    /// routes here is hidden in that case, so this is a defensive
    /// surface: a wallet whose last tx was pruned, or a deep-link /
    /// restored path landing here directly).
    private var emptyState: some View {
        UniEmptyState(
            title: "No activity yet.",
            detail: "Transactions appear here as they confirm on-chain.",
            mark: .icon(systemName: "list.bullet.rectangle.portrait")
        )
    }

    // MARK: - Header

    private func headerLabel(count: Int) -> String {
        String(
            format: String(localized: "All %lld transactions"),
            Int64(count)
        )
    }

    // MARK: - Feed

    /// Resolve + flatten + sort once. Newest-first across every
    /// address of the active wallet, reflecting the full history the DB
    /// holds (the adapters paginate to 1,000 txs/chain).
    private func rebuild() {
        guard let wallet = activeWallet else {
            sortedTransactions = []
            return
        }
        sortedTransactions = wallet.addresses
            .flatMap { $0.transactions }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    // MARK: - Wallet plumbing (store-truth, matches WalletHomeView)

    /// Active wallet resolved with the same hardened precedence the
    /// wallet-home uses: stored id → `@Query` match → direct store
    /// fetch (covers the `@Query` merge lag) → first existing wallet.
    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw) {
            if let match = allWallets.first(where: { $0.id == uuid }) {
                return match
            }
            var descriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == uuid }
            )
            descriptor.fetchLimit = 1
            if let stored = try? modelContext.fetch(descriptor).first {
                return stored
            }
        }
        return allWallets.first(where: { walletExists(id: $0.id) })
    }

    private func walletExists(id: UUID) -> Bool {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Resolves the chain a `TransactionRecord` belongs to. Returns
    /// `nil` when the parent address record is missing or carries an
    /// unrecognized chain — callers must NOT route such a row anywhere
    /// (no silent `.ethereum` fallback for navigation; that showed
    /// users wrong-chain data).
    private func chainFor(_ tx: TransactionRecord) -> SupportedChain? {
        guard let raw = tx.address?.chainRaw,
              let chain = SupportedChain(rawValue: raw) else { return nil }
        return chain
    }

    /// Shared row label for both the navigable and the plain
    /// (unresolvable-chain) activity entries — the same `ActivityRow`
    /// the wallet-home and `AssetActivityView` use.
    private func activityRow(_ tx: TransactionRecord, chain: SupportedChain) -> ActivityRow {
        ActivityRow(
            chain: chain,
            direction: TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing,
            amount: Decimal(string: tx.amountRaw) ?? .zero,
            tokenSymbol: tx.tokenSymbol,
            counterparty: tx.counterparty,
            occurredAt: tx.occurredAt,
            status: TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed
        )
    }
}
