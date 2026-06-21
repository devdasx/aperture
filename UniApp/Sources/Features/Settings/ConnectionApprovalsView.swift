import SwiftUI
import SwiftData

/// Settings → Connected dApps. The union of persisted in-app-browser
/// connections (`ConnectedDAppRecord`) and live WalletConnect sessions
/// (`WalletConnectClient.shared.activeSessions`), each with a Disconnect
/// affordance. Mirrors `BrowserSettingsView`'s union + disconnect exactly (the
/// router drops the host from its live allow-set AND the persisted row is
/// deleted, so `eth_accounts` returns `[]` for the host until the user
/// re-connects).
///
/// **2026-06-21 — Token Approvals removed (user direction).** The on-chain
/// ERC-20 allowance scan + revoke went away with the rest of EVM data
/// fetching. This screen now manages dApp connections only — the dApp browser
/// and WalletConnect themselves are unchanged.
struct ConnectionApprovalsView: View {

    /// Persisted in-app-browser connections — newest first. Unioned with
    /// live WalletConnect sessions.
    @Query(sort: \ConnectedDAppRecord.connectedAt, order: .reverse)
    private var connectedDApps: [ConnectedDAppRecord]

    @Environment(\.modelContext) private var modelContext

    /// Router that owns the in-app-browser allow-set + persisted rows.
    private var router: DAppRequestRouter { DAppRequestRouter.shared }

    /// Live WalletConnect sessions (observable).
    private var walletConnect: WalletConnectClient { WalletConnectClient.shared }

    var body: some View {
        List {
            connectedSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Connected dApps"))
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Connected dApps (mirrors BrowserSettingsView)

    @ViewBuilder
    private var connectedSection: some View {
        Section {
            if connectedDApps.isEmpty && walletConnect.activeSessions.isEmpty {
                // Modern empty state — the app's canonical `UniEmptyState`
                // (soft elliptical lift + breathing watermark + two-line copy),
                // matching the Holdings / Activity empties. Clear row + zero
                // insets so it floats as one calm surface, not a boxed cell.
                UniEmptyState(
                    title: "No connected dApps",
                    detail: "Connect a dApp via WalletConnect or the in-app browser to see active sessions here.",
                    mark: .icon(systemName: "app.connected.to.app.below.fill")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
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

    // MARK: - Behaviors

    private func disconnectInApp(_ dApp: ConnectedDAppRecord) {
        let host = dApp.host
        modelContext.delete(dApp)
        try? modelContext.save()
        router.disconnect(host: host)
    }
}
