import SwiftUI
import SwiftData

/// The active browsing surface — pushed onto `BrowserHomeView`'s
/// `NavigationStack` whenever the user submits a URL or taps a
/// favorite / recent row.
///
/// **Design intent (Rule #2 §D.1):** keep the user focused on the
/// dApp they're using by making every chrome element calm and
/// reachable with the thumb — URL bar at the top so they know
/// where they are, four bottom controls (back, forward, share,
/// close) so they can move, leave, or commit. The webview between
/// them is opaque content; the chrome is Liquid Glass.
///
/// **Layers (Rule #2 §B.3):**
///   - **Content** — the `WKWebView` wrapped by `BrowserWebView`.
///     Opaque. The dApp owns this surface.
///   - **Functional** — top URL bar (`Capsule`-shaped glass) +
///     bottom chrome (`GlassEffectContainer` holding 4 icon
///     buttons). Two glass regions, never overlapping. The
///     webview scrolls under both per Rule #2 §B.3's
///     content-scrolls-under-chrome rule.
///
/// **Loading indicator.** A thin tinted line under the URL bar.
/// Hidden when not loading; tinted accent and animated when
/// loading. Reads as honest "the page is still arriving" without
/// the heavy iOS UIRefreshControl.
///
/// **Honesty (Rule #16).** The URL bar carries `lock.fill` for
/// HTTPS and `lock.open` for HTTP. We don't paint a green "Secure"
/// bezel — HTTPS is the floor, not a feature. An HTTP page reads
/// as `lock.open` in the secondary text color so the user notices
/// without alarm.
struct BrowserSessionView: View {
    let initialURL: URL
    let router: DAppRequestRouter

    // MARK: - Webview state

    /// Live URL the webview reports. Bound to `BrowserWebView`.
    @State private var liveURL: URL?

    /// Live progress 0…1. Drives the slim progress strip.
    @State private var progress: Double = 0

    /// Whether the page is currently loading.
    @State private var isLoading: Bool = false

    /// Page `<title>`.
    @State private var pageTitle: String = ""

    /// Drives the back chevron's disabled state.
    @State private var canGoBack: Bool = false

    /// Drives the forward chevron's disabled state.
    @State private var canGoForward: Bool = false

    // MARK: - UI state

    /// Inline URL-edit sheet — opens when the user taps the URL
    /// bar to type a new destination without leaving the page.
    @State private var isEditingURL: Bool = false

    /// Direction key for Rule #12 §G sheet rebuild on RTL flip.
    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode

    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    /// Binding to the router's `pendingRequest` slot. Reading
    /// `router.pendingRequest` directly in `.sheet(item:)` would fail
    /// to dismiss when the user swipes down — `.sheet(item:)` sets
    /// the binding to `nil` on dismiss, but the router owns the
    /// state. We intercept the `nil` write and route it through
    /// `router.handleSheetDismissed()` so a swiped-down request
    /// resolves with `userRejected` and the next queued request
    /// gets presented.
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

    /// Imperative actions on the webview (back / forward / reload /
    /// stop). Owned here and handed into `BrowserWebView` so it can
    /// expose its `WKWebView` to the chrome buttons.
    @StateObject private var actions = BrowserActions()

    /// Last URL written to history — guards against double-counting
    /// a visit when the title KVO and the URL KVO fire for the same
    /// page load.
    @State private var lastRecordedURL: String?

    /// SwiftData context for recording visits to history.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss back to home.
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        ZStack {
            UniColors.Background.primary
                .ignoresSafeArea()

            BrowserWebView(
                url: webViewURLBinding,
                progress: $progress,
                isLoading: $isLoading,
                title: $pageTitle,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                router: router,
                actions: actions
            )
            .ignoresSafeArea(edges: .bottom)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topChrome
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isEditingURL) {
            BrowserURLEditSheet(
                initialURL: liveURL ?? initialURL,
                onSubmit: { newURL in
                    liveURL = newURL
                    isEditingURL = false
                }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        // **2026-06-10 fix.** Without this binding the user could
        // navigate to a dApp, tap Connect on the page, and nothing
        // happened — because the router updated `pendingRequest`
        // but only `BrowserHomeView` was bound to it, and home
        // isn't in the hierarchy while the session view is shown.
        // The session view IS the surface dApps actually run on,
        // so it owns the same `.sheet(item:)` binding.
        .sheet(item: routerPendingBinding) { request in
            Group {
                switch request {
                case .connect(let r):
                    DAppConnectSheet(request: r, router: router)
                case .signMessage(let r):
                    DAppSignMessageSheet(request: r, router: router)
                case .signTypedData(let r):
                    DAppSignTypedDataSheet(request: r, router: router)
                case .sendTransaction(let r):
                    DAppSendTransactionSheet(request: r, router: router)
                }
            }
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .onChange(of: liveURL) { _, newURL in
            // URL change is the one canonical "a visit happened"
            // signal — recording on title change too double-counted
            // every page load.
            guard let newURL else { return }
            recordVisit(for: newURL)
        }
        .onChange(of: pageTitle) { _, newTitle in
            // The title usually resolves after the URL. Backfill it
            // onto the already-recorded visit without incrementing
            // the count again.
            updateRecordedTitle(newTitle)
        }
    }

    // MARK: - Top chrome

    /// URL bar + progress strip + close. One Liquid Glass capsule
    /// holding the host + lock state, plus a leading bare close
    /// chevron, plus a trailing reload/stop icon. The progress
    /// strip lives just under the capsule.
    @ViewBuilder
    private var topChrome: some View {
        VStack(spacing: UniSpacing.xxs) {
            HStack(spacing: UniSpacing.s) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close browser"))

                Button {
                    isEditingURL = true
                } label: {
                    urlBar
                }
                .buttonStyle(.plain)

                reloadOrStopButton
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.xs)

            if isLoading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(UniColors.Tint.accent)
                    .frame(height: 2)
                    .padding(.horizontal, UniSpacing.m)
                    .transition(.opacity)
            }
        }
        .background {
            UniColors.Background.primary
                .opacity(0.92)
                .ignoresSafeArea(edges: .top)
        }
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }

    /// The URL pill — `Capsule`-shaped Liquid Glass surface with
    /// leading lock state + host text + (when scrolling) a
    /// trailing reload glyph. Tap = open the URL-edit sheet.
    @ViewBuilder
    private var urlBar: some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: isSecure ? "lock.fill" : "lock.open")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSecure ? UniColors.Icon.secondary : UniColors.Status.warningForeground)
                .accessibilityHidden(true)

            Text(verbatim: displayHost)
                .font(UniTypography.subheadlineEmphasized)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.m)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .glassEffect(
            .regular.interactive(),
            in: .capsule
        )
        .contentShape(Capsule())
        .accessibilityLabel(Text(verbatim: "URL: \(displayHost)"))
        .accessibilityHint(Text("Tap to edit URL"))
    }

    @ViewBuilder
    private var reloadOrStopButton: some View {
        Button {
            if isLoading {
                actions.stop()
            } else {
                actions.reload()
            }
        } label: {
            Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(UniColors.Icon.primary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isLoading ? "Stop loading" : "Reload page"))
    }

    // MARK: - Bottom chrome

    /// Four icon buttons in a row on a single Liquid Glass platter
    /// — back, forward, share, close. iOS Safari has the same
    /// four; we adopt the convention so the user's existing
    /// muscle memory transfers.
    ///
    /// **Why bare SF Symbols.** Per M-002 / M-003 the toolbar
    /// convention is bare SF Symbol glyphs (no `.circle` / no
    /// `.fill.circle`). The chrome platter provides the visual
    /// affordance.
    ///
    /// **Why one platter, not four glass buttons.** Apple's iOS 26
    /// toolbars (Safari, Mail, Notes) render their bottom chrome
    /// as a single Liquid Glass capsule holding bare icons — not
    /// four individual glass capsules in a row. The single-platter
    /// shape is the system convention and what users recognise as
    /// "browser chrome." The `.glassEffect(.regular.interactive(),
    /// in:)` call paints one translucent + specular + motion-
    /// responsive surface (Rule #2 §B.1) around the row.
    @ViewBuilder
    private var bottomChrome: some View {
        HStack(spacing: 0) {
            navIcon(
                "chevron.left",
                label: "Back",
                enabled: canGoBack,
                action: { actions.goBack() }
            )
            navIcon(
                "chevron.right",
                label: "Forward",
                enabled: canGoForward,
                action: { actions.goForward() }
            )
            if let liveURL {
                ShareLink(item: liveURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.primary)
                        .frame(width: 48, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel(Text("Share"))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
                    .frame(width: 48, height: 44)
                    .accessibilityHidden(true)
            }
            navIcon(
                "xmark",
                label: "Close",
                enabled: true,
                action: { dismiss() }
            )
        }
        .padding(.horizontal, UniSpacing.s)
        .frame(height: 52)
        .glassEffect(
            .regular.interactive(),
            in: .capsule
        )
        .contentShape(Capsule())
        .padding(.horizontal, UniSpacing.m)
        .padding(.bottom, UniSpacing.xs)
    }

    @ViewBuilder
    private func navIcon(
        _ symbol: String,
        label: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(enabled ? UniColors.Icon.primary : UniColors.Icon.tertiary)
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }

    // MARK: - Derived

    private var displayHost: String {
        if let liveURL {
            return BrowserURLNormalizer.displayHost(for: liveURL)
        }
        return BrowserURLNormalizer.displayHost(for: initialURL)
    }

    private var isSecure: Bool {
        (liveURL ?? initialURL).scheme?.lowercased() == "https"
    }

    /// Bind the parent's `liveURL` to a binding `BrowserWebView`
    /// reads + writes. Defaulted to `initialURL` so the webview
    /// loads it on first appear.
    private var webViewURLBinding: Binding<URL?> {
        Binding(
            get: { liveURL ?? initialURL },
            set: { liveURL = $0 }
        )
    }

    // MARK: - History recording

    private func recordVisit(for url: URL) {
        guard let host = url.host else { return }
        guard lastRecordedURL != url.absoluteString else { return }
        lastRecordedURL = url.absoluteString

        let descriptor = FetchDescriptor<BrowserHistoryRecord>(
            predicate: #Predicate { $0.host == host }
        )
        do {
            if let existing = try modelContext.fetch(descriptor).first {
                existing.url = url.absoluteString
                if !pageTitle.isEmpty {
                    existing.title = pageTitle
                }
                existing.lastVisitedAt = Date()
                existing.visitCount += 1
            } else {
                let record = BrowserHistoryRecord(
                    url: url.absoluteString,
                    title: pageTitle,
                    host: host,
                    // The site's own favicon — never a third-party
                    // favicon service that would learn the user's
                    // browsing history.
                    iconURL: "https://\(host)/favicon.ico",
                    lastVisitedAt: Date(),
                    visitCount: 1
                )
                modelContext.insert(record)
            }
            try modelContext.save()
        } catch {
            // Best-effort — a history-write failure should never
            // interrupt the user's browsing.
        }
    }

    /// Backfill the page title onto the host's history record once
    /// the page reports it. Does NOT touch `visitCount`.
    private func updateRecordedTitle(_ title: String) {
        guard !title.isEmpty,
              let host = (liveURL ?? initialURL).host else { return }

        let descriptor = FetchDescriptor<BrowserHistoryRecord>(
            predicate: #Predicate { $0.host == host }
        )
        do {
            if let existing = try modelContext.fetch(descriptor).first {
                existing.title = title
                try modelContext.save()
            }
        } catch {
            // Best-effort.
        }
    }
}
