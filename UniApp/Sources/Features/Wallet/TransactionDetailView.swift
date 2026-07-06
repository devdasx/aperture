import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The full, chain-aware transaction **receipt**.
///
/// **Two-stage paint (Rule #25 / #28).** The stored `TransactionRecord`
/// gives an instant first paint — the signed amount hero, direction, and
/// status badge — exactly as the prior version did. On appear the screen
/// asks `TransactionDetailService` for the live receipt off-main
/// (`.task(id:)`), then enriches the small set of user-facing rows every
/// chain shares: status, time, network fee, hash, and explorer link.
///
/// **Honesty (Rule #16 / #26).** Nothing is fabricated. While the fetch is
/// in flight the receipt rows show native redacted placeholders. If the
/// detail fetch returns `nil`, the stored summary and explorer link survive
/// without an error banner, so the user can always verify the tx on-chain.
/// Status colors are green/orange
/// only for real status; red is reserved for a genuinely failed tx, never
/// decoration.
///
/// **Composition (Rules #2/#3/#4/#7/#19).** A centered status hero (coin
/// mark → signed amount → fiat → status badge) ABOVE a native
/// inset-grouped `List` of grouped sections (Rule #3 — system List is the
/// on-system content pattern; content rows are opaque, B.3). Copy
/// affordances mirror the receive-row pattern (inline "Copied" tick +
/// `.uniHaptic(.success)`). The fiat line under the amount is resolved
/// off-main (Rule #28) and omitted honestly when no price is available
/// (Rule #16). Hashes are LTR-locked (Rule #11) and monospaced. SF Symbols
/// + Trust Wallet coin marks; every color is a `UniColors` role.
struct TransactionDetailView: View {
    let transactionId: UUID
    @StateObject private var transactionObservation = TransactionRecordObservation()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    /// The live, fetched detail. `nil` until the fetch lands (or if it
    /// fails — distinguished from "still loading" by `isLoading`).
    @State private var detail: TransactionDetail?
    /// `true` while the off-main fetch is in flight. Gates the inline
    /// loading line vs. the honest failure line.
    @State private var isLoading = false
    /// Drives the shared inline "Copied" confirmation + success haptic.
    /// One timestamp for the whole screen — every copy affordance writes it.
    @State private var lastCopiedAt: Date?

    /// The user's display currency — drives the hero's fiat conversion.
    @GRDBStorage(CurrencyPreference.storageKey)
    private var currencyCode: String = CurrencyPreference.defaultCode

    /// Settings -> Preferences toggle. On: transaction heroes prefer local
    /// currency with native amount underneath. Off: native amount only.
    @GRDBStorage(TransactionAmountDisplayPreference.storageKey)
    private var showAmountsInFiat: Bool = TransactionAmountDisplayPreference.defaultValue

    /// The fetched fiat value of this transaction's amount, resolved
    /// off-main (Rule #28) from the unit price × amount. `nil` until it
    /// lands — and stays `nil` honestly (Rule #16) when no price is
    /// available, so the hero falls back to the native amount rather than
    /// fabricating a local-currency value.
    @State private var fiatValue: Decimal?
    @State private var isRenderingShareImage = false
    @State private var screenshotShareItem: TransactionScreenshotShareItem?
    @State private var screenshotShareFailed = false

    private var matches: [TransactionRecord] {
        transactionObservation.transaction.map { [$0] } ?? []
    }

    var body: some View {
        Group {
            if let tx = matches.first {
                // The whole receipt is ONE scroll: the centered status hero
                // is folded in as the List's first (cleared) row, so it
                // scrolls away together with the detail sections — the screen
                // is a single native inset-grouped List (the Settings.app
                // register). The hero is opaque content; no glass on
                // long-form content (B.3).
                detailList(tx)
            } else {
                missing
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if matches.first != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let tx = matches.first {
                            shareTransactionScreenshot(tx)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityLabel(Text("Share screenshot"))
                    }
                    .tint(UniColors.Icon.accent)
                    .disabled(isRenderingShareImage)
                }
            }
        }
        .sheet(item: $screenshotShareItem) { item in
            TransactionScreenshotShareSheet(item: item)
        }
        .overlay {
            if isRenderingShareImage {
                shareRenderingOverlay
            }
        }
        .alert("Couldn't share the screenshot.", isPresented: $screenshotShareFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong preparing the image. Please try again.")
        }
        .task(id: transactionId) {
            transactionObservation.setTransactionId(transactionId)
        }
        // Off-main, re-runs once the narrow transaction observer has the
        // stored tx, then whenever that row changes.
        .task(id: transactionDetailLoadKey) {
            await loadDetail()
        }
        // Resolve the hero's fiat conversion off-main (Rule #28), re-running
        // when the tx or the display currency changes (Rule #25 — live).
        .task(id: fiatKey) {
            await loadFiat()
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    /// The native grouped-list register — hero plus the calm public receipt,
    /// scrolling under the nav bar. Content cards are opaque (B.3); the List
    /// itself owns the grouped background.
    private func detailList(_ tx: TransactionRecord) -> some View {
        List {
            heroSection(tx)
            commonSection(tx)
            transactionActionsSection(tx)
        }
        .listStyle(.insetGrouped)
        .frame(maxWidth: .infinity)
    }

    /// `true` while the off-main fetch is still in flight AND nothing has
    /// landed yet. Drives the inline `.redacted` skeletons — the structure
    /// is present from frame one, the placeholder shimmer is the loading
    /// affordance (no separate "Loading details…" banner, no pop-in).
    private var isSkeleton: Bool { detail == nil && isLoading }

    /// The centered status hero, folded into the List as its first row so it
    /// scrolls with the detail sections (one scroll surface). A cleared,
    /// separator-less, edge-to-edge row reads as a free-floating header —
    /// NOT a boxed grouped cell — keeping the exact centered padding it had
    /// when it sat above the List.
    private func heroSection(_ tx: TransactionRecord) -> some View {
        Section {
            hero(tx)
                .padding(.horizontal, UniSpacing.l)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: UniSpacing.l,
                    leading: 0,
                    bottom: UniSpacing.s,
                    trailing: 0
                ))
        }
    }

    // MARK: - Stage 1 — centered status hero (instant first paint)

    /// The centered hero: coin mark → direction eyebrow → primary amount →
    /// optional native subtitle → status badge. The primary amount follows
    /// Settings -> Preferences -> Amounts in local currency; if fiat is
    /// requested but unavailable, the native amount is shown honestly.
    private func hero(_ tx: TransactionRecord) -> some View {
        VStack(spacing: UniSpacing.xs) {
            // Show the coin mark only when the chain resolves — never a
            // misleading default mark for an unresolvable chain (Rule #16).
            if let chain = resolvedChain {
                CoinMark(
                    chain: chain,
                    tokenSymbol: tx.tokenSymbol,
                    contract: tx.tokenContract
                )
                .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
                .padding(.bottom, UniSpacing.xxs)
            }

            Text(directionLabel(tx))
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            Text(primaryAmountLine(tx))
                .font(UniTypography.heroBalance)
                .foregroundStyle(amountTint(tx))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .environment(\.layoutDirection, .leftToRight)

            if let subtitle = amountSubtitleLine(tx) {
                Text(verbatim: subtitle)
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .environment(\.layoutDirection, .leftToRight)
            }

            statusBadge(statusForDisplay(tx))
                .padding(.top, UniSpacing.xxs)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statusBadge(_ status: TransactionStatus?) -> some View {
        // Honesty: an unrecognized status never renders as a green
        // "Confirmed" — show the stored raw value on a neutral badge.
        switch status {
        case .pending:   UniBadge(text: "Pending", kind: .warning)
        case .confirmed: UniBadge(text: "Confirmed", kind: .success)
        case .failed:    UniBadge(text: "Canceled", kind: .error)
        case nil:
            UniBadge(text: LocalizedStringKey(matches.first?.statusRaw ?? "Unknown"), kind: .neutral)
        }
    }

    // MARK: - Common receipt section (every chain)

    private func commonSection(_ tx: TransactionRecord) -> some View {
        sectionCard(title: "Details") {
            // Status — prefer the live, authoritative status when fetched.
            let status = statusForDisplay(tx)
            keyValueRow(
                label: "Status",
                value: statusText(status),
                valueColor: statusValueColor(status)
            )

            // When — live blockTime if present, else the stored occurredAt.
            if let date = detail?.blockTime ?? Optional(tx.occurredAt) {
                divider
                keyValueRow(
                    label: "When",
                    value: date.formatted(date: .abbreviated, time: .standard)
                )
            }

            // Network fee: show the stored fee instantly when present;
            // otherwise hold the row's place with a redacted placeholder
            // until the live fee lands.
            if let feeText = feeDisplay(tx) {
                divider
                keyValueRow(label: "Network fee", value: feeText, monospaced: true)
            } else if isSkeleton {
                divider
                keyValueRow(label: "Network fee", value: skeletonFee, monospaced: true)
                    .redacted(reason: .placeholder)
            }

            divider
            copyableRow(
                label: "Hash",
                display: WalletFormatting.shortAddress(hashForDisplay(tx), prefix: 10, suffix: 8),
                full: hashForDisplay(tx),
                accessibilityName: "transaction hash"
            )

        }
    }

    @ViewBuilder
    private func transactionActionsSection(_ tx: TransactionRecord) -> some View {
        Section {
            if let url = detail?.explorerURL ?? explorerFallbackURL(tx) {
                Link(destination: url) {
                    Label("View on explorer", systemImage: "safari")
                }
            }
            Button {
                shareTransactionScreenshot(tx)
            } label: {
                Label("Share screenshot", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(isRenderingShareImage)
        }
    }

    /// Native progress overlay shown while the transaction screenshot renders.
    private var shareRenderingOverlay: some View {
        ZStack {
            UniColors.Background.primary.opacity(0.6).ignoresSafeArea()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(UniColors.Tint.accent)
        }
        .transition(.opacity)
    }

    // MARK: - Stage 3 — chain-specific sections

    /// The chain-specific sections. Once the fetch lands, the real payload
    /// renders. While it's in flight (`isSkeleton`), the FULL section
    /// scaffolding for the stored chain's family is rendered with
    /// `.redacted(reason: .placeholder)` — so the complete screen layout is
    /// present from frame one and the real values just replace the
    /// placeholders in one smooth pass (no two-phase reveal, no layout jump).
    @ViewBuilder
    private func payloadSections(_ tx: TransactionRecord) -> some View {
        switch detail?.payload {
        case .bitcoin(let btc):  bitcoinSections(btc)
        case .evm(let evm):      evmSections(evm)
        case .solana(let sol):   solanaSections(sol)
        case .generic(let rows): genericSection(rows)
        case nil:
            if isSkeleton {
                skeletonSections
            } else {
                EmptyView()
            }
        }
    }

    // MARK: Skeleton scaffolding (in-place placeholders while fetching)

    /// Picks which skeleton sections to show from the STORED chain's family
    /// (already resolved via `resolvedChain`), so the structure the user is
    /// about to see is present immediately. EVM → Transaction + Gas & fee;
    /// Bitcoin family → Transaction + Inputs + Outputs; Solana → Transaction
    /// + Balance changes; everything else (XRPL / TRON / TON / NEAR / Aptos /
    /// Cosmos / Polkadot / Stellar / Sui) → a single generic "On-chain
    /// detail" section. If the chain can't be resolved at all, the generic
    /// scaffold is the safe minimum.
    @ViewBuilder
    private var skeletonSections: some View {
        switch resolvedChain?.family {
        case .evm:
            skeletonSection(title: "Transaction", rowCount: 5)
            skeletonSection(title: "Gas & fee", rowCount: 5, monospaced: true)
        case .bitcoin:
            skeletonSection(title: "Transaction", rowCount: 5, monospaced: true)
            skeletonSection(title: "Inputs", rowCount: 2)
            skeletonSection(title: "Outputs", rowCount: 2)
        case .ed25519 where resolvedChain == .solana:
            skeletonSection(title: "Transaction", rowCount: 4, monospaced: true)
            skeletonSection(title: "Balance changes", rowCount: 2)
        default:
            skeletonSection(title: "On-chain detail", rowCount: 5)
        }
    }

    /// One redacted section: a real `sectionCard` with `rowCount`
    /// key/value rows of fixed-width dummy strings, blurred by the native
    /// `.redacted(reason: .placeholder)` so the shimmer reads as an honest
    /// placeholder — never a fabricated real value (Rule #16).
    private func skeletonSection(
        title: LocalizedStringKey,
        rowCount: Int,
        monospaced: Bool = false
    ) -> some View {
        sectionCard(title: title) {
            ForEach(0..<rowCount, id: \.self) { index in
                if index > 0 { divider }
                skeletonRow(monospaced: monospaced)
            }
        }
        .redacted(reason: .placeholder)
    }

    /// One redacted dummy row. BOTH label and value are `Text(verbatim:)` —
    /// these placeholders are shimmer-only (redacted, never visibly rendered
    /// and never localized), so they must NOT enter the string catalog
    /// (Rule #20). Mirrors `keyValueRow`'s native `LabeledContent` layout.
    private func skeletonRow(monospaced: Bool) -> some View {
        LabeledContent {
            keyValueText(
                monospaced ? skeletonMono : skeletonValue,
                monospaced: monospaced,
                valueColor: UniColors.Text.primary
            )
        } label: {
            Text(verbatim: skeletonLabel)
        }
    }

    // Fixed-width dummy strings — clearly placeholders under the native
    // redaction blur; never read as real chain data (Rule #16).
    private var skeletonLabel: String { "Placeholder" }
    private var skeletonValue: String { "Placeholder value" }
    private var skeletonMono: String { "0x00000000000000" }
    private var skeletonNumber: String { "000000" }
    private var skeletonFee: String { "0.00000000 —" }

    // MARK: Bitcoin

    @ViewBuilder
    private func bitcoinSections(_ btc: BitcoinTxDetail) -> some View {
        sectionCard(title: "Transaction") {
            keyValueRow(label: "Size", value: "\(btc.size) bytes")
            divider
            keyValueRow(label: "Virtual size", value: "\(btc.vsize) vB")
            divider
            keyValueRow(label: "Weight", value: "\(btc.weight) WU")
            divider
            keyValueRow(label: "Version", value: btc.version.formatted())
            divider
            keyValueRow(label: "Locktime", value: btc.locktime.formatted())
            if let feeRate = btc.feeRate {
                divider
                keyValueRow(
                    label: "Fee rate",
                    value: "\(WalletFormatting.native(feeRate, decimals: 2)) sat/vB",
                    monospaced: true
                )
            }
            if let feeSats = btc.feeSats {
                divider
                keyValueRow(label: "Fee", value: "\(feeSats.formatted()) sats", monospaced: true)
            }
        }

        bitcoinLegSection(
            title: "Inputs",
            countSuffix: btc.inputs.count,
            legs: btc.inputs,
            emptyNote: "No inputs reported."
        )

        bitcoinLegSection(
            title: "Outputs",
            countSuffix: btc.outputs.count,
            legs: btc.outputs,
            emptyNote: "No outputs reported."
        )

        if let hex = btc.hex, !hex.isEmpty {
            monoDisclosureSection(title: "Raw transaction", body: hex, copyName: "raw transaction hex")
        }
    }

    @ViewBuilder
    private func bitcoinLegSection(
        title: LocalizedStringKey,
        countSuffix: Int,
        legs: [BitcoinTxIO],
        emptyNote: LocalizedStringKey
    ) -> some View {
        sectionCard(title: title, trailing: countSuffix > 0 ? "\(countSuffix)" : nil) {
            if legs.isEmpty {
                UniFootnote(text: emptyNote, color: UniColors.Text.tertiary)
            } else {
                ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                    if index > 0 { divider }
                    bitcoinLegRow(leg)
                }
            }
        }
    }

    private func bitcoinLegRow(_ leg: BitcoinTxIO) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
                if leg.isCoinbase {
                    UniBody(text: "Coinbase (newly generated)", color: UniColors.Text.secondary)
                } else if let address = leg.address {
                    Button {
                        copy(address, name: "address")
                    } label: {
                        monoValue(address, truncate: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Copy address"))
                } else {
                    UniBody(text: "Non-standard script", color: UniColors.Text.secondary)
                }
                Spacer(minLength: UniSpacing.s)
                Text(verbatim: bitcoinValue(leg.value))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            if let scriptType = leg.scriptType, !scriptType.isEmpty {
                UniCaption(text: LocalizedStringKey(scriptType), color: UniColors.Text.tertiary)
            }
            if let outpoint = leg.outpoint {
                monoCaption(WalletFormatting.shortAddress(outpoint, prefix: 10, suffix: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: EVM

    @ViewBuilder
    private func evmSections(_ evm: EVMTxDetail) -> some View {
        sectionCard(title: "Transaction") {
            // A malformed tx can carry an empty `from`; treat empty as absent
            // and render "—" rather than a copyable blank (finding #15).
            if let from = nonEmpty(evm.from) {
                copyableRow(
                    label: "From",
                    display: WalletFormatting.shortAddress(from, prefix: 8, suffix: 6),
                    full: from,
                    accessibilityName: "sender address"
                )
            } else {
                keyValueRow(label: "From", value: "—")
            }
            divider
            if let to = evm.to {
                copyableRow(
                    label: "To",
                    display: WalletFormatting.shortAddress(to, prefix: 8, suffix: 6),
                    full: to,
                    accessibilityName: "recipient address"
                )
            } else if let created = evm.contractAddress {
                copyableRow(
                    label: "Contract created",
                    display: WalletFormatting.shortAddress(created, prefix: 8, suffix: 6),
                    full: created,
                    accessibilityName: "created contract address"
                )
            } else {
                keyValueRow(label: "To", value: "Contract creation")
            }
            divider
            keyValueRow(label: "Nonce", value: evm.nonce.formatted())
            divider
            keyValueRow(label: "Type", value: evmTypeLabel(evm.type))
            if let index = evm.transactionIndex {
                divider
                keyValueRow(label: "Position in block", value: index.formatted())
            }
        }

        sectionCard(title: "Gas & fee") {
            if let gasLimit = evm.gasLimit {
                keyValueRow(label: "Gas limit", value: gasUnits(gasLimit), monospaced: true)
            }
            if let gasUsed = evm.gasUsed {
                divider
                keyValueRow(label: "Gas used", value: gasUnits(gasUsed), monospaced: true)
            }
            if let cumulative = evm.cumulativeGasUsed {
                divider
                keyValueRow(label: "Cumulative gas used", value: gasUnits(cumulative), monospaced: true)
            }
            if let gasPrice = evm.gasPrice {
                divider
                keyValueRow(label: "Gas price", value: gweiString(gasPrice), monospaced: true)
            }
            if let effective = evm.effectiveGasPrice {
                divider
                keyValueRow(label: "Effective gas price", value: gweiString(effective), monospaced: true)
            }
            if let maxFee = evm.maxFeePerGas {
                divider
                keyValueRow(label: "Max fee", value: gweiString(maxFee), monospaced: true)
            }
            if let priority = evm.maxPriorityFeePerGas {
                divider
                keyValueRow(label: "Max priority fee", value: gweiString(priority), monospaced: true)
            }
            if let feeText = feeDisplay(matches.first) {
                divider
                keyValueRow(label: "Total fee", value: feeText, monospaced: true)
            }
        }

        if !evm.erc20Transfers.isEmpty {
            sectionCard(title: "Token transfers", trailing: "\(evm.erc20Transfers.count)") {
                ForEach(Array(evm.erc20Transfers.enumerated()), id: \.element.id) { index, transfer in
                    if index > 0 { divider }
                    erc20TransferRow(transfer)
                }
            }
        }

        if evm.input != "0x", !evm.input.isEmpty {
            monoDisclosureSection(title: "Input data", body: evm.input, copyName: "input data")
        }
    }

    private func erc20TransferRow(_ transfer: ERC20Transfer) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
                if let token = nonEmpty(transfer.token) {
                    Button {
                        copy(token, name: "token contract")
                    } label: {
                        monoValue(WalletFormatting.shortAddress(token, prefix: 8, suffix: 6), truncate: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Copy token contract"))
                } else {
                    // Empty/malformed contract — render "—" (finding #15).
                    monoValue("—", truncate: false)
                }
                Spacer(minLength: UniSpacing.s)
                Text(verbatim: erc20AmountText(transfer))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            HStack(spacing: UniSpacing.xxs) {
                monoCaption(WalletFormatting.shortAddress(transfer.from, prefix: 6, suffix: 4))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
                monoCaption(WalletFormatting.shortAddress(transfer.to, prefix: 6, suffix: 4))
            }
            // The "decimals not applied" caption ONLY shows for an unknown
            // contract whose raw base-units value we couldn't scale
            // (finding #5). A known token shows a real amount + symbol.
            if transfer.decimals == nil {
                UniCaption(
                    text: "Raw amount — token decimals not applied",
                    color: UniColors.Text.tertiary
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The transfer's display amount: a decimals-scaled value + symbol when
    /// the token is known (`USDC`, `DAI`, …), else the raw base-units value
    /// (paired with the "decimals not applied" caption). 100 USDC renders as
    /// "100 USDC", not "100,000,000" (finding #5).
    private func erc20AmountText(_ transfer: ERC20Transfer) -> String {
        if let decimals = transfer.decimals {
            // Scale the full-precision raw `Decimal` directly (no string
            // round-trip) so a uint256 value keeps its precision.
            let scaled = transfer.valueRaw / pow(Decimal(10), max(0, decimals))
            let amount = WalletFormatting.native(scaled, decimals: decimals, hidden: hideBalances)
            if let symbol = nonEmpty(transfer.symbol ?? "") {
                return "\(amount) \(symbol)"
            }
            return amount
        }
        return WalletFormatting.native(transfer.valueRaw, decimals: 0, hidden: hideBalances)
    }

    // MARK: Solana

    @ViewBuilder
    private func solanaSections(_ sol: SolanaTxDetail) -> some View {
        sectionCard(title: "Transaction") {
            keyValueRow(label: "Slot", value: sol.slot.formatted())
            divider
            keyValueRow(label: "Fee", value: "\(sol.feeLamports.formatted()) lamports", monospaced: true)
            if let cu = sol.computeUnitsConsumed {
                divider
                keyValueRow(label: "Compute units", value: cu.formatted(), monospaced: true)
            }
            if let blockhash = sol.recentBlockhash {
                divider
                copyableRow(
                    label: "Recent blockhash",
                    display: WalletFormatting.shortAddress(blockhash, prefix: 8, suffix: 6),
                    full: blockhash,
                    accessibilityName: "recent blockhash"
                )
            }
            if let err = sol.errString {
                divider
                keyValueRow(label: "Error", value: err, valueColor: UniColors.Feedback.Error.foreground)
            }
        }

        if !sol.netChanges.isEmpty {
            sectionCard(title: "Balance changes", trailing: "\(sol.netChanges.count)") {
                ForEach(Array(sol.netChanges.enumerated()), id: \.element.id) { index, change in
                    if index > 0 { divider }
                    solanaChangeRow(change)
                }
            }
        }

        if !sol.instructions.isEmpty {
            monoDisclosureSection(
                title: "Instructions",
                lines: sol.instructions,
                copyName: "instructions"
            )
        }

        if !sol.logMessages.isEmpty {
            monoDisclosureSection(
                title: "Program logs",
                lines: sol.logMessages,
                copyName: "program logs"
            )
        }
    }

    private func solanaChangeRow(_ change: SolanaBalanceChange) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
                Button {
                    copy(change.account, name: "account")
                } label: {
                    monoValue(WalletFormatting.shortAddress(change.account, prefix: 8, suffix: 6), truncate: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Copy account"))
                Spacer(minLength: UniSpacing.s)
                Text(verbatim: solanaChangeAmount(change))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(changeTint(change.amount))
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Generic (XRPL / TRON / TON / NEAR / Aptos / Cosmos / Polkadot / Stellar / Sui)

    @ViewBuilder
    private func genericSection(_ rows: [DetailField]) -> some View {
        if !rows.isEmpty {
            sectionCard(title: "On-chain detail") {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { divider }
                    genericRow(field)
                }
            }
        }
    }

    private func genericRow(_ field: DetailField) -> some View {
        LabeledContent {
            Button {
                copy(field.value, name: field.label.lowercased())
            } label: {
                Text(verbatim: genericDisplayValue(field.value))
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Copy \(field.label)"))
        } label: {
            Text(LocalizedStringKey(field.label))
        }
    }

    // MARK: - Reusable section / row primitives

    /// Native inset-grouped `List` section. Rows are emitted directly so
    /// iOS owns separators, insets, highlighting, and grouped section chrome.
    private func sectionCard<C: View>(
        title: LocalizedStringKey,
        trailing: String? = nil,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        Section {
            content()
        } header: {
            if let trailing {
                HStack {
                    Text(title)
                    Spacer(minLength: UniSpacing.s)
                    Text(verbatim: trailing)
                }
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var divider: some View { EmptyView() }

    /// A plain label → value row. `monospaced` for numeric / hashy values.
    private func keyValueRow(
        label: LocalizedStringKey,
        value: String,
        monospaced: Bool = false,
        valueColor: Color = UniColors.Text.primary
    ) -> some View {
        LabeledContent {
            keyValueText(value, monospaced: monospaced, valueColor: valueColor)
        } label: {
            Text(label)
        }
    }

    /// A label → truncated-mono-value row that copies the FULL value on
    /// tap, with the shared inline "Copied" tick + success haptic.
    private func copyableRow(
        label: LocalizedStringKey,
        display: String,
        full: String,
        accessibilityName: String
    ) -> some View {
        LabeledContent {
            Button {
                copy(full, name: accessibilityName)
            } label: {
                HStack(spacing: UniSpacing.xs) {
                    monoValue(display, truncate: false)
                    Image(systemName: "doc.on.doc")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Copy \(accessibilityName)"))
        } label: {
            Text(label)
        }
    }

    /// A monospaced value `Text`, LTR-locked. `truncate` middle-truncates
    /// for very long single-line values inside dense rows.
    private func monoValue(_ value: String, truncate: Bool) -> some View {
        Text(verbatim: value)
            .font(UniTypography.monoBody)
            .foregroundStyle(UniColors.Text.primary)
            .lineLimit(1)
            .truncationMode(truncate ? .middle : .tail)
            .environment(\.layoutDirection, .leftToRight)
    }

    /// A trailing value `Text` for `keyValueRow`. Monospaced values are
    /// LTR-locked (Rule #11 §C); plain prose follows ambient direction.
    @ViewBuilder
    private func keyValueText(_ value: String, monospaced: Bool, valueColor: Color) -> some View {
        let text = Text(verbatim: value)
            .font(monospaced ? UniTypography.monoBody : UniTypography.body)
            .foregroundStyle(valueColor)
            .multilineTextAlignment(.trailing)
            .lineLimit(4)
        if monospaced {
            text.environment(\.layoutDirection, .leftToRight)
        } else {
            text
        }
    }

    private func monoCaption(_ value: String) -> some View {
        Text(verbatim: value)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(UniColors.Text.tertiary)
            .lineLimit(1)
            .environment(\.layoutDirection, .leftToRight)
    }

    /// A collapsed disclosure that reveals a long monospaced block
    /// (raw hex / input data) inside a horizontally + vertically scrollable
    /// pane, with a copy button. Calm by default — the screen doesn't
    /// flood the user with a 2KB hex string unless they ask.
    private func monoDisclosureSection(
        title: LocalizedStringKey,
        body text: String,
        copyName: String
    ) -> some View {
        sectionCard(title: title) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: UniSpacing.s) {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(verbatim: text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(UniColors.Text.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .frame(maxHeight: 200)

                    copyBlockButton(text, name: copyName)
                }
                .padding(.top, UniSpacing.xs)
            } label: {
                disclosureLabel(byteCount: text.count, unit: "characters")
            }
            .tint(UniColors.Text.link)
        }
    }

    /// Same, for an array of lines (Solana instructions / logs). Each line
    /// gets its own row so the user can read the trace top-to-bottom.
    private func monoDisclosureSection(
        title: LocalizedStringKey,
        lines: [String],
        copyName: String
    ) -> some View {
        sectionCard(title: title, trailing: "\(lines.count)") {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: UniSpacing.s) {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: UniSpacing.xs) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(UniColors.Text.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                        }
                    }
                    .frame(maxHeight: 240)

                    copyBlockButton(lines.joined(separator: "\n"), name: copyName)
                }
                .padding(.top, UniSpacing.xs)
            } label: {
                disclosureLabel(byteCount: lines.count, unit: "lines")
            }
            .tint(UniColors.Text.link)
        }
    }

    private func disclosureLabel(byteCount: Int, unit: LocalizedStringKey) -> some View {
        HStack(spacing: UniSpacing.xs) {
            Text("Show")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Text(verbatim: "·")
                .foregroundStyle(UniColors.Text.tertiary)
            Text(verbatim: byteCount.formatted())
                .font(UniTypography.footnote.monospacedDigit())
                .foregroundStyle(UniColors.Text.tertiary)
            Text(unit)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }

    private func copyBlockButton(_ value: String, name: String) -> some View {
        Button {
            copy(value, name: name)
        } label: {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                Text("Copy")
                    .font(UniTypography.footnote)
            }
            .foregroundStyle(UniColors.Text.link)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copy \(name)"))
    }

    // MARK: - Missing state

    private var missing: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
            UniBody(
                text: "This transaction is no longer in the local store.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
        .frame(maxWidth: .infinity)
        .padding(UniSpacing.xl)
    }

    // MARK: - Fetch wiring (off-main, Rule #28)

    private func loadDetail() async {
        guard let tx = matches.first, let chain = resolvedChain else {
            isLoading = false
            return
        }
        isLoading = true

        // Stable lookup keys — captured once so the poll loop doesn't reach
        // back into the live record across suspension points.
        let txHash = tx.txHash
        let tokenContract = tx.tokenContract
        let address = tx.address?.address
        let counterparty = tx.counterparty

        var fetched = await TransactionDetailService.detail(
            chain: chain,
            txHash: txHash,
            tokenContract: tokenContract,
            address: address,
            counterparty: counterparty
        )
        guard !Task.isCancelled else { return }
        detail = fetched
        isLoading = false
        if let fetched, fetched.status != .pending {
            persistResolved(fetched)
            return
        }

        // Keep checking while the tx is still pending, so the badge flips to
        // Confirmed/Failed live (Rule #25) and the confirmation count ticks
        // up — then persist the terminal details so the activity list agrees.
        // Honest (Rule #16): a tx that never resolves within the window
        // simply stays "Pending"; nothing is fabricated.
        var attempt = 0
        while currentStatus(fetched, tx: tx) == .pending, attempt < 40 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(attempt == 0 ? 5 : 8))
            if Task.isCancelled { return }
            let refreshed = await TransactionDetailService.detail(
                chain: chain,
                txHash: txHash,
                tokenContract: tokenContract,
                address: address,
                counterparty: counterparty
            )
            guard !Task.isCancelled else { return }
            attempt += 1
            guard let refreshed else { continue }
            fetched = refreshed
            detail = refreshed
            if refreshed.status != .pending {
                persistResolved(refreshed)
                return
            }
        }
    }

    /// The effective status driving the poll loop — the fetched detail wins,
    /// falling back to the stored record's status.
    private func currentStatus(_ fetched: TransactionDetail?, tx: TransactionRecord) -> TransactionStatus? {
        fetched?.status ?? TransactionStatus(rawValue: tx.statusRaw)
    }

    /// Write resolved live fields back to the record so activity rows and
    /// future opens reflect confirmation, block, and fee updates.
    private func persistResolved(_ detail: TransactionDetail) {
        guard let tx = matches.first,
              let addressId = tx.addressId,
              let direction = TransactionDirection(rawValue: tx.directionRaw) else { return }
        if let feeNative = detail.feeNative {
            persistResolvedTransaction(
                tx,
                addressId: addressId,
                direction: direction,
                status: detail.status,
                blockNumber: detail.blockNumber,
                occurredAt: detail.blockTime ?? tx.occurredAt,
                feeRaw: feeNative.description
            )
        } else {
            persistResolvedTransaction(
                tx,
                addressId: addressId,
                direction: direction,
                status: detail.status,
                blockNumber: detail.blockNumber,
                occurredAt: detail.blockTime ?? tx.occurredAt,
                feeRaw: tx.feeRaw
            )
        }
    }

    private func persistResolvedTransaction(
        _ tx: TransactionRecord,
        addressId: UUID,
        direction: TransactionDirection,
        status: TransactionStatus,
        blockNumber: Int64?,
        occurredAt: Date,
        feeRaw: String?
    ) {
        Task { @MainActor in
            try? TransactionRepository(database: AppDatabase.shared).upsertTransaction(
                addressId: addressId,
                txHash: tx.txHash,
                direction: direction,
                amountRaw: tx.amountRaw,
                tokenSymbol: tx.tokenSymbol,
                tokenContract: tx.tokenContract,
                kind: tx.kindRaw.flatMap(TransactionKind.init(rawValue:)),
                blockNumber: blockNumber,
                occurredAt: occurredAt,
                status: status,
                counterparty: tx.counterparty,
                feeRaw: feeRaw,
                id: tx.id,
                save: true
            )
        }
    }

    // MARK: - Fiat conversion (off-main, Rule #28; honest, Rule #16)

    /// Re-fetch the fiat value when the tx, display currency, or amount
    /// preference changes (Rule #25 — live re-denomination). Empty when
    /// there's no tx yet.
    private var fiatKey: String {
        guard let tx = matches.first else { return "none" }
        return "\(tx.tokenSymbol)|\(tx.amountRaw)|\(currencyCode)|\(showAmountsInFiat)"
    }

    private var transactionDetailLoadKey: String {
        "\(transactionId.uuidString)|\(transactionObservation.revision)"
    }

    /// Resolve the transaction amount's fiat value through the shared
    /// pricing engine (unit price × amount), off the main thread. When the
    /// user chooses native transaction amounts, clears `fiatValue` so no local
    /// currency subtitle leaks through. When fiat display is enabled, leaves
    /// `fiatValue` nil if no price resolves, never fabricating one (Rule #16).
    private func loadFiat() async {
        guard showAmountsInFiat else {
            fiatValue = nil
            return
        }
        guard let tx = matches.first else {
            fiatValue = nil
            return
        }
        let amount = Decimal(string: tx.amountRaw) ?? .zero
        guard amount > 0 else {
            fiatValue = nil
            return
        }
        let symbol = tx.tokenSymbol.uppercased()
        let prices = await TokenPricingEngine.shared.unitPrices(
            symbols: [symbol], currencyCode: currencyCode.uppercased()
        )
        guard !Task.isCancelled else { return }
        if let unit = prices[symbol]?.amount, unit > 0 {
            fiatValue = amount * unit
        } else {
            fiatValue = nil
        }
    }

    // MARK: - Screenshot sharing

    @MainActor
    private func shareTransactionScreenshot(_ tx: TransactionRecord) {
        guard !isRenderingShareImage else { return }
        isRenderingShareImage = true
        defer { isRenderingShareImage = false }

        let direction = TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing
        let status = statusForDisplay(tx) ?? .pending
        let when = detail?.blockTime ?? tx.occurredAt
        let receipt = TransactionScreenshotReceipt(
            chain: resolvedChain,
            tokenSymbol: tx.tokenSymbol,
            tokenContract: tx.tokenContract,
            directionText: screenshotDirectionLabel(direction).uppercased(),
            primaryAmount: primaryAmountLine(tx),
            subtitleAmount: amountSubtitleLine(tx),
            statusText: statusText(status),
            status: status,
            whenText: Self.receiptDateTimeFormatter.string(from: when),
            networkFeeText: feeDisplay(tx),
            hashText: WalletFormatting.shortAddress(hashForDisplay(tx), prefix: 12, suffix: 10),
            appStoreText: ApertureWeb.appStoreDisplay
        )
        let renderer = ImageRenderer(
            content: TransactionScreenshotView(receipt: receipt)
        )
        renderer.scale = displayScale
        guard let image = renderer.uiImage else {
            screenshotShareFailed = true
            return
        }
        screenshotShareItem = TransactionScreenshotShareItem(
            image: image,
            appStoreURL: URL(string: ApertureWeb.appStore)
        )
    }

    private func screenshotDirectionLabel(_ direction: TransactionDirection) -> String {
        switch direction {
        case .incoming: return String(localized: "Received")
        case .outgoing: return String(localized: "Sent")
        case .internal: return String(localized: "Internal")
        }
    }

    // MARK: - Copy

    private func copy(_ value: String, name: String) {
        SafePasteboard.setItems(
            [[UTType.plainText.identifier: value]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        lastCopiedAt = Date()
        UniHapticEngine.shared.play(.success)
    }

    // MARK: - Derived values

    private var resolvedChain: SupportedChain? {
        detail?.chain
            ?? matches.first?.address.flatMap { SupportedChain(rawValue: $0.chainRaw) }
    }

    /// The block-vs-slot label per chain family (Solana / Sui report a
    /// slot / checkpoint, not a block).
    private var blockLabel: LocalizedStringKey {
        switch resolvedChain {
        case .solana: return "Slot"
        case .sui:    return "Checkpoint"
        default:      return "Block"
        }
    }

    /// Live status when fetched, else the stored status.
    private func statusForDisplay(_ tx: TransactionRecord) -> TransactionStatus? {
        detail?.status ?? TransactionStatus(rawValue: tx.statusRaw)
    }

    private func statusText(_ status: TransactionStatus?) -> String {
        switch status {
        case .pending:   return String.apertureLocalized("Pending")
        case .confirmed: return String.apertureLocalized("Confirmed")
        case .failed:    return String.apertureLocalized("Canceled")
        case nil:        return matches.first?.statusRaw ?? String.apertureLocalized("Unknown")
        }
    }

    private func statusValueColor(_ status: TransactionStatus?) -> Color {
        switch status {
        case .confirmed: return UniColors.Feedback.Success.foreground
        case .pending: return UniColors.Feedback.Warning.foreground
        case .failed: return UniColors.Feedback.Error.foreground
        case nil: return UniColors.Text.primary
        }
    }

    private func hashForDisplay(_ tx: TransactionRecord) -> String {
        detail?.hash ?? tx.txHash
    }

    private func explorerFallbackURL(_ tx: TransactionRecord) -> URL? {
        guard let chain = resolvedChain else { return nil }
        return TransactionExplorer.url(for: tx.txHash, chain: chain)
    }

    /// The native network fee, formatted with the chain ticker. Prefers
    /// the live `feeNative`; falls back to the stored raw fee string.
    private func feeDisplay(_ tx: TransactionRecord?) -> String? {
        if let fee = detail?.feeNative {
            let ticker = detail?.feeTicker ?? resolvedChain?.ticker ?? ""
            let decimals = resolvedChain?.nativeDecimals ?? 8
            return "\(WalletFormatting.native(fee, decimals: decimals, hidden: hideBalances)) \(ticker)"
        }
        if let raw = tx?.feeRaw, !raw.isEmpty {
            return raw
        }
        return nil
    }

    // MARK: - Formatting helpers

    private func bitcoinValue(_ sats: Int64) -> String {
        let coin = Decimal(sats) / pow(Decimal(10), 8)
        let ticker = resolvedChain?.ticker ?? "BTC"
        return "\(WalletFormatting.native(coin, decimals: 8, hidden: hideBalances)) \(ticker)"
    }

    private func gasUnits(_ value: Decimal) -> String {
        WalletFormatting.native(value, decimals: 0, hidden: hideBalances)
    }

    /// wei → gwei (÷1e9), capped to a readable precision. Gas prices are
    /// universally read in gwei.
    private func gweiString(_ wei: Decimal) -> String {
        let gwei = wei / pow(Decimal(10), 9)
        return "\(WalletFormatting.native(gwei, decimals: 4)) gwei"
    }

    private func evmTypeLabel(_ type: Int?) -> String {
        switch type {
        case 0:  return String.apertureLocalized("Legacy")
        case 1:  return "EIP-2930"
        case 2:  return "EIP-1559"
        case let value?: return "Type \(value)"
        case nil: return "—"
        }
    }

    private func solanaChangeAmount(_ change: SolanaBalanceChange) -> String {
        let sign = change.amount > 0 ? "+" : (change.amount < 0 ? "−" : "")
        let magnitude = change.amount < 0 ? -change.amount : change.amount
        return "\(sign)\(WalletFormatting.native(magnitude, decimals: 8, hidden: hideBalances)) \(change.symbol)"
    }

    /// Treat an empty/whitespace string as absent — the service can carry an
    /// empty `from` / token contract for a malformed tx, and the screen's
    /// convention is to render absent values as "—" (finding #15).
    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func genericDisplayValue(_ value: String) -> String {
        // Long opaque values (hashes / addresses) get middle-truncated so
        // a row stays one or two lines; short values render in full. The
        // full value is always copyable via the row's tap.
        guard value.count > 28, !value.contains(" ") else { return value }
        return WalletFormatting.shortAddress(value, prefix: 12, suffix: 8)
    }

    // MARK: - Tints (status colors only for real status; Rule #16)

    private func amountTint(_ tx: TransactionRecord) -> Color {
        switch TransactionDirection(rawValue: tx.directionRaw) {
        case .incoming?: return UniColors.Crypto.up
        case .outgoing?: return UniColors.Text.primary
        default:         return UniColors.Text.primary
        }
    }

    private func changeTint(_ amount: Decimal) -> Color {
        if amount > 0 { return UniColors.Crypto.up }
        if amount < 0 { return UniColors.Text.primary }
        return UniColors.Text.secondary
    }

    // MARK: - Stored-record labels (carried from v1)

    private func directionLabel(_ tx: TransactionRecord) -> String {
        switch TransactionDirection(rawValue: tx.directionRaw) {
        case .incoming?: return String.apertureLocalized("Received")
        case .outgoing?: return String.apertureLocalized("Sent")
        case .internal?: return String.apertureLocalized("Internal transfer")
        case nil:        return String.apertureLocalized("Transaction")
        }
    }

    private func primaryAmountLine(_ tx: TransactionRecord) -> String {
        if showAmountsInFiat, let fiatValue {
            return "\(amountSign(tx))\(WalletFormatting.fiat(fiatValue, currencyCode: currencyCode, hidden: hideBalances))"
        }
        return nativeAmountLine(tx)
    }

    private func amountSubtitleLine(_ tx: TransactionRecord) -> String? {
        guard showAmountsInFiat, fiatValue != nil else { return nil }
        return nativeAmountLine(tx)
    }

    private func nativeAmountLine(_ tx: TransactionRecord) -> String {
        let amount = Decimal(string: tx.amountRaw) ?? .zero
        let formatted = WalletFormatting.native(amount, decimals: 8, hidden: hideBalances)
        return "\(amountSign(tx))\(formatted) \(tx.tokenSymbol)"
    }

    private func amountSign(_ tx: TransactionRecord) -> String {
        switch TransactionDirection(rawValue: tx.directionRaw) {
        case .incoming?: return "+"
        case .outgoing?: return "−"
        default:         return ""
        }
    }

    private static let receiptDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy 'at' HH:mm:ss"
        return f
    }()
}

private struct TransactionScreenshotReceipt {
    let chain: SupportedChain?
    let tokenSymbol: String
    let tokenContract: String?
    let directionText: String
    let primaryAmount: String
    let subtitleAmount: String?
    let statusText: String
    let status: TransactionStatus
    let whenText: String
    let networkFeeText: String?
    let hashText: String
    let appStoreText: String
}

private struct TransactionScreenshotView: View {
    let receipt: TransactionScreenshotReceipt

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                if let chain = receipt.chain {
                    CoinMark(
                        chain: chain,
                        tokenSymbol: receipt.tokenSymbol,
                        contract: receipt.tokenContract
                    )
                    .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
                }

                Text(verbatim: receipt.directionText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(UniColors.Text.tertiary)

                Text(verbatim: receipt.primaryAmount)
                    .font(.system(size: 42, weight: .semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)

                if let subtitle = receipt.subtitleAmount {
                    Text(verbatim: subtitle)
                        .font(.system(size: 20, weight: .regular).monospacedDigit())
                        .foregroundStyle(UniColors.Text.secondary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .environment(\.layoutDirection, .leftToRight)
                }

                Text(verbatim: receipt.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(statusBackground))
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                screenshotRow("Status", value: receipt.statusText, valueColor: statusForeground)
                Divider()
                screenshotRow("When", value: receipt.whenText)
                if let fee = receipt.networkFeeText {
                    Divider()
                    screenshotRow("Network fee", value: fee, monospaced: true)
                }
                Divider()
                screenshotRow("Hash", value: receipt.hashText, monospaced: true)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(UniColors.Card.background)
            )

            VStack(spacing: 3) {
                Text("Shared with Aperture")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(UniColors.Text.secondary)
                Text(verbatim: "Download on the App Store • \(receipt.appStoreText)")
                    .font(.caption2)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(width: 390)
        .background(UniColors.Background.primary)
    }

    private func screenshotRow(
        _ label: LocalizedStringKey,
        value: String,
        monospaced: Bool = false,
        valueColor: Color = UniColors.Text.primary
    ) -> some View {
        LabeledContent {
            Text(verbatim: value)
                .font(monospaced ? .body.monospacedDigit() : .body)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .environment(\.layoutDirection, .leftToRight)
        } label: {
            Text(label)
                .foregroundStyle(UniColors.Text.secondary)
        }
        .padding(.vertical, 10)
    }

    private var statusForeground: Color {
        switch receipt.status {
        case .confirmed: return UniColors.Feedback.Success.foreground
        case .pending: return UniColors.Feedback.Warning.foreground
        case .failed: return UniColors.Feedback.Error.foreground
        }
    }

    private var statusBackground: Color {
        switch receipt.status {
        case .confirmed: return UniColors.Feedback.Success.background
        case .pending: return UniColors.Feedback.Warning.background
        case .failed: return UniColors.Feedback.Error.background
        }
    }
}

private struct TransactionScreenshotShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let appStoreURL: URL?
}

private struct TransactionScreenshotShareSheet: UIViewControllerRepresentable {
    let item: TransactionScreenshotShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [item.image]
        if let appStoreURL = item.appStoreURL {
            items.append(appStoreURL)
        }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
