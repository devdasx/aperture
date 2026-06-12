import SwiftUI
import SwiftData

/// The Browser tab's start page — the user's entry into Aperture's
/// in-app dApp browser. Replaces `BrowserPlaceholderView`.
///
/// **Design intent (Rule #2 §D.1):** give the user one calm map of
/// the dApps they can reach — favorites first (where do you want
/// to go?), recents second (where have you been?), connected
/// third (what's currently using your wallet?) — with one search
/// field above it all that accepts whatever they type and routes
/// it intelligently.
///
/// **Layers (Rule #2 §B.3):**
///   - **Content** — opaque List (favorites grid card + recent
///     section + connected section + the dApp guide footnote). The
///     list scrolls under the floating chrome.
///   - **Functional** — the Liquid Glass URL field at the top
///     (one of two allowed glass surfaces in any region per Rule
///     #2 §B.3) + the system nav bar's toolbar items
///     (`qrcode.viewfinder` + `gearshape`).
///
/// **Sections** are rendered as `List` rows so they inherit iOS's
/// inset-grouped chrome — the same chrome Wallet uses. The
/// favorites grid sits inside its own Section as a single row
/// with the grid as content, so the inset-grouped card frames the
/// 4×2 tile arrangement.
///
/// **Empty states (Rule #2 §A.2 — designed, not deferred):**
///   - No recents → the section disappears; the user reads the
///     favorites grid as the only "where do I go" surface.
///   - No connected sessions → the section disappears; the
///     "Connect a dApp" hint lives inside the guide footnote.
///
/// **Search (Rule #14 carve-out).** The browser's smart URL field
/// is NOT `.searchable(text:)`. The system's `.searchable` is for
/// filtering visible content; this field is the user's primary
/// commit affordance — type a URL, tap Go, navigate. Apple's
/// Safari, Chrome, every browser ships a custom URL field for the
/// same reason. The custom field still honors Rule #11 (semantic
/// edges) and Rule #2 §B (Liquid Glass via system APIs).
///
/// **Honesty (Rule #16).** The Open-source anchor sits inline at
/// the bottom of the list as a tertiary UniButton. Aperture
/// browses dApps; we don't audit them. The guide footnote says so
/// plainly.
struct BrowserHomeView: View {
    // MARK: - Source of truth

    /// Recent visits — `@Query` for live reactivity. When the
    /// `BrowserSessionView` calls `recordVisit(...)`, this list
    /// rebuilds on the next body evaluation.
    @Query(sort: \BrowserHistoryRecord.lastVisitedAt, order: .reverse)
    private var history: [BrowserHistoryRecord]

    /// SwiftData context for swipe-to-delete + clear-history.
    @Environment(\.modelContext) private var modelContext

    /// The shared dApp router — supplies the `injectedSessions`
    /// stream for the Connected section AND owns the pending
    /// confirmation slot the sheets bind to. Held by reference;
    /// the router is `@Observable`, so reading `router.pendingRequest`
    /// inside `body` subscribes the view to changes through iOS 17+
    /// Observation tracking.
    private var router: DAppRequestRouter { DAppRequestRouter.shared }

    /// The shared WalletConnect client — its `activeSessions`
    /// drive the Connected section alongside the router's
    /// `injectedSessions`. (Today the client's session list is
    /// empty until the SDK is wired; the UI surface still renders
    /// honestly.) The view re-evaluates on the
    /// `pendingRequest` change above; sessions changes propagate
    /// via the parent's `.task` re-run path.
    private var walletConnect: WalletConnectClient { WalletConnectClient.shared }

    // MARK: - Local UI state

    /// The URL field's text. Bound to `BrowserSearchField`. Reset
    /// when the user navigates so the next visit starts fresh.
    @State private var searchText: String = ""

    /// The pushed `BrowserSessionView`'s URL. When non-nil the
    /// session view is on the navigation stack.
    @State private var sessionDestination: BrowserSessionDestination?

    /// Sheets owned by this view — the QR scanner and the browser
    /// settings page. The router's confirmation sheets are owned
    /// by the binding-to-router area below.
    @State private var isShowingQRScanner: Bool = false
    @State private var isShowingBrowserSettings: Bool = false

    /// Direction key for Rule #12 §G sheet rebuild on RTL flip.
    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode

    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    // MARK: - Body

    var body: some View {
        listSurface
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarItems }
            .navigationDestination(item: $sessionDestination) { destination in
                BrowserSessionView(
                    initialURL: destination.url,
                    router: router
                )
            }
            .sheet(isPresented: $isShowingQRScanner) {
                BrowserQRScanSheet(
                    onScan: { uri in
                        Task { await router.handleWalletConnectURI(uri) }
                        isShowingQRScanner = false
                    }
                )
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
            }
            .sheet(isPresented: $isShowingBrowserSettings) {
                BrowserSettingsView()
                    .id(sheetDirectionKey)
                    .uniAppEnvironment()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(UniColors.Background.primary)
            }
            // Bind the router's single pending-request slot to the
            // four confirmation sheets. Each case maps to one sheet.
            // The router's `pendingRequest` becomes non-nil when a
            // dApp call needs user input; the matching sheet
            // presents.
            .sheet(item: routerPendingBinding) { request in
                switch request {
                case .connect(let r):
                    DAppConnectSheet(request: r, router: router)
                        .id(sheetDirectionKey)
                        .uniAppEnvironment()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(UniColors.Background.primary)
                case .signMessage(let r):
                    DAppSignMessageSheet(request: r, router: router)
                        .id(sheetDirectionKey)
                        .uniAppEnvironment()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(UniColors.Background.primary)
                case .signTypedData(let r):
                    DAppSignTypedDataSheet(request: r, router: router)
                        .id(sheetDirectionKey)
                        .uniAppEnvironment()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(UniColors.Background.primary)
                case .sendTransaction(let r):
                    DAppSendTransactionSheet(request: r, router: router)
                        .id(sheetDirectionKey)
                        .uniAppEnvironment()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(UniColors.Background.primary)
                }
            }
            .task {
                await walletConnect.configureIfNeeded()
            }
    }

    // MARK: - List

    @ViewBuilder
    private var listSurface: some View {
        List {
            searchSection
            favoritesSection
            recentSection
            connectedSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
    }

    // MARK: - Sections

    /// The smart URL field. Rendered as one cleared row so the
    /// glass capsule floats free of the inset-grouped card chrome
    /// (Rule #2 §B.3 — chrome floats over content).
    @ViewBuilder
    private var searchSection: some View {
        Section {
            BrowserSearchField(text: $searchText, onSubmit: submitSearch)
                .padding(.horizontal, UniSpacing.xs)
                .padding(.vertical, UniSpacing.xs)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: UniSpacing.xs, leading: 0, bottom: UniSpacing.s, trailing: 0))
        }
    }

    /// The 4-column favorites grid. One List row holding the grid
    /// — iOS draws the inset-grouped card around it for free.
    @ViewBuilder
    private var favoritesSection: some View {
        Section {
            BrowserFavoritesGrid(
                favorites: BrowserFavorite.starterSet,
                onSelect: { favorite in
                    sessionDestination = BrowserSessionDestination(url: favorite.url)
                }
            )
            .padding(.vertical, UniSpacing.s)
            .listRowBackground(UniColors.Background.secondary)
            .listRowSeparator(.hidden)
        } header: {
            UniCaption(
                text: "Favorites",
                color: UniColors.Text.tertiary
            )
        }
    }

    /// History rows. Hidden when empty — the favorites grid is
    /// enough to start with.
    @ViewBuilder
    private var recentSection: some View {
        if !history.isEmpty {
            Section {
                ForEach(history) { record in
                    Button {
                        if let url = URL(string: record.url) {
                            sessionDestination = BrowserSessionDestination(url: url)
                        }
                    } label: {
                        BrowserHistoryRow(record: record)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            delete(record)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                UniCaption(
                    text: "Recent",
                    color: UniColors.Text.tertiary
                )
            }
        }
    }

    /// Active dApp sessions — both injected and WalletConnect.
    @ViewBuilder
    private var connectedSection: some View {
        if !connectedSessions.isEmpty {
            Section {
                ForEach(connectedSessions) { session in
                    Button {
                        if let url = URL(string: "https://\(session.dAppHost)") {
                            sessionDestination = BrowserSessionDestination(url: url)
                        }
                    } label: {
                        BrowserConnectedRow(session: session)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            disconnect(session)
                        } label: {
                            Label("Disconnect", systemImage: "xmark")
                        }
                    }
                }
            } header: {
                UniCaption(
                    text: "Connected",
                    color: UniColors.Text.tertiary
                )
            }
        }
    }

    /// Honesty footer: a single tertiary text button to the
    /// open-source anchor + one paragraph naming Aperture's
    /// boundary statement.
    @ViewBuilder
    private var footerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniFootnote(
                    text: "Aperture browses dApps; it doesn't audit them. Read every request before you sign.",
                    color: UniColors.Text.secondary
                )
            }
            .padding(.vertical, UniSpacing.xs)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingQRScanner = true
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .accessibilityLabel(Text("Scan WalletConnect QR"))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingBrowserSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel(Text("Browser settings"))
            }
        }
    }

    // MARK: - Behaviors

    /// Resolve the typed text and navigate.
    private func submitSearch() {
        let resolution = BrowserURLNormalizer.resolve(searchText)
        switch resolution {
        case .url(let url), .search(let url, _):
            sessionDestination = BrowserSessionDestination(url: url)
            searchText = ""
        case .empty:
            break
        }
    }

    /// Swipe-to-delete on a history row.
    private func delete(_ record: BrowserHistoryRecord) {
        modelContext.delete(record)
        try? modelContext.save()
    }

    /// Swipe-to-disconnect on a connected row.
    private func disconnect(_ session: BrowserSession) {
        Task {
            switch session.transport {
            case .walletConnect:
                await walletConnect.disconnect(sessionId: session.id)
            case .injected:
                // Injected sessions disconnect when the page goes
                // away. Surfacing a per-row disconnect requires
                // the router to revoke `connectedHosts`; the
                // bridge work adds the affordance.
                break
            }
        }
    }

    /// Merge the router's injected sessions + the WalletConnect
    /// client's active sessions into one sorted list. Stable id
    /// ordering — newest first.
    private var connectedSessions: [BrowserSession] {
        // Today: the router doesn't surface its injected sessions
        // through a public property (the bridge work adds them as
        // a real publisher). We project the WalletConnect client's
        // active sessions through the shared `BrowserSession`
        // shape; future expansion adds the injected ones here.
        let wc = walletConnect.activeSessions.map { session in
            BrowserSession(
                id: session.id,
                dAppName: session.name,
                dAppIcon: URL(string: session.iconURL ?? ""),
                dAppHost: URL(string: session.url)?.host ?? session.url,
                chain: session.chain,
                connectedAt: session.connectedAt,
                transport: .walletConnect
            )
        }
        return wc.sorted { $0.connectedAt > $1.connectedAt }
    }

    /// Bind the router's `pendingRequest` slot to a `.sheet(item:)`
    /// presentation. Reading `router.pendingRequest` directly in
    /// the modifier requires `Observation`-tracked observable
    /// access; we wrap it in a `Binding` so SwiftUI picks up the
    /// change.
    private var routerPendingBinding: Binding<DAppRequestRouter.PendingRequest?> {
        Binding(
            get: { router.pendingRequest },
            set: { newValue in
                if newValue == nil {
                    // Idempotent per request: rejects only if the
                    // presented request is still unresolved (user
                    // swipe-down); a no-op after an explicit
                    // approve / reject already resolved it. Either
                    // way the router presents the next queued
                    // request.
                    router.handleSheetDismissed()
                }
            }
        )
    }
}

// MARK: - Navigation destination

/// Wraps a URL in a Hashable identity so `.navigationDestination(item:)`
/// can drive it. A bare `URL?` would break the iOS 16+ `Hashable`
/// destination shape; this struct makes the intent explicit.
struct BrowserSessionDestination: Hashable, Identifiable {
    let id: UUID = UUID()
    let url: URL
}
