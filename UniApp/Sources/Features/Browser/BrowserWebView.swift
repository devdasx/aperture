import SwiftUI
import WebKit
import OSLog

/// SwiftUI wrapper around `WKWebView` for Aperture's in-app dApp
/// browser. Injects the EIP-1193 + Solana wallet provider script at
/// document-start so every page sees `window.ethereum` and
/// `window.solana` before any dApp code runs. JSON-RPC requests from
/// the page flow into `DAppRequestRouter` via a `WKScriptMessageHandler`;
/// responses are posted back to the page via JS evaluation.
///
/// **Rule #3 native-only.** Pure system frameworks: `WKWebView`,
/// `WKUserContentController`, `WKWebsiteDataStore`. No third-party
/// browser engine or webview wrapper.
struct BrowserWebView: UIViewRepresentable {
    /// The URL the browser should load. Bind from the parent; the
    /// wrapper updates it as the user navigates so the URL bar
    /// stays in sync.
    @Binding var url: URL?

    /// Bound progress (0.0–1.0). Drives the slim progress strip in
    /// `BrowserSessionView`'s top chrome.
    @Binding var progress: Double

    /// Bound loading flag. `true` while a page is loading; `false`
    /// when finished or failed.
    @Binding var isLoading: Bool

    /// Bound page title. Updated as the page reports it.
    @Binding var title: String

    /// Bound canGoBack / canGoForward to drive the bottom nav buttons.
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    /// Router that resolves dApp JSON-RPC requests against the user's
    /// active wallet. Owns the confirmation sheets and the signing
    /// pipeline.
    let router: DAppRequestRouter

    /// Imperative navigation commands the parent can fire. Passed in
    /// by `BrowserSessionView` as a shared `Coordinator` reference.
    let actions: BrowserActions

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()

        // Inject the provider script at document-start so dApps see
        // `window.ethereum` before any of their bundle code runs.
        //
        // **2026-06-10 fix.** xcodegen flattens
        // `Resources/Browser/ApertureProvider.js` to the bundle
        // root, so the older `subdirectory: "Browser"` lookup
        // returned nil and the dApp never saw `window.ethereum`
        // (so no connect prompt fired). Search the root first;
        // fall back to the subdirectory in case a future xcodegen
        // bump restores the nested layout.
        let scriptURL = Bundle.main.url(forResource: "ApertureProvider", withExtension: "js")
            ?? Bundle.main.url(
                forResource: "ApertureProvider",
                withExtension: "js",
                subdirectory: "Browser"
            )
        if let scriptURL,
           let scriptSource = try? String(contentsOf: scriptURL, encoding: .utf8) {
            // Main frame ONLY — injecting into subframes would hand
            // every embedded third-party iframe a wallet provider and
            // a direct line to the native message handler.
            let userScript = WKUserScript(
                source: scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            userContent.addUserScript(userScript)
        } else {
            Self.log.error("ApertureProvider.js not found in bundle — dApps won't see window.ethereum.")
        }

        userContent.add(context.coordinator, name: "aperture")
        config.userContentController = userContent
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Persistent data store so dApps can keep their sign-in state /
        // local cache between sessions (just like Safari). Use the
        // non-persistent store for incognito if we add it later.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = Self.userAgentString
        #if DEBUG
        webView.isInspectable = true
        #endif

        // KVO for progress + url + title + nav buttons.
        context.coordinator.attachKVO(to: webView)

        // Imperative actions — back, forward, reload, stop.
        actions.goBack = { [weak webView] in webView?.goBack() }
        actions.goForward = { [weak webView] in webView?.goForward() }
        actions.reload = { [weak webView] in webView?.reload() }
        actions.stop = { [weak webView] in webView?.stopLoading() }

        // Initial load.
        if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // When the parent rewrites the URL externally (typed in URL
        // bar, tapped a favorite), navigate. Skip when the WebView is
        // already there to avoid a refresh loop.
        guard let url else { return }
        if webView.url?.absoluteString != url.absoluteString {
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.detachKVO()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "aperture")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: BrowserWebView
        private var observations: [NSKeyValueObservation] = []

        init(parent: BrowserWebView) {
            self.parent = parent
        }

        func attachKVO(to webView: WKWebView) {
            observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                guard let new = change.newValue else { return }
                Task { @MainActor in self?.parent.progress = new }
            })
            observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                guard let new = change.newValue else { return }
                Task { @MainActor in self?.parent.isLoading = new }
            })
            observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, change in
                guard let new = change.newValue, let url = new else { return }
                Task { @MainActor in self?.parent.url = url }
            })
            observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, change in
                let new = change.newValue ?? ""
                Task { @MainActor in self?.parent.title = new ?? "" }
            })
            observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                guard let new = change.newValue else { return }
                Task { @MainActor in self?.parent.canGoBack = new }
            })
            observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                guard let new = change.newValue else { return }
                Task { @MainActor in self?.parent.canGoForward = new }
            })
        }

        func detachKVO() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }

        // MARK: WKNavigationDelegate

        // Async form — exact protocol match under Swift 6 (the
        // completion-handler form's sendability "nearly matches" and
        // WebKit would silently never call it, leaving `wc:` URIs to
        // load as dead web pages).
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // Intercept `wc:` and `aperture:` URIs so they don't try to
            // load as web pages. Hand them off to the WalletConnect
            // pairing path.
            if let target = navigationAction.request.url,
               target.scheme == "wc" {
                await parent.router.handleWalletConnectURI(target.absoluteString)
                return .cancel
            }
            return .allow
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // Main-frame requests only. A compromised or merely
            // embedded subframe must never speak to the wallet bridge.
            guard message.frameInfo.isMainFrame else { return }
            guard message.name == "aperture",
                  let body = message.body as? [String: Any],
                  let id = body["id"] as? String,
                  let channel = body["channel"] as? String,
                  let method = body["method"] as? String else {
                return
            }
            let params = (body["params"] as? [Any]) ?? []
            // Capture the requesting frame's security origin
            // SYNCHRONOUSLY — reading `webView.url` later inside the
            // Task races navigation: the page could navigate away and
            // the request would be attributed (and its connection
            // grant issued) to the wrong origin.
            let securityOrigin = message.frameInfo.securityOrigin
            var originComponents = URLComponents()
            originComponents.scheme = securityOrigin.`protocol`
            originComponents.host = securityOrigin.host
            if securityOrigin.port != 0 {
                originComponents.port = securityOrigin.port
            }
            let originURL = originComponents.url
            let pageTitle = message.webView?.title
            let webView = message.webView
            Task { @MainActor in
                let result = await parent.router.handle(
                    channel: channel,
                    method: method,
                    params: params,
                    pageURL: originURL,
                    pageTitle: pageTitle
                )
                resolve(id: id, result: result, in: webView)
            }
        }

        @MainActor
        private func resolve(id: String, result: DAppRequestResult, in webView: WKWebView?) {
            guard let webView else { return }
            let envelope: String
            switch result {
            case .success(let value):
                envelope = "{\"id\":\(Self.jsonString(id)),\"result\":\(Self.jsonString(value))}"
            case .failure(let error):
                envelope = "{\"id\":\(Self.jsonString(id)),\"error\":{\"code\":\(error.code),\"message\":\(Self.jsonString(error.message))}}"
            }
            let js = "window.__apertureDispatch && window.__apertureDispatch(\(envelope));"
            webView.evaluateJavaScript(js) { _, _ in }
        }

        private static func jsonString(_ value: Any) -> String {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "null"
        }
    }

    // MARK: - Statics

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "browser-webview")

    /// User-agent string — matches Safari closely so dApps render their
    /// mobile-Safari path correctly while still identifying as Aperture.
    private static let userAgentString: String =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/26.0 Mobile/15E148 Safari/604.1 Aperture/1.0"
}

/// Imperative navigation actions on the WebView. `BrowserSessionView`
/// holds one and the nav-chrome buttons call into it.
final class BrowserActions: ObservableObject, @unchecked Sendable {
    var goBack: () -> Void = {}
    var goForward: () -> Void = {}
    var reload: () -> Void = {}
    var stop: () -> Void = {}
}
