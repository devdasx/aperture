import Foundation
import SwiftData

/// Background-safe mutation surface for `CustomTokenRecord`. Parallels
/// `WalletRepository` in shape — `@ModelActor` with its own
/// `ModelContext`, methods return after `save()` so callers can rely on
/// `@Query`-driven SwiftUI views to pick up the change on the next
/// frame.
///
/// **Dedup contract.** `(chain, contract)` uniquely identifies a custom
/// token. `add(_:)` throws `CustomTokenError.duplicate` if a row with
/// the same `dedupKey` already exists. `fetchByContract(...)` uses the
/// same case-insensitive compare so callers can detect the duplicate
/// before showing the Add sheet's "Save" CTA.
///
/// **Read consistency.** `fetchAll(chain:)` and `fetchByContract(...)`
/// take a snapshot at call time — repeat callers of `fetchAll` after
/// an `add` see the new row. Per-chain scanner loops in
/// `RealRPCBalanceScanner` instantiate the repository per scan, so
/// the most recent additions are visible to the next refresh.
@ModelActor
actor CustomTokenRepository {

    /// Insert a new custom-token row. Throws `.duplicate` if the
    /// `(chain, contract)` pair already exists.
    ///
    /// The caller is expected to have validated the contract via
    /// `ContractValidator` and to have passed the normalized form
    /// (EIP-55 checksummed for EVM, verbatim base58 for Solana).
    /// Repository does NOT re-validate — that's the Add sheet's job.
    func add(
        id: UUID = UUID(),
        chain: SupportedChain,
        contract: String,
        symbol: String,
        name: String,
        decimals: Int,
        iconURL: String? = nil,
        metadataFromChain: Bool = true
    ) throws {
        if try fetchRecord(chain: chain, contract: contract) != nil {
            throw CustomTokenError.duplicate
        }
        let record = CustomTokenRecord(
            id: id,
            chainRaw: chain.rawValue,
            contract: contract,
            symbol: symbol,
            name: name,
            decimals: decimals,
            iconURL: iconURL,
            addedAt: Date(),
            metadataFromChain: metadataFromChain
        )
        modelContext.insert(record)
        try modelContext.save()
    }

    /// Delete a custom-token row by its UUID. No-op if the row is
    /// already gone.
    func remove(id: UUID) throws {
        var descriptor = FetchDescriptor<CustomTokenRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let match = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(match)
        try modelContext.save()
    }

    /// Fetch every custom token, optionally filtered to one chain.
    /// `nil` chain returns every row across every chain — used by
    /// the Custom Tokens list screen when displaying sections by
    /// chain.
    ///
    /// Returns a snapshot of plain-value `CustomTokenSnapshot`
    /// structs (Sendable) so callers across actor boundaries don't
    /// hold `@Model` references. The scanner loop in
    /// `RealRPCBalanceScanner` consumes the snapshot form.
    func fetchAll(chain: SupportedChain? = nil) throws -> [CustomTokenSnapshot] {
        let descriptor = FetchDescriptor<CustomTokenRecord>(
            sortBy: [SortDescriptor(\.symbol, order: .forward)]
        )
        let all = try modelContext.fetch(descriptor)
        // Gate on `hasKnownChain` HERE — `CustomTokenSnapshot` carries a
        // non-optional `chain` whose decode falls back to `.ethereum`,
        // so the snapshot type erases the unknown-chain signal. A row
        // whose `chainRaw` no longer decodes (e.g. a retired
        // `SupportedChain` rawValue) must not be scanned or displayed
        // as if it lived on Ethereum, per the contract documented on
        // `CustomTokenRecord.hasKnownChain`.
        let known = all.filter { $0.hasKnownChain }
        let filtered: [CustomTokenRecord]
        if let chain {
            filtered = known.filter { $0.chainRaw == chain.rawValue }
        } else {
            filtered = known
        }
        return filtered.map { CustomTokenSnapshot(from: $0) }
    }

    /// Lookup a single custom token by `(chain, contract)`. Returns
    /// `nil` if not found. Used by the Add sheet to detect a
    /// duplicate before the user taps Save.
    func fetchByContract(
        chain: SupportedChain,
        contract: String
    ) throws -> CustomTokenSnapshot? {
        guard let match = try fetchRecord(chain: chain, contract: contract) else {
            return nil
        }
        return CustomTokenSnapshot(from: match)
    }

    /// Dedup lookup by `(chain, contract)`. Two-step fetch instead of a
    /// full-table scan: an exact-equality predicate (`chainRaw` +
    /// `contract`, fetchLimit 1) catches the normalized-form fast path,
    /// then a chain-scoped predicate narrows the case-insensitive
    /// `dedupKey` comparison to that one chain's rows. `#Predicate`
    /// has no store-evaluated case-insensitive equality, so the
    /// lowercased compare runs in memory — but only over the handful
    /// of custom tokens on the matching chain, never the whole table.
    private func fetchRecord(
        chain: SupportedChain,
        contract: String
    ) throws -> CustomTokenRecord? {
        let chainValue = chain.rawValue
        var exactDescriptor = FetchDescriptor<CustomTokenRecord>(
            predicate: #Predicate { $0.chainRaw == chainValue && $0.contract == contract }
        )
        exactDescriptor.fetchLimit = 1
        if let exact = try modelContext.fetch(exactDescriptor).first {
            return exact
        }

        let key = "\(chainValue)|\(contract.lowercased())"
        let chainDescriptor = FetchDescriptor<CustomTokenRecord>(
            predicate: #Predicate { $0.chainRaw == chainValue }
        )
        return try modelContext.fetch(chainDescriptor).first { $0.dedupKey == key }
    }
}

/// Sendable value snapshot of a `CustomTokenRecord`. Used to cross
/// actor boundaries — `@Model` instances are tied to their owning
/// `ModelContext` and can't be passed across isolation domains; this
/// struct is the carrier.
struct CustomTokenSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let chain: SupportedChain
    let contract: String
    let symbol: String
    let name: String
    let decimals: Int
    let iconURL: String?
    let addedAt: Date
    let metadataFromChain: Bool

    init(from record: CustomTokenRecord) {
        self.id = record.id
        self.chain = record.chain
        self.contract = record.contract
        self.symbol = record.symbol
        self.name = record.name
        self.decimals = record.decimals
        self.iconURL = record.iconURL
        self.addedAt = record.addedAt
        self.metadataFromChain = record.metadataFromChain
    }
}

/// Errors a `CustomTokenRepository` can throw.
enum CustomTokenError: Error, Sendable, Equatable {
    /// A row with the same `(chain, contract)` already exists.
    case duplicate
}
