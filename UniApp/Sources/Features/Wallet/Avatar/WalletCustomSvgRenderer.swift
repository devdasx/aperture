import SwiftUI
import WebKit
import OSLog

/// `WalletCustomSvgRenderer` turns a sanitized SVG string + a tint
/// choice into a cached PNG on disk, then hands the cached PNG back to
/// the avatar pipeline. It exists because:
///
/// 1. Rendering arbitrary user SVG natively in SwiftUI is unsafe —
///    there is no public `Path`-from-SVG-string API and Rule #3 forbids
///    third-party SVG libraries (SVGKit / PocketSVG / SwiftSVG).
/// 2. `WKWebView` is a system framework, can render passive SVG safely
///    inside a transparent web view, and exposes
///    `takeSnapshot(with:)` to produce a `UIImage` from a view region —
///    exactly the pipeline the v3 design handoff prescribes.
///
/// **The contract.**
/// - `cachedImage(walletId:)` returns the on-disk PNG for a wallet, or
///   `nil` if no cache exists. Async — the file read + decode runs off
///   the main actor so body passes and list scrolls never block on
///   disk I/O.
/// - `renderAndCache(walletId:svg:tint:)` is the async write path —
///   spins up an off-screen `WKWebView`, loads the sanitized SVG with
///   the appropriate tint inline, takes a snapshot, writes the PNG to
///   `~/Library/Caches/ApertureCustomAvatars/{walletId}.png`. Returns
///   the `UIImage` so the caller can use it without re-reading from
///   disk.
/// - `invalidate(walletId:)` deletes the cached PNG so the next call
///   to `cachedImage` returns nil and the next `renderAndCache` will
///   recompute. Called from `WalletIconPickerSheet.commit(...)` before
///   re-rendering so a re-save always lands fresh pixels.
///
/// **Cache key = wallet UUID, NOT content hash.** Per the v3 brief:
/// every re-save invalidates the cache. A content hash would collide
/// across two wallets that uploaded the same logo + tint — semantically
/// fine but operationally fragile. Per-wallet UUID gives one-PNG-per-
/// wallet, no collisions, simple invalidation.
///
/// **Cache directory.** `Library/Caches/ApertureCustomAvatars/` — iOS
/// is allowed to evict this directory under storage pressure. If
/// eviction happens, the next render re-creates the PNG from the
/// sanitized SVG (which lives in SwiftData + Keychain as the source
/// of truth). No data loss; just a one-time re-render.
///
/// **Render resolution.** 192×192 pixels = 96pt × 2x (Retina). The
/// largest avatar size the picker presents is `.editor` (96pt); at
/// 2x device scale, 192 is the maximum useful resolution. For 3x
/// devices the system upscales 192 → 288 with bilinear filtering —
/// acceptable for a user-supplied identity mark inside a 96pt disc.
///
/// **Why MainActor.** `WKWebView` and `UIScreen.main` require the
/// main actor. `ImageRenderer`-style usage. The actor isolation
/// keeps all WebKit interaction on the main thread and avoids any
/// async hop into a background actor that would then have to round-
/// trip back to UI code.
///
/// **Why no third-party dependency.** `WebKit` is system. `UIKit` is
/// system. `OSLog` is system. No SVGKit, no PocketSVG, no SwiftSVG.
/// Rule #3 satisfied.
@MainActor
enum WalletCustomSvgRenderer {

    // MARK: - Constants

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "wallet-custom-svg"
    )

    /// Render resolution in pixels. Matches the 96pt × 2x Retina
    /// envelope of the picker's `.editor` avatar size.
    private static let renderPixels: CGFloat = 192

    /// Renderer errors. Surfaced to the picker if the WebKit pipeline
    /// fails (rare — WKWebView snapshots normally succeed for passive
    /// SVG content; this exists so the caller can branch on failure
    /// instead of silently swallowing).
    enum RendererError: Error, Sendable {
        case snapshotFailed
        case writeFailed(underlying: Error)
    }

    // MARK: - Cache directory

    /// Lazy-created cache directory under `Library/Caches/`. iOS evicts
    /// `Caches/` under pressure; that's a feature, not a bug — the
    /// SwiftData spec is the source of truth and re-rendering is cheap.
    ///
    /// `static let` so the URL resolution + ensure-exists check runs
    /// once per process (Swift's lazy static initialization), not on
    /// every cache read/write. If iOS evicts the directory mid-run the
    /// next `writeCache` throws and the caller's error path handles it.
    private static let cacheDirectory: URL = {
        // `.cachesDirectory` is guaranteed in the iOS sandbox, but fall
        // back to the temp dir rather than force-unwrap — a crash here
        // would take down a cold launch (2026-06-14 audit hardening).
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ApertureCustomAvatars", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
            } catch {
                log.error("Failed to create cache directory: \(String(describing: error), privacy: .public)")
            }
        }
        return dir
    }()

    private static func cacheURL(for walletId: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(walletId.uuidString).png", isDirectory: false)
    }

    // MARK: - Public surface

    /// Returns the cached PNG for a wallet, if one exists. Async —
    /// `Data(contentsOf:)` is blocking disk I/O, so the read + decode
    /// runs detached off the main actor and only the resulting
    /// (Sendable) `UIImage` hops back. Used by `CustomSvgCachedView`'s
    /// `.task` to decide whether to render the cached image immediately
    /// or fall back to a placeholder while the async render runs.
    static func cachedImage(walletId: UUID) async -> UIImage? {
        let url = cacheURL(for: walletId)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else {
                return nil
            }
            return image
        }.value
    }

    /// Render the sanitized SVG to a PNG, write it to the cache, and
    /// return the `UIImage`. The async path. Throws if the snapshot
    /// fails or the disk write errors.
    @discardableResult
    static func renderAndCache(
        walletId: UUID,
        svg: String,
        tint: WalletAvatarSpec.CustomTint
    ) async throws -> UIImage {
        let image = try await snapshot(svg: svg, tint: tint)
        try writeCache(walletId: walletId, image: image)
        return image
    }

    /// Delete the cached PNG. Idempotent — no-op if the file doesn't
    /// exist. Called from the picker's commit handler before
    /// `renderAndCache(...)` so each save lands a fresh pixel buffer.
    static func invalidate(walletId: UUID) {
        let url = cacheURL(for: walletId)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Snapshot pipeline

    /// Spin up an offscreen `WKWebView`, load the sanitized SVG
    /// wrapped in a minimal HTML host that centers and tints it, take
    /// a snapshot at `renderPixels × renderPixels`, return the
    /// resulting `UIImage`. Throws `.snapshotFailed` if the WebKit
    /// pipeline returns no image.
    private static func snapshot(
        svg: String,
        tint: WalletAvatarSpec.CustomTint
    ) async throws -> UIImage {
        let html = htmlHost(svg: svg, tint: tint)
        let config = WKWebViewConfiguration()
        config.preferences = {
            let p = WKPreferences()
            // Disable JS — passive SVG only. The sanitizer already
            // strips `<script>` tags, but defense in depth: the
            // renderer's own host page also denies JS execution.
            p.javaScriptCanOpenWindowsAutomatically = false
            return p
        }()
        // iOS 14+ way to disable JS — set the policy on the page
        // preferences. Even if a sanitizer bypass somehow lets a
        // `<script>` through, the renderer cannot run it.
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePrefs

        let frame = CGRect(x: 0, y: 0, width: renderPixels, height: renderPixels)
        let webView = WKWebView(frame: frame, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        // Hold a strong reference via the delegate so the load callback
        // can resume the continuation.
        let coordinator = LoadCoordinator()
        webView.navigationDelegate = coordinator

        return try await withCheckedThrowingContinuation { continuation in
            coordinator.onFinish = { result in
                switch result {
                case .success:
                    let snapshotConfig = WKSnapshotConfiguration()
                    snapshotConfig.rect = frame
                    snapshotConfig.afterScreenUpdates = true
                    webView.takeSnapshot(with: snapshotConfig) { image, error in
                        if let image {
                            continuation.resume(returning: image)
                        } else {
                            log.error("WKWebView snapshot failed: \(String(describing: error), privacy: .public)")
                            continuation.resume(throwing: RendererError.snapshotFailed)
                        }
                    }
                case .failure(let error):
                    log.error("WKWebView load failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: RendererError.snapshotFailed)
                }
            }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Compose the minimal HTML host that displays the sanitized SVG.
    /// The brief specifies:
    /// - Box ~48/100 of the disc (we render against a 192×192 frame,
    ///   so the SVG content is centered with auto margins).
    /// - `customTint == .white` applies `filter: brightness(0) invert(1)`
    ///   to produce a clean white silhouette.
    /// - `customTint == .original` leaves the SVG colors intact.
    ///
    /// The host page background is transparent; the gradient disc is
    /// painted by the SwiftUI `WalletAvatar` pipeline AROUND this
    /// rendered PNG, not by the WKWebView.
    private static func htmlHost(
        svg: String,
        tint: WalletAvatarSpec.CustomTint
    ) -> String {
        let filterRule = (tint == .white)
            ? "filter: brightness(0) invert(1);"
            : ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
            html, body {
                margin: 0;
                padding: 0;
                background: transparent;
                width: 100%;
                height: 100%;
            }
            .stage {
                display: flex;
                align-items: center;
                justify-content: center;
                width: 100%;
                height: 100%;
            }
            .stage > svg {
                width: 100%;
                height: 100%;
                \(filterRule)
            }
        </style></head>
        <body><div class="stage">\(svg)</div></body></html>
        """
    }

    // MARK: - Disk write

    private static func writeCache(walletId: UUID, image: UIImage) throws {
        guard let data = image.pngData() else {
            throw RendererError.writeFailed(underlying: NSError(
                domain: "WalletCustomSvgRenderer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Image had no PNG representation"]
            ))
        }
        let url = cacheURL(for: walletId)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw RendererError.writeFailed(underlying: error)
        }
    }
}

// MARK: - WKNavigationDelegate bridge

/// Tiny `WKNavigationDelegate` that resumes the awaiter when the
/// `WKWebView` finishes loading the HTML host. Lives outside the
/// `WalletCustomSvgRenderer` enum because Swift enums can't conform
/// to `@objc` protocols. The instance is held by the snapshot
/// continuation closure so it survives until `takeSnapshot(...)`
/// completes.
@MainActor
private final class LoadCoordinator: NSObject, WKNavigationDelegate {
    var onFinish: ((Result<Void, Error>) -> Void)?

    /// Capture-and-nil the closure before invoking it. WebKit can
    /// deliver MORE than one delegate callback for a single navigation
    /// (e.g. `didFailProvisionalNavigation` followed by `didFinish`
    /// for the error page, or `didFinish` + `didFail` in teardown
    /// races) — and the closure resumes a `CheckedContinuation`, which
    /// traps at runtime on a double resume. Clearing `onFinish` first
    /// makes every callback after the first a no-op. The class is
    /// `@MainActor`-isolated, so the read-then-clear is atomic with
    /// respect to the delegate callbacks (all main-thread).
    private func finishOnce(_ result: Result<Void, Error>) {
        let callback = onFinish
        onFinish = nil
        callback?(result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishOnce(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishOnce(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishOnce(.failure(error))
    }
}
