import SwiftUI
import UIKit
import os

private let installerLog = Logger(
    subsystem: "com.thuglife.aperture",
    category: "tab-context-menu"
)

/// Zero-size `UIViewControllerRepresentable` that resolves the host
/// `UITabBarController` and attaches a `UIContextMenuInteraction` to
/// the bar so a long-press on the target tab presents iOS's native
/// context menu — the same pattern Mail uses for the account
/// switcher, Messages uses for conversation actions, and the
/// home-screen app icons use for shortcuts.
///
/// **Why a context menu, not a sheet (2026-06-09 v4).** v1–v3 fired
/// a SwiftUI `.sheet` from a `UILongPressGestureRecognizer.began`
/// callback. The user observed that the sheet felt off-system:
/// > *"when i long press here it shouldn't show the sheet, instead
/// > it should show options ... and it should be apple native."*
///
/// `UIContextMenuInteraction` IS the apple-native primitive. It owns
/// the long-press timing, the haptic at preview, the blur backdrop,
/// the rounded-glass menu chrome, the dismissal gesture, the
/// accessibility tree, and the Voice Control vocabulary — none of
/// which a sheet inherits. Per Rule #3 (native-only), the rewrite
/// drops the sheet and adopts the system primitive.
///
/// **Why on the `UITabBar`, not on a button subview.** Same reason as
/// the v3 long-press: iOS 26's Liquid Glass tab bar uses a private
/// button class whose name doesn't contain `"Button"` — class-name
/// filtering returns zero matches. We attach the interaction to the
/// public `UITabBar` instance (which IS guaranteed to exist —
/// `SwiftUI-Introspect` confirms the `UITabBarController` bridge on
/// iOS 26) and use the press location's x-coordinate to filter for
/// the target tab (Wallet = 0).
///
/// **How we find the `UITabBarController`.** Three strategies in
/// order: `UIViewController.parent` chain → `self.tabBarController`
/// accessor → window root DFS. Identical to v3. The strategy is
/// already battle-tested; the only thing that changes is what
/// happens once we have the bar.
///
/// **Rule #3 (native-only).** `UIContextMenuInteraction` is Apple's
/// canonical long-press-menu surface. No SwiftUI hack, no
/// third-party menu library, no custom blur background. The
/// `UIMenu` is built in SwiftUI via a closure the caller passes in;
/// the wrapper hands that closure to iOS verbatim.
struct TabBarLongPressInstaller: UIViewControllerRepresentable {
    /// Zero-based index of the tab whose long-press should surface
    /// the context menu. Wallet = 0 in `MainTabView`'s order.
    let tabIndex: Int
    /// Closure that returns the `UIMenu` to present, evaluated lazily
    /// when the user actually long-presses. Building per-press (not
    /// per-body) lets the menu reflect the live wallet list, active
    /// wallet, etc. without the wrapper having to subscribe to
    /// SwiftUI's reactive surfaces.
    let menuProvider: () -> UIMenu

    func makeUIViewController(context: Context) -> InstallerController {
        installerLog.info("makeUIViewController for tabIndex=\(tabIndex)")
        return InstallerController(tabIndex: tabIndex, menuProvider: menuProvider)
    }

    func updateUIViewController(_ vc: InstallerController, context: Context) {
        vc.tabIndex = tabIndex
        vc.menuProvider = menuProvider
        vc.installIfNeeded(reason: "updateUIViewController")
    }

    // MARK: - Installer view controller

    final class InstallerController: UIViewController, UIContextMenuInteractionDelegate {
        var tabIndex: Int
        var menuProvider: () -> UIMenu
        weak var installedOn: UITabBar?
        /// Tagged identity for our `UIContextMenuInteraction`. Lets us
        /// distinguish our interaction from any iOS-internal one when
        /// removing stale instances on tab-bar regeneration.
        private static let interactionTag = ObjectIdentifier(InstallerController.self)
        private var ownInteraction: UIContextMenuInteraction?

        init(tabIndex: Int, menuProvider: @escaping () -> UIMenu) {
            self.tabIndex = tabIndex
            self.menuProvider = menuProvider
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func loadView() {
            let v = UIView(frame: .zero)
            v.isUserInteractionEnabled = false
            v.backgroundColor = .clear
            view = v
        }

        /// `true` once the interaction is attached to a live tab bar.
        /// The cheapest possible exit for the deferred retries below —
        /// two stored-property nil checks, no controller resolution.
        /// (`installedOn` is weak, so a deallocated bar reads as "not
        /// installed" and the retries correctly re-attach.)
        private var isInstalled: Bool {
            ownInteraction != nil && installedOn != nil
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installerLog.info("viewDidAppear: tabIndex=\(self.tabIndex)")
            installIfNeeded(reason: "viewDidAppear")
            // Deferred retries — only queued when the immediate attempt
            // failed (the tab bar may not be in the hierarchy yet on
            // first appearance). Each fired closure re-checks the
            // installed flag FIRST so a retry that lands after a
            // successful install (e.g. via viewDidLayoutSubviews)
            // exits at zero cost instead of re-resolving the
            // controller chain.
            guard !isInstalled else { return }
            for delay: TimeInterval in [0.1, 0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.isInstalled else { return }
                    self.installIfNeeded(reason: "viewDidAppear+\(delay)s")
                }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installIfNeeded(reason: "viewDidLayoutSubviews")
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installerLog.info(
                "didMove(toParent:) parent=\(parent.map { String(describing: type(of: $0)) } ?? "nil")"
            )
            installIfNeeded(reason: "didMove(toParent:)")
        }

        deinit {
            // Backstop teardown: if this installer goes away while the
            // interaction (or an orphaned anchor view from a menu whose
            // `willEndFor` never fired) is still attached to the bar,
            // strip both. UIViewController deallocation happens on the
            // main thread; `assumeIsolated` re-asserts that so the
            // UIKit teardown calls satisfy strict concurrency.
            MainActor.assumeIsolated {
                teardownInstalledInteraction()
            }
        }

        func installIfNeeded(reason: String) {
            guard let tabBarController = resolveTabBarController() else {
                installerLog.debug("installIfNeeded[\(reason)]: no UITabBarController")
                return
            }
            let tabBar = tabBarController.tabBar
            attach(to: tabBar)
        }

        // MARK: - Resolution (same 3-strategy fallback as v3)

        private func resolveTabBarController() -> UITabBarController? {
            var current: UIViewController? = self.parent
            while current != nil {
                if let tbc = current as? UITabBarController { return tbc }
                current = current?.parent
            }
            if let tbc = self.tabBarController { return tbc }
            if let tbc = self.parent?.tabBarController { return tbc }
            if let window = view.window,
               let root = window.rootViewController,
               let tbc = Self.findTabBarController(in: root) {
                return tbc
            }
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    if let root = window.rootViewController,
                       let tbc = Self.findTabBarController(in: root) {
                        return tbc
                    }
                }
            }
            return nil
        }

        private static func findTabBarController(in vc: UIViewController) -> UITabBarController? {
            if let tbc = vc as? UITabBarController { return tbc }
            for child in vc.children {
                if let found = findTabBarController(in: child) { return found }
            }
            if let presented = vc.presentedViewController {
                return findTabBarController(in: presented)
            }
            return nil
        }

        // MARK: - Attach

        private func attach(to tabBar: UITabBar) {
            if installedOn === tabBar, ownInteraction != nil {
                return
            }
            // Tab bar instance changed (regenerated chrome on trait
            // collection change). Tear down the prior interaction AND
            // any orphaned anchor view still parked on the old bar.
            teardownInstalledInteraction()
            // Defensive: strip stale anchors from the NEW bar too, in
            // case a previous installer instance left one behind.
            Self.stripAnchorViews(from: tabBar)
            let interaction = UIContextMenuInteraction(delegate: self)
            tabBar.addInteraction(interaction)
            ownInteraction = interaction
            installedOn = tabBar
            installerLog.info("attach: installed UIContextMenuInteraction on UITabBar")
        }

        /// Tear down everything this installer added to the bar — the
        /// context-menu interaction and any orphaned invisible anchor
        /// view. `willEndFor` is not guaranteed to fire for every
        /// presented menu (the bar can be torn down mid-presentation),
        /// so this is the leak backstop, called on bar regeneration
        /// (`attach(to:)`) and on installer `deinit`.
        private func teardownInstalledInteraction() {
            if let bar = installedOn {
                if let prior = ownInteraction {
                    bar.removeInteraction(prior)
                }
                Self.stripAnchorViews(from: bar)
            }
            ownInteraction = nil
            installedOn = nil
        }

        /// Remove every invisible anchor view this installer family has
        /// ever parked on the given bar (matched by `anchorViewTag`).
        private static func stripAnchorViews(from tabBar: UITabBar) {
            tabBar.subviews
                .filter { $0.tag == anchorViewTag }
                .forEach { $0.removeFromSuperview() }
        }

        // MARK: - UIContextMenuInteractionDelegate

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let tabBar = interaction.view as? UITabBar else { return nil }
            // Same x-coord-to-tab-index math as the v3 recognizer —
            // only return a configuration if the press landed on our
            // target tab. Other tabs get nil → iOS skips the menu and
            // lets the normal tap-to-switch fire. The press location
            // is in *visual* coordinates, so the logical `tabIndex`
            // is resolved through `effectiveTabIndex(in:itemCount:)`
            // — under RTL the leading (Wallet) tab renders at the
            // trailing x-segment.
            let count = resolvedTabCount(tabBar: tabBar)
            guard count > 0 else { return nil }
            let segmentWidth = tabBar.bounds.width / CGFloat(count)
            let pressedIndex = Int((location.x / segmentWidth).rounded(.down))
            let targetIndex = effectiveTabIndex(in: tabBar, itemCount: count)
            guard pressedIndex == targetIndex else {
                installerLog.debug("ctx-menu: skipped (pressed segment \(pressedIndex), target segment \(targetIndex))")
                return nil
            }
            installerLog.info("ctx-menu: presenting menu for tab \(self.tabIndex)")
            // Pass `previewProvider: nil` so iOS only shows the menu
            // — no preview card above. Our "preview" would be the
            // current wallet's home, which is already on screen.
            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: nil
            ) { [weak self] _ in
                self?.menuProvider()
            }
        }

        /// Anchor the menu's position to the wallet tab's exact rect
        /// inside the bar (Telegram-style — the menu hugs the tab item
        /// it was triggered from, not the press location).
        ///
        /// **Why a targeted preview, not a preview provider.** A
        /// preview provider would render a "card" above the menu —
        /// which iOS positions but ALSO requires us to fabricate a
        /// view to show in the card. We don't want a card; the wallet
        /// avatar's already visible on the tab. A `UITargetedPreview`
        /// with an invisible anchor view lets iOS skip the card and
        /// position the menu purely against the anchor's center —
        /// exactly what we want.
        ///
        /// **Why an invisible anchor, not the actual tab button.** The
        /// private button class on iOS 26's Liquid Glass tab bar
        /// doesn't expose its frame through any public accessor we can
        /// rely on. The invisible anchor is positioned by the same
        /// x-coord math the press-location check uses, so it's always
        /// at the right place regardless of how iOS lays out the bar
        /// internally.
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            makeTargetedPreview(in: interaction.view as? UITabBar)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            // Reuse the same anchor on dismiss so the menu animates
            // back to the same position it came from.
            makeTargetedPreview(in: interaction.view as? UITabBar)
        }

        /// Build the anchor view + targeted preview that ties the
        /// menu to the wallet tab's rect. Cleans up any orphan anchor
        /// before installing the new one — defensive against missed
        /// `willEnd` callbacks.
        private func makeTargetedPreview(in tabBar: UITabBar?) -> UITargetedPreview? {
            guard let tabBar = tabBar else { return nil }
            // Strip any prior anchor first.
            Self.stripAnchorViews(from: tabBar)

            let count = resolvedTabCount(tabBar: tabBar)
            guard count > 0 else { return nil }
            let segmentWidth = tabBar.bounds.width / CGFloat(count)
            // Visual segment index — RTL-aware, same resolution the
            // press-location hit test uses, so the anchor always sits
            // over the segment the user actually pressed.
            let targetIndex = effectiveTabIndex(in: tabBar, itemCount: count)
            let tabRect = CGRect(
                x: segmentWidth * CGFloat(targetIndex),
                y: 0,
                width: segmentWidth,
                height: tabBar.bounds.height
            )

            let anchor = UIView(frame: tabRect)
            anchor.backgroundColor = .clear
            anchor.isUserInteractionEnabled = false
            anchor.tag = Self.anchorViewTag
            tabBar.addSubview(anchor)

            let params = UIPreviewParameters()
            params.backgroundColor = .clear
            // Empty visiblePath suppresses the default highlight halo
            // iOS draws around a previewed view. Without it, iOS
            // briefly tints the anchor — visible on a clear view
            // because the tint is opaque.
            params.visiblePath = UIBezierPath(rect: .zero)

            return UITargetedPreview(view: anchor, parameters: params)
        }

        /// Strip any leftover anchor views the moment the menu starts
        /// dismissing — keeps the tab bar's subview list clean.
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            guard let tabBar = interaction.view as? UITabBar else { return }
            // `addCompletion` fires AFTER the dismiss animation —
            // removing the anchor mid-animation would jump-cut the
            // menu, so defer until iOS is done with it.
            let cleanup = {
                Self.stripAnchorViews(from: tabBar)
            }
            if let animator = animator {
                animator.addCompletion(cleanup)
            } else {
                cleanup()
            }
        }

        // MARK: - Helpers

        /// Marker tag for our invisible anchor view so we can find +
        /// remove it without scanning every subview type.
        private static let anchorViewTag: Int = 0x4AFE_A1AB

        /// Number of segments in the bar. The bar's own `items` array
        /// is the authority (it's what the bar lays out); the
        /// controller's `viewControllers` is the fallback when the
        /// items haven't been populated yet, and the literal 4 (this
        /// app's tab count) is the last-resort sane default.
        private func resolvedTabCount(tabBar: UITabBar) -> Int {
            if let items = tabBar.items, !items.isEmpty {
                return items.count
            }
            if let count = resolveTabBarController()?.viewControllers?.count, count > 0 {
                return count
            }
            return 4
        }

        /// The *visual* segment index our logical `tabIndex` occupies.
        /// UIKit lays tab items out leading → trailing, so under a
        /// right-to-left layout the first logical tab (Wallet = 0)
        /// renders in the right-most x-segment. The x-coordinate hit
        /// test and the anchor rect both work in visual coordinates —
        /// they must compare against this, not the raw logical index,
        /// or the menu fires on the wrong tab in Arabic / Hebrew /
        /// Persian / Urdu.
        private func effectiveTabIndex(in tabBar: UITabBar, itemCount: Int) -> Int {
            guard tabBar.effectiveUserInterfaceLayoutDirection == .rightToLeft else {
                return tabIndex
            }
            return itemCount - 1 - tabIndex
        }
    }
}
