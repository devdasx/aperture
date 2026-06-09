import SwiftUI
import UIKit

/// Zero-size `UIViewControllerRepresentable` that, on its hosting
/// controller's `viewDidAppear` and on every subsequent
/// `viewDidLayoutSubviews`, walks up to the window, finds the
/// `UITabBar`, filters its subviews for `UITabBarButton` instances
/// (identified via the documented `String(describing: type(of:
/// $0)).contains("Button")` pattern — `UITabBarButton` is a private
/// class so we identify by class-name string), sorts them by
/// `frame.minX` to mirror the visible tab order, and attaches a
/// `UILongPressGestureRecognizer` to the button at `tabIndex`.
///
/// **Why a UIViewController, not a UIView (2026-06-09 correction).**
/// The first installer (commit `e41593e`) was a `UIViewRepresentable`
/// + `DispatchQueue.main.async` deferral. That fired BEFORE the tab
/// bar was guaranteed to be in the window — the SwiftUI tree composes
/// the tab content's body before `UITabBarController` finishes its
/// own view hierarchy assembly, so the first attachment attempt
/// missed the bar and never retried. The UIViewController approach
/// uses iOS's own lifecycle: `viewDidAppear` fires only AFTER the
/// containing controller (in our case, the `UITabBarController` SwiftUI
/// hosts under the hood) has its `view` set up and added to the window.
/// `viewDidLayoutSubviews` then re-fires on every layout pass so we
/// auto-reattach if the tab bar gets regenerated (rotation, dynamic-
/// type resize, dark-mode trait change).
///
/// **Robustness:** the installer is idempotent — `installedOn` holds
/// a `weak` reference to the button it already wired, so repeated
/// layout passes don't stack recognizers. When iOS regenerates the
/// tab bar buttons, the weak reference clears and the next
/// `viewDidLayoutSubviews` re-attaches to the fresh button.
/// `cancelsTouchesInView = false` so the recognizer doesn't
/// interfere with the normal tap-to-switch-tab behaviour.
///
/// **Rule #3 (native-only):** pure `UIKit` + `UIViewControllerRepresentable`.
/// No third-party `siteline/swiftui-introspect` or similar.
///
/// **Usage:** place inside the tab's root content view tree with a
/// `.frame(width: 0, height: 0)` modifier so it doesn't occupy
/// layout space; pass the tab's zero-based index and the closure
/// that fires on `.began`. The closure typically flips a
/// `@State Bool` that drives a `.sheet(isPresented:)`.
struct TabBarLongPressInstaller: UIViewControllerRepresentable {
    /// Zero-based index of the tab whose `UITabBarButton` should
    /// receive the long-press recognizer. Wallet = 0 in
    /// `MainTabView`'s order.
    let tabIndex: Int
    /// Minimum press duration for the gesture. `0.4` matches the
    /// system default for a comfortable long-press without feeling
    /// sluggish.
    var minimumPressDuration: TimeInterval = 0.4
    /// Fires once on each long-press `.began` state. SwiftUI state
    /// updates inside the closure are safe (the recognizer runs on
    /// the main runloop).
    let onLongPress: () -> Void

    func makeUIViewController(context: Context) -> InstallerController {
        InstallerController(
            tabIndex: tabIndex,
            minimumPressDuration: minimumPressDuration,
            onLongPress: onLongPress
        )
    }

    func updateUIViewController(_ vc: InstallerController, context: Context) {
        vc.tabIndex = tabIndex
        vc.minimumPressDuration = minimumPressDuration
        vc.onLongPress = onLongPress
        vc.installIfNeeded()
    }

    // MARK: - Installer view controller

    final class InstallerController: UIViewController {
        var tabIndex: Int
        var minimumPressDuration: TimeInterval
        var onLongPress: () -> Void
        weak var installedOn: UIView?

        init(
            tabIndex: Int,
            minimumPressDuration: TimeInterval,
            onLongPress: @escaping () -> Void
        ) {
            self.tabIndex = tabIndex
            self.minimumPressDuration = minimumPressDuration
            self.onLongPress = onLongPress
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func loadView() {
            let v = UIView(frame: .zero)
            v.isUserInteractionEnabled = false
            v.backgroundColor = .clear
            view = v
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfNeeded()
            // Belt-and-braces: retry once after the runloop tick
            // in case the tab bar is added asynchronously after
            // viewDidAppear (rare but observed under split-view
            // transitions and accessibility-resize animations).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.installIfNeeded()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard let window = view.window else { return }
            guard let tabBar = Self.findTabBar(in: window) else { return }
            let buttons = tabBar.subviews
                .filter { String(describing: type(of: $0)).contains("Button") }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard tabIndex >= 0, tabIndex < buttons.count else { return }
            let target = buttons[tabIndex]
            if installedOn === target { return }
            let recognizer = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            recognizer.minimumPressDuration = minimumPressDuration
            // Normal tap-to-switch-tab behaviour must keep working
            // alongside the long-press. `cancelsTouchesInView = false`
            // and `delaysTouches*` = false preserve the standard
            // UITabBar tap handling.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            target.addGestureRecognizer(recognizer)
            installedOn = target
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            // Fire once at `.began` — the canonical UIKit state
            // for "the user has held long enough; show the menu."
            // Subsequent `.changed` / `.ended` are ignored.
            guard gesture.state == .began else { return }
            onLongPress()
        }

        /// Depth-first traversal for a `UITabBar` in a view tree.
        /// Returns the first one found — Aperture's `MainTabView`
        /// hosts exactly one.
        private static func findTabBar(in view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar { return bar }
            for sub in view.subviews {
                if let found = findTabBar(in: sub) { return found }
            }
            return nil
        }
    }
}
