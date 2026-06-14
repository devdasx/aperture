import SwiftUI
import Observation

// MARK: - Send v2 view model
//
// **The Send v2 flow's single source of UI truth** and the boundary
// between the DESIGN track (these screens) and the future domain layer
// (signing / broadcast / RPC / ENS / fee estimation).
//
// Per the prompt this is the DESIGN track only — no real signing,
// broadcast, or RPC. Every domain interaction is a clearly-named `async`
// **seam** with realistic placeholder data behind it, marked `// TODO:`
// and mirrored to TODO.md (T-061..T-066, T-068..T-071). When the domain
// layer lands, the bodies of these seams are replaced; the screens that
// call them do not change.
//
// **Seams the domain layer will implement (the named boundary):**
// - `resolveRecipient(_:)`     → ENS/SNS/name resolution + validation (T-062)
// - `detectPoisoning(_:)`      → address-poisoning guard (T-062)
// - `estimateFees()`           → per-chain fee tiers (T-063)
// - `simulate()`               → pre-flight balance-change simulation (T-068)
// - `send() async`             → sign + broadcast + lifecycle (T-066)
// - `speedUp(_:)` / `cancel()` → RBF / replacement (T-069)
//
// Swift 6.2 `@Observable` (Rule #2 §C — never `ObservableObject`),
// `@MainActor` (UI state). It composes the existing `SendDraft` (recipient
// text, asset, amount, fee selection, advanced params, held balances) so
// the v1 advanced power-sheets keep working unchanged, and adds the v2
// safety + simulation + lifecycle state on top.

@MainActor
@Observable
final class SendV2Model {

    // MARK: - Composed draft (carries the v1 UI state + advanced sheets)

    /// The underlying draft — recipient input, selected asset, typed
    /// amount, fee selection, per-chain advanced params, DB-sourced held
    /// balances. Shared with the v1 advanced power-sheets (re-skinned in
    /// v2), so coin-control / EVM gas / Solana priority keep working.
    let draft: SendDraft

    init(draft: SendDraft = SendDraft()) {
        self.draft = draft
    }

    // MARK: - Recipient resolution + safety (seams: T-062)

    /// The live resolution of the current recipient input. `nil` until a
    /// resolve runs; `.resolving` while in flight; `.resolved` /
    /// `.invalid` / `.poisoned` on completion.
    var recipientState: RecipientState = .empty

    /// The paste-validation card state (Flow D1/D2). `nil` when no paste
    /// has been validated this session.
    var pasteValidation: PasteValidation?

    /// **SEAM (T-062).** Resolve a recipient input — ENS/SNS name
    /// resolution, address checksum + format validation, network-match,
    /// first-send detection. Replace the body with the real resolver.
    ///
    /// DESIGN placeholder: recognises one sample ENS name, treats
    /// address-shaped input (≥20 chars, no spaces) as valid, and flags
    /// any input matching a saved address's prefix+suffix but differing in
    /// the middle as poisoned (via `detectPoisoning`).
    func resolveRecipient(_ input: String) async {
        // TODO: (T-062) Real ENS/SNS resolution + checksum/format validation + network-match.
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { recipientState = .empty; return }

        recipientState = .resolving
        // Simulate resolver latency so the design shows the resolving beat.
        try? await Task.sleep(for: .milliseconds(450))

        // Poisoning guard runs first — it's the highest-stakes outcome.
        if let poisoned = detectPoisoning(trimmed) {
            recipientState = .poisoned(poisoned)
            return
        }

        if SendMockData.isResolvableName(trimmed) {
            let address = SendMockData.sampleResolvedAddress
            recipientState = .resolved(
                ResolvedRecipient(
                    name: trimmed,
                    address: address,
                    network: draft.network ?? .ethereum,
                    isFirstSend: !SendV2MockData.contacts.contains { $0.address == address },
                    ensVerified: true
                )
            )
            return
        }

        // Address-shaped placeholder validity.
        if trimmed.count >= 20, !trimmed.contains(" ") {
            recipientState = .resolved(
                ResolvedRecipient(
                    name: nil,
                    address: trimmed,
                    network: draft.network ?? .ethereum,
                    isFirstSend: !SendV2MockData.allKnownAddresses.contains(trimmed),
                    ensVerified: false
                )
            )
        } else {
            recipientState = .invalid
        }
    }

    /// **SEAM (T-062).** Address-poisoning detection. Returns a
    /// `PoisonMatch` when `pasted` matches a known address's first ≥4 and
    /// last ≥4 chars but differs in the middle (the dust-attack pattern),
    /// else `nil`. Replace with the real check against the wallet's
    /// address book + recent counterparties.
    ///
    /// DESIGN placeholder: compares against `SendV2MockData.contacts`.
    func detectPoisoning(_ pasted: String) -> PoisonMatch? {
        let p = pasted.lowercased()
        guard p.count >= 12 else { return nil }
        let pPrefix = p.prefix(6)
        let pSuffix = p.suffix(6)
        for contact in SendV2MockData.contacts {
            let k = contact.address.lowercased()
            guard k.count >= 12, k != p else { continue }
            if k.prefix(6) == pPrefix && k.suffix(6) == pSuffix {
                // Same ends, different middle → poisoning.
                return PoisonMatch(savedName: contact.name, savedAddress: contact.address, pastedAddress: pasted)
            }
        }
        return nil
    }

    /// **SEAM (T-062).** Validate a pasted/clipboard address per the
    /// active asset's chain — used by the Paste card (Flow D1/D2). Returns
    /// the validation outcome (valid, wrong-network with a suggested fix,
    /// or invalid). Replace with the real per-chain validator.
    func validatePaste(_ value: String) -> PasteValidation {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let network = draft.network ?? .ethereum
        // Crude cross-network heuristic for the design: a Solana-shaped
        // base58 address pasted while on EVM → wrong-network suggestion.
        let looksSolana = trimmed.count >= 32 && trimmed.count <= 44 && !trimmed.hasPrefix("0x") && !trimmed.contains("1") == false
        if network.family == .evm, !trimmed.hasPrefix("0x"), looksSolana,
           let alt = SendV2MockData.crossNetworkSuggestion(for: draft.asset) {
            return .wrongNetwork(suggested: alt)
        }
        if trimmed.count >= 20, !trimmed.contains(" ") {
            return .valid(network: network, inAddressBook: SendV2MockData.allKnownAddresses.contains(trimmed))
        }
        return .invalid(network: network)
    }

    // MARK: - Fees (seam: T-063)

    /// The fee tiers offered on the fee-speed sheet (E3). Empty until
    /// `estimateFees()` runs.
    var feeTiers: [FeeTier] = []

    /// The selected fee tier id (drives the Review fee chip + total).
    var selectedFeeTierId: FeeTier.Speed = .normal

    /// **SEAM (T-063).** Estimate per-chain fee tiers. Replace with real
    /// per-chain fee endpoints (EVM gas oracle, Bitcoin mempool feerate,
    /// Solana priority fee). DESIGN placeholder: three tiers shaped by the
    /// network family with believable times + fiat figures.
    func estimateFees() -> [FeeTier] {
        // Synchronous seed for first render; `loadFeeTiers()` replaces these
        // with REAL on-chain fees the moment the screen's `.task` runs.
        let tiers = SendV2MockData.feeTiers(for: draft.network, fiatPerNative: draft.unitFiatRate)
        if feeTiers.isEmpty { feeTiers = tiers }
        return feeTiers
    }

    /// Load REAL fee tiers for the active chain. EVM uses the live gas
    /// oracle (`EVMSendService.loadFees`); families not yet wired keep the
    /// placeholder tiers. Off-main (Rule #28); call from the screen's
    /// `.task`. Honest fee display (Rule #16): the slider charges what's
    /// shown.
    func loadFeeTiers() async {
        guard let asset = draft.asset, let chain = draft.network,
              let to = draft.resolvedAddress, !to.isEmpty else {
            if feeTiers.isEmpty {
                feeTiers = SendV2MockData.feeTiers(for: draft.network, fiatPerNative: draft.unitFiatRate)
            }
            return
        }
        let isNative: Bool = { if case .native = asset { return true } else { return false } }()
        let raw = ChainAmount.rawInteger(from: draft.cryptoAmount, decimals: asset.decimals)
        do {
            let options = try await ChainSendRouter.loadFees(
                chain: chain, toAddress: to, rawAmount: raw == "0" ? "1" : raw,
                isNative: isNative, contract: asset.contract, decimals: asset.decimals,
                container: ApertureDatabase.shared.container
            )
            // Fee is paid in the native coin; for a native send that's the
            // sent asset (its fiat rate applies). Token-send fee fiat is a
            // later refinement (needs the native coin's rate).
            let nativeRate: Decimal = isNative ? draft.unitFiatRate : 0
            feeTiers = options.map { opt in
                FeeTier(
                    speed: FeeTier.Speed(rawValue: opt.speed.rawValue) ?? .normal,
                    title: Self.feeTierTitle(opt.speed),
                    etaSeconds: opt.estimatedSeconds,
                    feeNative: opt.feeNative,
                    feeFiat: opt.feeNative * nativeRate
                )
            }
        } catch {
            if feeTiers.isEmpty {
                feeTiers = SendV2MockData.feeTiers(for: draft.network, fiatPerNative: draft.unitFiatRate)
            }
        }
    }

    private static func feeTierTitle(_ speed: ChainFeeOption.Speed) -> LocalizedStringKey {
        switch speed {
        case .slow:   return "Slow"
        case .normal: return "Normal"
        case .fast:   return "Fast"
        }
    }

    /// The currently-selected tier (falls back to the first estimated).
    var selectedFeeTier: FeeTier? {
        feeTiers.first { $0.speed == selectedFeeTierId } ?? feeTiers.first
    }

    /// The resolved network fee in fiat for the Review total.
    var networkFeeFiat: Decimal {
        selectedFeeTier?.feeFiat ?? draft.networkFeeFiat
    }

    /// The resolved network fee in the chain's native units.
    var networkFeeNative: Decimal {
        selectedFeeTier?.feeNative ?? draft.networkFeeNative
    }

    // MARK: - Fee-aware Max (seam: T-063)

    /// A short, honest note about what Max reserves on this chain. Drives
    /// the handoff's fee note under the 25/50/Max chips:
    /// *"Max keeps 0.0021 ETH for network fees."*
    var maxFeeNote: String {
        SendV2MockData.maxFeeNote(for: draft.asset, feeNative: networkFeeNative)
    }

    /// Apply a percentage of the available balance (25 / 50). For Max
    /// (100), reserves the native fee on a native send so the user can
    /// still cover gas (fee-aware Max — handoff requirement).
    func applyPercent(_ percent: Int) {
        draft.isShowingFiat = false
        let available = draft.availableBalance
        guard available > 0 else { return }
        if percent >= 100 {
            // Fee-aware: native sends deduct the fee; token sends send
            // the full token (fee is paid in the native asset).
            let reserve: Decimal
            switch draft.asset {
            case .native:  reserve = networkFeeNative
            case .token, .none: reserve = 0
            }
            let target = max(0, available - reserve)
            draft.amountInput = WalletFormatting.native(target, decimals: draft.asset?.decimals ?? 8)
        } else {
            let fraction = Decimal(percent) / 100
            draft.amountInput = WalletFormatting.native(available * fraction, decimals: draft.asset?.decimals ?? 8)
        }
        selectedPercent = percent
    }

    /// Which percentage chip is selected (for the dark-glass selected
    /// state), or nil if the user typed a custom amount.
    var selectedPercent: Int?

    // MARK: - Simulation (seam: T-068)

    /// The pre-flight simulation result — one row per balance change. Empty
    /// until `simulate()` runs.
    var simulation: [BalanceChange] = []
    /// True while a simulation is in flight (Review shows a quiet
    /// "Checking…" state).
    var isSimulating: Bool = false
    /// A simulated revert — when non-nil the Review blocks the commit and
    /// surfaces the decoded reason (handoff H4). DESIGN: always nil.
    var simulationRevert: String?

    /// **SEAM (T-068).** Run a real pre-flight simulation (eth_call /
    /// debug_traceCall on EVM, simulateTransaction on Solana, etc.) and
    /// return the actual balance deltas — *"not arithmetic alone (catches
    /// reverts, token taxes)"*. Replace the body with the real simulation.
    ///
    /// DESIGN placeholder: the amount as a negative delta on the sent
    /// asset + the fee as a negative delta on the native asset.
    func simulate() async -> [BalanceChange] {
        // TODO: (T-068) Real pre-flight simulation — eth_call / debug_traceCall (EVM),
        // simulateTransaction (Solana). Return actual balance deltas + catch reverts.
        isSimulating = true
        defer { isSimulating = false }
        try? await Task.sleep(for: .milliseconds(600))

        var changes: [BalanceChange] = []
        if let asset = draft.asset {
            changes.append(
                BalanceChange(
                    assetName: asset.displayName,
                    symbol: asset.unitTicker,
                    delta: -draft.cryptoAmount,
                    decimals: asset.decimals,
                    isFee: false
                )
            )
            // Fee row — on the native asset, separate from the sent asset
            // for token sends.
            if case .token = asset, let network = draft.network {
                changes.append(
                    BalanceChange(
                        assetName: network.displayName + " · fee",
                        symbol: network.ticker,
                        delta: -networkFeeNative,
                        decimals: network.nativeDecimals,
                        isFee: true
                    )
                )
            } else if let network = draft.network {
                // Native send: fee folds into the same asset; show it as a
                // separate fee row anyway for honesty.
                changes.append(
                    BalanceChange(
                        assetName: network.displayName + " · fee",
                        symbol: network.ticker,
                        delta: -networkFeeNative,
                        decimals: network.nativeDecimals,
                        isFee: true
                    )
                )
            }
        }
        simulation = changes
        simulationRevert = nil   // DESIGN: never a revert
        return changes
    }

    // MARK: - Whale check (handoff B3)

    /// Whether the send is more than 50% of the asset's balance — the
    /// whale-check gate. Neutral (not an error).
    var isWhaleSend: Bool {
        let available = draft.availableBalance
        guard available > 0 else { return false }
        return draft.cryptoAmount > available / 2
    }

    /// The send as a percentage of the asset balance (for the whale-check
    /// copy: *"This send is 83% of your Tether balance."*).
    var sendPercentOfBalance: Int {
        let available = draft.availableBalance
        guard available > 0 else { return 0 }
        let fraction = (draft.cryptoAmount / available) as NSDecimalNumber
        return min(100, max(0, Int((fraction.doubleValue * 100).rounded())))
    }

    // MARK: - Lifecycle (seams: T-066 / T-069)

    /// The live transaction state (handoff Flow G — one screen, a state
    /// machine). DESIGN: walks signed → broadcasting → confirmed on a
    /// timer; the real `send()` drives it from broadcast events.
    var lifecycle: LifecycleState = .idle

    /// Confirmation progress (handoff G2 "4/12 CONFIRMS"). DESIGN: ticks
    /// up on a timer.
    var confirmations: Int = 0
    var requiredConfirmations: Int { SendV2MockData.requiredConfirmations(for: draft.network) }

    /// **SEAM (T-066).** Sign + broadcast + watch the transaction. Replace
    /// with the real signing (BiometricService gate already exists) +
    /// per-chain broadcast + the lifecycle watcher (receipt poll /
    /// signatureSubscribe / mempool poll per the handoff's "Watching
    /// rules" table). DESIGN: a scripted walk so the result screens are
    /// fully navigable.
    func send() async {
        sendFailureMessage = nil
        guard let asset = draft.asset, let chain = draft.network,
              let to = draft.resolvedAddress, !to.isEmpty else {
            sendFailureMessage = "Missing recipient or asset."
            lifecycle = .failed
            return
        }
        // REAL sign + broadcast + status poll for every supported chain,
        // dispatched by family through ChainSendRouter (all off-main —
        // Rule #28). No scripted fallback: a chain whose service isn't
        // wired yet throws `.unsupportedChain` and the UI says so honestly.
        let isNative: Bool = { if case .native = asset { return true } else { return false } }()
        let rawAmount = ChainAmount.rawInteger(from: draft.cryptoAmount, decimals: asset.decimals)
        let speed = ChainFeeOption.Speed(rawValue: selectedFeeTierId.rawValue) ?? .normal
        // Memo / destination-tag (XRPL, Stellar, Cosmos, TON) — the V2
        // handoff doesn't surface a memo field yet, so nil for now. The
        // router + services already accept it for when that field lands.
        // TODO: (T-070) capture an optional memo/destination-tag in the UI.
        let memo: String? = nil
        lifecycle = .broadcasting
        do {
            let signed = try await ChainSendRouter.performSend(
                chain: chain, toAddress: to, rawAmount: rawAmount,
                isNative: isNative, contract: asset.contract, decimals: asset.decimals,
                memo: memo, speed: speed,
                container: ApertureDatabase.shared.container
            )
            sentTxHash = signed.txHash
            lifecycle = .unconfirmed
            await pollStatus(chain: chain, txHash: signed.txHash)
        } catch let error as ChainSendError {
            sendFailureMessage = error.userMessage
            lifecycle = .failed
        } catch {
            sendFailureMessage = "Send failed."
            lifecycle = .failed
        }
    }

    /// Poll the receipt until confirmed/failed (Rule #28 — the RPC runs
    /// off-main inside `EVMSendService`; only the lifecycle update is here).
    private func pollStatus(chain: SupportedChain, txHash: String) async {
        lifecycle = .confirming
        confirmations = 0
        let target = requiredConfirmations
        for _ in 0..<60 {   // ~60 × 3s ≈ 3 min ceiling, then leave unconfirmed
            if lifecycle != .confirming { return }
            try? await Task.sleep(for: .seconds(3))
            let status = (try? await ChainSendRouter.status(chain: chain, txHash: txHash)) ?? .pending
            switch status {
            case .pending:
                if confirmations < max(1, target - 1) { confirmations += 1 }
            case .confirmed:
                confirmations = target
                lifecycle = .confirmed
                return
            case .failed(let reason):
                sendFailureMessage = reason
                lifecycle = .failed
                return
            }
        }
        if lifecycle == .confirming { lifecycle = .unconfirmed }
    }

    /// **SEAM (T-069).** Replace a pending tx with a higher fee (EVM
    /// same-nonce replacement, Bitcoin RBF bump). DESIGN: no-op marker.
    func speedUp(_ preset: SpeedUpPreset) {
        // `// TODO: (T-069)` real RBF / replacement broadcast.
        _ = preset
    }

    /// **SEAM (T-069).** Cancel a pending tx (EVM 0-value self-transfer at
    /// higher fee, Bitcoin RBF double-spend-to-self). DESIGN: no-op marker.
    func cancel() {
        // `// TODO: (T-069)` real cancel / replacement broadcast.
    }

    /// The real broadcast hash once the send lands; the sample hash is the
    /// design-preview / not-yet-sent fallback (T-066).
    var sentTxHash: String?
    /// Honest failure reason surfaced when `lifecycle == .failed` (Rule #16).
    var sendFailureMessage: String?
    var transactionHash: String { sentTxHash ?? SendMockData.sampleTransactionHash }
}

// MARK: - Recipient state

extension SendV2Model {
    /// The live recipient-resolution state.
    enum RecipientState: Equatable {
        case empty
        case resolving
        case resolved(ResolvedRecipient)
        case invalid
        case poisoned(PoisonMatch)

        /// Whether the flow can advance to Amount from this state.
        var canContinue: Bool {
            if case .resolved = self { return true }
            return false
        }

        var resolved: ResolvedRecipient? {
            if case let .resolved(r) = self { return r }
            return nil
        }

        var poison: PoisonMatch? {
            if case let .poisoned(p) = self { return p }
            return nil
        }
    }

    /// A successfully resolved recipient.
    struct ResolvedRecipient: Equatable, Hashable {
        let name: String?
        let address: String
        let network: SupportedChain
        let isFirstSend: Bool
        let ensVerified: Bool

        var display: String { name ?? SendDraft.shorten(address) }
    }

    /// A detected address-poisoning match (handoff A3).
    struct PoisonMatch: Equatable, Hashable {
        let savedName: String
        let savedAddress: String
        let pastedAddress: String
    }

    /// The paste-validation card outcome (handoff D1/D2).
    enum PasteValidation: Equatable {
        case valid(network: SupportedChain, inAddressBook: Bool)
        case wrongNetwork(suggested: SendV2MockData.CrossNetworkSuggestion)
        case invalid(network: SupportedChain)
    }
}

// MARK: - Fee tier

extension SendV2Model {
    /// One fee tier offered on the fee-speed sheet (E3).
    struct FeeTier: Identifiable, Equatable, Hashable {
        enum Speed: String, Hashable { case slow, normal, fast }
        let speed: Speed
        let title: LocalizedStringKey
        let etaSeconds: Int
        let feeNative: Decimal
        let feeFiat: Decimal
        var id: Speed { speed }

        static func == (lhs: FeeTier, rhs: FeeTier) -> Bool {
            lhs.speed == rhs.speed && lhs.feeNative == rhs.feeNative && lhs.feeFiat == rhs.feeFiat
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(speed); hasher.combine(feeNative); hasher.combine(feeFiat)
        }
    }
}

// MARK: - Balance change (simulation)

extension SendV2Model {
    /// One row in the "After this send" simulation card (handoff B2).
    struct BalanceChange: Identifiable, Equatable, Hashable {
        let assetName: String
        let symbol: String
        let delta: Decimal     // negative = leaves the wallet
        let decimals: Int
        let isFee: Bool
        var id: String { assetName + symbol }
    }
}

// MARK: - Lifecycle + speed-up

extension SendV2Model {
    /// The transaction lifecycle states (handoff Flow G).
    enum LifecycleState: Equatable {
        case idle
        case broadcasting
        case unconfirmed
        case confirming
        case confirmed
        case failed
        case dropped
    }

    /// A speed-up preset (handoff C3).
    enum SpeedUpPreset: String, Identifiable, Hashable, CaseIterable {
        case plus10, plus25, plus50
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .plus10: return "+10%"
            case .plus25: return "+25%"
            case .plus50: return "+50%"
            }
        }
        var eta: LocalizedStringKey {
            switch self {
            case .plus10: return "~3 min"
            case .plus25: return "~45 sec"
            case .plus50: return "Next block"
            }
        }
        var multiplier: Decimal {
            switch self {
            case .plus10: return Decimal(string: "1.10") ?? 1
            case .plus25: return Decimal(string: "1.25") ?? 1
            case .plus50: return Decimal(string: "1.50") ?? 1
            }
        }
    }
}
