import SwiftUI
import SwiftData

/// Browser-specific settings sheet — surfaced from
/// `BrowserHomeView`'s `gearshape` toolbar item. Two affordances:
/// clear browsing history, and manage active dApp sessions.
///
/// **Sheet shape (Rule #15).** `NavigationStack` wrapping a
/// grouped `List`. Native nav title via `.navigationTitle("Browser
/// settings")` on `.inline` for the `.large` detent.
///
/// **Honesty (Rule #16).** Each row names what it does in plain
/// terms — "Clear history" removes the on-device list of dApps
/// visited; "Disconnect" ends an active dApp session. No
/// promotional language; no surprise side-effects.
struct BrowserSettingsView: View {
    @Query private var history: [BrowserHistoryRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Live WalletConnect sessions. Today these come from
    /// `WalletConnectClient.shared.activeSessions` — when the SDK
    /// is wired, real entries appear and the list updates live.
    private var walletConnect: WalletConnectClient { WalletConnectClient.shared }

    @State private var isShowingClearConfirm: Bool = false

    var body: some View {
        NavigationStack {
            List {
                historySection
                connectedSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle("Browser settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Clear browsing history?",
                isPresented: $isShowingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear history", role: .destructive, action: clearHistory)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every dApp from the Recent section.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var historySection: some View {
        Section {
            HStack(spacing: UniSpacing.m) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    UniBody(text: "Browsing history")
                    UniFootnote(
                        text: history.isEmpty
                            ? "No history yet."
                            : "\(history.count) dApps in your recent list.",
                        color: UniColors.Text.secondary
                    )
                }

                Spacer()
            }
            .padding(.vertical, UniSpacing.xxs)
            .listRowBackground(UniColors.Background.secondary)

            Button {
                isShowingClearConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .foregroundStyle(UniColors.Status.errorForeground)
                        .frame(width: 28)
                    Text("Clear history")
                        .foregroundStyle(UniColors.Status.errorForeground)
                    Spacer()
                }
            }
            .disabled(history.isEmpty)
            .listRowBackground(UniColors.Background.secondary)
        } header: {
            UniCaption(
                text: "History",
                color: UniColors.Text.tertiary
            )
        } footer: {
            UniFootnote(
                text: "History lives on this iPhone only. Aperture has no server copy.",
                color: UniColors.Text.tertiary
            )
        }
    }

    @ViewBuilder
    private var connectedSection: some View {
        Section {
            if walletConnect.activeSessions.isEmpty {
                VStack(alignment: .leading, spacing: UniSpacing.xs) {
                    UniBody(
                        text: "No connected dApps",
                        color: UniColors.Text.primary
                    )
                    UniFootnote(
                        text: "Connect a dApp via WalletConnect or the in-app browser to see active sessions here.",
                        color: UniColors.Text.secondary
                    )
                }
                .padding(.vertical, UniSpacing.xs)
                .listRowBackground(UniColors.Background.secondary)
            } else {
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
            UniCaption(
                text: "Connected dApps",
                color: UniColors.Text.tertiary
            )
        }
    }

    // MARK: - Behaviors

    private func clearHistory() {
        for record in history {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }
}
