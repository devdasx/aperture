import SwiftUI
import SwiftData

/// Settings → Connection & Approvals. Two sections:
///
/// 1. **Connected dApps** — the union of persisted in-app-browser
///    connections (`ConnectedDAppRecord`) and live WalletConnect
///    sessions (`WalletConnectClient.shared.activeSessions`), each with a
///    Disconnect affordance. Mirrors `BrowserSettingsView`'s union +
///    disconnect exactly (the router drops the host from its live
///    allow-set AND the persisted row is deleted, so `eth_accounts`
///    returns `[]` for the host until the user re-connects).
///
/// 2. **Token approvals (REAL, on-chain)** — scans the active wallet's
///    ERC-20 approvals across the EVM chains it holds addresses for
///    (`ApprovalScanner`, on-demand into value types — no persistence),
///    lists each non-zero allowance (token symbol + spender address +
///    allowance, "Unlimited" at the uint256 max), and lets the user
///    REVOKE one by signing + broadcasting an `approve(spender, 0)` tx
///    (`ApprovalRevocationService`), gated behind a biometric check.
///
/// **Honesty (Rule #16).** A failed scan shows an honest error/empty
/// state, never a misleading blank "no approvals". Spenders are shown as
/// their addresses; an unknown token shows its short contract — nothing
/// is fabricated. A revoke shows the REAL tx hash on success and the
/// node's honest reason on failure.
///
/// **Custody.** Revocation is offered only for mnemonic-backed wallets
/// (`.created` / `.importedMnemonic`, no BIP-39 passphrase) — the same
/// guard `EVMDAppSigner` / `ApprovalRevocationService` enforce. For other
/// wallet kinds the Revoke control is disabled with an honest caption.
struct ConnectionApprovalsView: View {

    /// Persisted in-app-browser connections — newest first. Unioned with
    /// live WalletConnect sessions in the Connected dApps section.
    @Query(sort: \ConnectedDAppRecord.connectedAt, order: .reverse)
    private var connectedDApps: [ConnectedDAppRecord]

    @Environment(\.modelContext) private var modelContext

    /// Router that owns the in-app-browser allow-set + persisted rows.
    private var router: DAppRequestRouter { DAppRequestRouter.shared }

    /// Live WalletConnect sessions (observable).
    private var walletConnect: WalletConnectClient { WalletConnectClient.shared }

    // Approval scan state.
    @State private var scanState: ApprovalScanState = .idle
    /// Per-approval revoke state, keyed by `TokenApproval.id`.
    @State private var revokeStates: [String: RevocationState] = [:]

    var body: some View {
        List {
            connectedSection
            approvalsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Connection & Approvals"))
        .navigationBarTitleDisplayMode(.large)
        .task { await runScan() }
    }

    // MARK: - Connected dApps (mirrors BrowserSettingsView)

    @ViewBuilder
    private var connectedSection: some View {
        Section {
            if connectedDApps.isEmpty && walletConnect.activeSessions.isEmpty {
                VStack(alignment: .leading, spacing: UniSpacing.xs) {
                    UniBody(text: "No connected dApps", color: UniColors.Text.primary)
                    UniFootnote(
                        text: "Connect a dApp via WalletConnect or the in-app browser to see active sessions here.",
                        color: UniColors.Text.secondary
                    )
                }
                .padding(.vertical, UniSpacing.xs)
                .listRowBackground(UniColors.Background.secondary)
            } else {
                // In-app-browser connections (persisted).
                ForEach(connectedDApps) { dApp in
                    HStack(spacing: UniSpacing.m) {
                        BrowserFaviconView(
                            url: dApp.iconURL.flatMap(URL.init(string:)),
                            fallbackLetter: dApp.name,
                            size: .row
                        )
                        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                            Text(verbatim: dApp.name)
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Text.primary)
                            Text(verbatim: dApp.host)
                                .font(UniTypography.footnote)
                                .foregroundStyle(UniColors.Text.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(UniColors.Background.secondary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            disconnectInApp(dApp)
                        } label: {
                            Label("Disconnect", systemImage: "xmark")
                        }
                    }
                }

                // Live WalletConnect sessions.
                ForEach(walletConnect.activeSessions) { session in
                    HStack(spacing: UniSpacing.m) {
                        BrowserFaviconView(
                            url: URL(string: session.iconURL ?? ""),
                            fallbackLetter: session.name,
                            size: .row
                        )
                        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                            Text(verbatim: session.name)
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Text.primary)
                            Text(verbatim: URL(string: session.url)?.host ?? session.url)
                                .font(UniTypography.footnote)
                                .foregroundStyle(UniColors.Text.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(UniColors.Background.secondary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await walletConnect.disconnect(sessionId: session.id) }
                        } label: {
                            Label("Disconnect", systemImage: "xmark")
                        }
                    }
                }
            }
        } header: {
            UniCaption(text: "Connected dApps", color: UniColors.Text.tertiary)
        } footer: {
            UniFootnote(
                text: "Disconnecting revokes a dApp's account access. It can't read your address again until you re-connect.",
                color: UniColors.Text.tertiary
            )
        }
    }

    // MARK: - Token approvals

    @ViewBuilder
    private var approvalsSection: some View {
        Section {
            switch scanState {
            case .idle, .scanning:
                HStack(spacing: UniSpacing.s) {
                    ProgressView()
                    UniFootnote(text: "Scanning your approvals on-chain…", color: UniColors.Text.secondary)
                }
                .padding(.vertical, UniSpacing.xs)
                .listRowBackground(UniColors.Background.secondary)

            case .failed(let reason):
                VStack(alignment: .leading, spacing: UniSpacing.xs) {
                    HStack(alignment: .top, spacing: UniSpacing.s) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(UniColors.Status.warningForeground)
                            .frame(width: 20)
                        Text(verbatim: reason)
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Try again") { Task { await runScan() } }
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.link)
                }
                .padding(.vertical, UniSpacing.xs)
                .listRowBackground(UniColors.Background.secondary)

            case .loaded(let approvals):
                if approvals.isEmpty {
                    VStack(alignment: .leading, spacing: UniSpacing.xs) {
                        UniBody(text: "No token approvals", color: UniColors.Text.primary)
                        UniFootnote(
                            text: "This wallet has no active ERC-20 approvals on the scanned EVM chains.",
                            color: UniColors.Text.secondary
                        )
                    }
                    .padding(.vertical, UniSpacing.xs)
                    .listRowBackground(UniColors.Background.secondary)
                } else {
                    ForEach(approvals) { approval in
                        approvalRow(approval)
                            .listRowBackground(UniColors.Background.secondary)
                    }
                }
            }
        } header: {
            UniCaption(text: "Token approvals", color: UniColors.Text.tertiary)
        } footer: {
            UniFootnote(
                text: "Approvals let a contract move your tokens. Revoking signs and broadcasts an on-chain approve(spender, 0) — a network fee applies. Read live from the chain; nothing is stored.",
                color: UniColors.Text.tertiary
            )
        }
    }

    @ViewBuilder
    private func approvalRow(_ approval: TokenApproval) -> some View {
        let state = revokeStates[approval.id] ?? .idle
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: approval.tokenSymbol)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                Text(verbatim: approval.chain.displayName)
                    .font(UniTypography.caption2)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            // Spender — honest, checksummed/short address (never a label).
            HStack(spacing: UniSpacing.xxs) {
                Text("Spender")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                Text(verbatim: WalletFormatting.shortAddress(approval.spender))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(UniColors.Text.secondary)
                    .textSelection(.enabled)
            }

            // Allowance.
            HStack(spacing: UniSpacing.xxs) {
                Text("Allowance")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                Text(verbatim: allowanceDisplay(approval))
                    .font(UniTypography.caption1)
                    .foregroundStyle(approval.isUnlimited ? UniColors.Status.warningForeground : UniColors.Text.secondary)
            }

            revokeControl(approval, state: state)
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    @ViewBuilder
    private func revokeControl(_ approval: TokenApproval, state: RevocationState) -> some View {
        switch state {
        case .idle:
            if canRevoke {
                Button(role: .destructive) {
                    revoke(approval)
                } label: {
                    Text("Revoke")
                        .font(UniTypography.footnote.weight(.semibold))
                        .foregroundStyle(UniColors.Status.errorForeground)
                }
                .buttonStyle(.plain)
                .padding(.top, UniSpacing.xxs)
            } else {
                UniFootnote(
                    text: "This wallet can't revoke — it's watch-only or a single-key import.",
                    color: UniColors.Text.tertiary
                )
            }

        case .revoking:
            HStack(spacing: UniSpacing.s) {
                ProgressView()
                UniFootnote(text: "Revoking…", color: UniColors.Text.secondary)
            }
            .padding(.top, UniSpacing.xxs)

        case .revoked(let txHash):
            HStack(alignment: .top, spacing: UniSpacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(UniColors.Status.successForeground)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    UniFootnote(text: "Revoke sent", color: UniColors.Text.secondary)
                    Text(verbatim: WalletFormatting.shortAddress(txHash, prefix: 10, suffix: 8))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(UniColors.Text.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, UniSpacing.xxs)

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: UniSpacing.xxs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(UniColors.Status.errorForeground)
                        .frame(width: 18)
                    Text(verbatim: reason)
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try again") { revoke(approval) }
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.link)
            }
            .padding(.top, UniSpacing.xxs)
        }
    }

    // MARK: - Behaviors

    private func disconnectInApp(_ dApp: ConnectedDAppRecord) {
        let host = dApp.host
        modelContext.delete(dApp)
        try? modelContext.save()
        router.disconnect(host: host)
    }

    /// Scan the active wallet's EVM chains for non-zero ERC-20 approvals.
    /// Resolves the wallet + its per-chain EVM addresses on the main actor
    /// (SwiftData), then hands value types to the off-main scanner.
    private func runScan() async {
        scanState = .scanning
        guard let resolved = ActiveWalletResolver.resolve() else {
            scanState = .failed(reason: "No wallet is selected to scan.")
            return
        }
        guard !resolved.evmAddresses.isEmpty else {
            scanState = .loaded([])
            return
        }
        let approvals = await ApprovalScanner.scan(
            walletAddresses: resolved.evmAddresses,
            chains: Array(resolved.evmAddresses.keys)
        )
        if Task.isCancelled { return }
        scanState = .loaded(approvals)
    }

    /// Authenticate (biometric when available — this moves an on-chain
    /// tx), then sign + broadcast `approve(spender, 0)`. Mirrors
    /// `DAppSendTransactionSheet.confirmAndSend`'s gating pattern.
    private func revoke(_ approval: TokenApproval) {
        guard revokeStates[approval.id] != .revoking else { return }
        revokeStates[approval.id] = .revoking
        Task { @MainActor in
            guard let resolved = ActiveWalletResolver.resolve(),
                  let owner = resolved.evmAddresses[approval.chain] else {
                revokeStates[approval.id] = .failed(reason: "No wallet is selected to sign this revoke.")
                return
            }

            let biometrics = BiometricService()
            if biometrics.isAvailable {
                let outcome = await biometrics.authenticate(reason: "Confirm revoking this approval")
                if case .failure = outcome {
                    revokeStates[approval.id] = .failed(
                        reason: String.apertureLocalized("Authentication failed — the revoke wasn’t sent.")
                    )
                    return
                }
            }

            switch await ApprovalRevocationService.revoke(
                approval: approval, wallet: resolved.descriptor, ownerAddress: owner
            ) {
            case .success(let txHash):
                revokeStates[approval.id] = .revoked(txHash: txHash)
            case .failure(let error):
                revokeStates[approval.id] = .failed(reason: error.userMessage)
            }
        }
    }

    // MARK: - Derived

    /// Whether the active wallet can sign a revoke (mnemonic-backed, no
    /// passphrase). Read once for the rows; resolved on the main actor.
    private var canRevoke: Bool {
        guard let resolved = ActiveWalletResolver.resolve() else { return false }
        switch resolved.descriptor.kind {
        case .created, .importedMnemonic: return !resolved.descriptor.hasPassphrase
        case .importedKey, .watchOnly:    return false
        }
    }

    /// Human-readable allowance: "Unlimited" at the uint256 max, otherwise
    /// the decimal allowance scaled by the token's decimals (best-effort —
    /// the raw word is authoritative and shown by the spender row's
    /// selection). Never fabricated.
    private func allowanceDisplay(_ approval: TokenApproval) -> String {
        if approval.isUnlimited { return "Unlimited" }
        guard let raw = EthereumConnector.decimalFromHex(approval.allowanceRaw) else {
            return approval.allowanceRaw
        }
        var scale = Decimal(1)
        for _ in 0..<min(max(approval.decimals, 0), 38) { scale *= 10 }
        let amount = raw / scale
        return "\(WalletFormatting.native(amount, decimals: min(approval.decimals, 8))) \(approval.tokenSymbol)"
    }
}

// MARK: - ActiveWalletResolver

/// Resolves the active wallet into the `Sendable` value types the
/// scanner + revocation service need — a `WalletDescriptor` (custody
/// snapshot) and a per-EVM-chain owner-address map. EVM addresses are
/// shared across EVM chains (one secp256k1 key → one address), so the
/// wallet's single EVM address is mapped to every EVM chain it has a row
/// for. Resolved on the main actor (SwiftData / `@Model` is main-actor-
/// bound); the returned struct is `Sendable`. Mirrors the targeted active-
/// wallet fetch in `EVMDAppSigner.activeWallet()` /
/// `ActiveWalletReader.activeWallet()`.
@MainActor
enum ActiveWalletResolver {

    struct Resolved: Sendable {
        let descriptor: WalletDescriptor
        /// chain → owner address, EVM chains only.
        let evmAddresses: [SupportedChain: String]
    }

    static func resolve() -> Resolved? {
        let activeId = UserDefaults.standard.string(forKey: "activeWalletId") ?? ""
        let context = ModelContext(ApertureDatabase.shared.container)

        var record: WalletRecord?
        if let activeUUID = UUID(uuidString: activeId) {
            var descriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == activeUUID }
            )
            descriptor.fetchLimit = 1
            record = (try? context.fetch(descriptor))?.first
        }
        if record == nil {
            var fallback = FetchDescriptor<WalletRecord>()
            fallback.fetchLimit = 1
            record = (try? context.fetch(fallback))?.first
        }
        guard let record else { return nil }

        var evmAddresses: [SupportedChain: String] = [:]
        for addressRow in record.addresses {
            guard let chain = SupportedChain(rawValue: addressRow.chainRaw),
                  chain.family == .evm, !addressRow.address.isEmpty else { continue }
            evmAddresses[chain] = addressRow.address
        }
        return Resolved(descriptor: WalletDescriptor(record: record), evmAddresses: evmAddresses)
    }
}
