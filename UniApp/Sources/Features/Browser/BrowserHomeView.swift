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
/// **Search (2026-06-17 — native `.searchable`, user direction).** The
/// URL field is now the system `.searchable(text:)` bar connected to the
/// nav bar — identical to every other screen (Wallets, Currency, Receive,
/// etc.) so the browser doesn't feel bespoke. It still routes intelligently:
/// `.onSubmit(of: .search)` hands the text to `BrowserURLNormalizer`, which
/// decides URL vs. search query. (This supersedes the earlier custom
/// `BrowserSearchField` carve-out; the user asked for the native bar.)
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

    /// User-pinned favorites. The grid now shows ONLY these — there is no
    /// pre-curated starter set masquerading as the user's choices (2026-06-18
    /// user direction). Toggled by swiping a directory row.
    @Query(sort: \BrowserBookmarkRecord.sortOrder)
    private var bookmarks: [BrowserBookmarkRecord]

    /// Persisted in-app-browser connections — surfaced in the Connected
    /// section and used to offer swipe-to-disconnect on the directory.
    @Query(sort: \ConnectedDAppRecord.connectedAt, order: .reverse)
    private var connectedDApps: [ConnectedDAppRecord]

    /// SwiftData context for swipe-to-delete + clear-history + favoriting.
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

    /// The URL field's text. Bound to the nav-bar `.searchable`. Reset
    /// when the user navigates so the next visit starts fresh.
    @State private var searchText: String = ""

    /// The selected directory category chip (2026-06-17). `.all` shows the
    /// curated favorites + the full directory; a category filters to it.
    @State private var selectedCategory: BrowserDAppCategory = .all

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
            // Wire the dApp router's SwiftData context as soon as the browser
            // home appears — BEFORE the user can reach a connect sheet
            // (2026-06-18 fix). Previously this happened only in
            // BrowserSessionView.task, so a connection approved before that
            // view's task ran never persisted a ConnectedDAppRecord and the
            // Connected dApps list stayed empty. The setter is idempotent.
            .task { router.setModelContext(modelContext) }
            // Native iOS 26 search bar, connected to the nav bar (user
            // direction 2026-06-17) — identical to every other screen's
            // `.searchable`. It doubles as the smart URL field: the typed
            // text routes through `BrowserURLNormalizer` on submit (URL vs.
            // search query). Autocapitalization / autocorrection are off so
            // URLs aren't mangled, and `.webSearch` parsing happens on submit.
            .searchable(text: $searchText, prompt: Text("Search or enter address"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) { submitSearch() }
            .toolbar { toolbarItems }
            .navigationDestination(item: $sessionDestination) { destination in
                BrowserSessionView(
                    initialURL: destination.url,
                    router: router
                )
            }
            .fullScreenCover(isPresented: $isShowingQRScanner) {
                // The unified full-screen scanner auto-detects WalletConnect
                // (and addresses) — no per-caller `wc:` filter (2026-06-20).
                UniQRScannerSheet(
                    onConnect: { uri in
                        isShowingQRScanner = false
                        Task { await router.handleWalletConnectURI(uri) }
                    }
                )
                .id(sheetDirectionKey)
                .uniAppEnvironment()
            }
            .sheet(isPresented: $isShowingBrowserSettings) {
                BrowserSettingsView()
                    .id(sheetDirectionKey)
                    .uniAppEnvironment()
                    .uniSheetDetents([.large])
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
                        .uniSheetDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(UniColors.Background.primary)
                case .signMessage(let r):
                    DAppSignMessageSheet(request: r, router: router)
                        .id(sheetDirectionKey)
                        .uniAppEnvironment()
                        .uniSheetDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(UniColors.Background.primary)
                case .signTypedData(let r):
                    DAppSignTypedDataSheet(request: r, router: router)
                        .id(sheetDirectionKey)
                        .uniAppEnvironment()
                        .uniSheetDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(UniColors.Background.primary)
                case .sendTransaction(let r):
                    DAppSendTransactionSheet(request: r, router: router)
                        .id(sheetDirectionKey)
                        .uniAppEnvironment()
                        .uniSheetDetents([.large])
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
            chipsSection
            if selectedCategory == .all { favoritesSection }
            directorySection
            recentSection
            connectedSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
    }

    // MARK: - Sections

    /// Category chips — a cleared, full-bleed row so the horizontal
    /// scroller floats free of the inset-grouped chrome (2026-06-17).
    @ViewBuilder
    private var chipsSection: some View {
        Section {
            BrowserCategoryChips(selected: $selectedCategory)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    /// The dApp directory, filtered by the selected chip. On `.all` the
    /// eight curated favorites (shown in the grid above) are excluded so
    /// they don't appear twice. Tapping a row opens the dApp.
    @ViewBuilder
    private var directorySection: some View {
        let dapps = directoryDApps
        if !dapps.isEmpty {
            Section {
                ForEach(dapps) { dapp in
                    Button {
                        sessionDestination = BrowserSessionDestination(url: dapp.url)
                    } label: {
                        BrowserDAppRow(dapp: dapp)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            toggleFavorite(dapp)
                        } label: {
                            Label(
                                isFavorited(dapp.host) ? "Unfavorite" : "Favorite",
                                systemImage: isFavorited(dapp.host) ? "star.slash" : "star"
                            )
                        }
                        .tint(UniColors.Tint.accent)

                        if connectedHosts.contains(dapp.host) {
                            Button(role: .destructive) {
                                disconnectHost(dapp.host)
                            } label: {
                                Label("Disconnect", systemImage: "xmark")
                            }
                        }
                    }
                }
            } header: {
                UniCaption(
                    text: selectedCategory == .all ? "All dApps" : selectedCategory.label,
                    color: UniColors.Text.tertiary
                )
            }
        }
    }

    /// The directory rows for the current chip — favorites removed on `.all`.
    private var directoryDApps: [BrowserDApp] {
        let all = BrowserDApp.directory(for: selectedCategory)
        guard selectedCategory == .all else { return all }
        let favoriteHosts = Set(favoriteBookmarks.map { $0.host })
        return all.filter { !favoriteHosts.contains($0.host) }
    }

    /// The user's pinned favorites, in sort order. Empty until the user
    /// swipes a directory row to favorite it.
    private var favoriteBookmarks: [BrowserBookmarkRecord] {
        bookmarks.filter { $0.isFavorite }
    }

    /// `favoriteBookmarks` hydrated into the grid's `BrowserFavorite` shape.
    /// URLs are validated (no force-unwrap — these are user data), and a
    /// missing favicon falls back to the favicon service.
    private var favorites: [BrowserFavorite] {
        favoriteBookmarks.compactMap { record in
            guard let url = URL(string: record.url) else { return nil }
            let icon = record.iconURL.flatMap(URL.init(string:))
                ?? URL(string: "https://www.google.com/s2/favicons?domain=\(record.host)&sz=128")
            guard let iconURL = icon else { return nil }
            return BrowserFavorite(
                id: record.host,
                name: record.title.isEmpty ? record.host : record.title,
                url: url,
                host: record.host,
                iconURL: iconURL,
                category: .swap
            )
        }
    }

    /// The 4-column favorites grid. One List row holding the grid — iOS
    /// draws the inset-grouped card around it for free. Shown only when the
    /// user has actually pinned at least one dApp (2026-06-18 — no
    /// pre-curated set shown as if the user chose it).
    @ViewBuilder
    private var favoritesSection: some View {
        if !favorites.isEmpty {
            Section {
                BrowserFavoritesGrid(
                    favorites: favorites,
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

    /// Hosts the wallet is currently connected to (in-app injected +
    /// WalletConnect) — drives the directory's swipe-to-disconnect.
    private var connectedHosts: Set<String> {
        var set = Set(connectedDApps.map { $0.host })
        set.formUnion(walletConnect.activeSessions.compactMap { URL(string: $0.url)?.host })
        return set
    }

    /// Whether the user has pinned this host as a favorite.
    private func isFavorited(_ host: String) -> Bool {
        bookmarks.contains { $0.host == host && $0.isFavorite }
    }

    /// Toggle a directory dApp's favorite state — flips an existing
    /// bookmark row or inserts a new one (favoriting appends to the end of
    /// the user's order).
    private func toggleFavorite(_ dapp: BrowserDApp) {
        if let existing = bookmarks.first(where: { $0.host == dapp.host }) {
            existing.isFavorite.toggle()
        } else {
            let nextOrder = (bookmarks.map { $0.sortOrder }.max() ?? -1) + 1
            modelContext.insert(BrowserBookmarkRecord(
                url: dapp.url.absoluteString,
                title: dapp.name,
                host: dapp.host,
                iconURL: "https://www.google.com/s2/favicons?domain=\(dapp.host)&sz=128",
                sortOrder: nextOrder,
                isFavorite: true
            ))
        }
        try? modelContext.save()
    }

    /// Disconnect an in-app (injected) connection from the directory swipe.
    /// Routes through the shared router, which revokes the host AND deletes
    /// its `ConnectedDAppRecord`; the `@Query` above then drops the row.
    private func disconnectHost(_ host: String) {
        router.disconnect(host: host)
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
