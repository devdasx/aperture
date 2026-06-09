import SwiftUI
import UIKit

/// A zero-size `UIViewRepresentable` placeholder that, on its next
/// layout pass, walks up to its window's view hierarchy, finds the
/// hosting `UITabBar`, filters its subviews for `UITabBarButton`
/// instances (via the documented `String(describing: type(of: …))
/// .contains("Button")` pattern — `UITabBarButton` is a private class
/// so we identify by class-name string), sorts them by
/// `frame.minX` to mirror the visible tab order, and attaches a
/// `UILongPressGestureRecognizer` to the button at `tabIndex`.
///
/// **Why this exists (M-016 follow-on).** SwiftUI's iOS 26 `Tab` is
/// rendered by UIKit's `UITabBar` and the SwiftUI ↔ UIKit bridge
/// silently drops `.contextMenu` modifiers on tab bar items —
/// neither outside the Tab nor inside the `label:` closure makes
/// the menu fire. Apple Mail's tab-bar account switcher uses
/// UIKit-level APIs (`UITabBarItem.contextMenu`,
/// `UITabBarControllerDelegate.tabBarController(_:contextMenuConfigurationForItemAt:)`)
/// that SwiftUI doesn't expose. The only viable path that preserves
/// the four-tab `TabView` shell AND delivers the Telegram /
/// Instagram long-press pattern on the bottom bar is this one:
/// reach into the `UITabBar`'s subviews ourselves and attach a
/// recognizer.
///
/// **Robustness:** the installer is idempotent — `Coordinator.
/// installedOn` holds a `weak` reference to the button it already
/// wired, so repeated `updateUIView` passes don't stack recognizers.
/// When iOS regenerates the tab bar buttons (e.g. on rotation or
/// dynamic-type resize), the weak reference clears and the next
/// update re-attaches to the fresh button. Cancels-touches-in-view
/// is `false` so the recognizer doesn't interfere with the normal
/// tap-to-switch-tab behaviour.
///
/// **Rule #3 (native-only):** pure `UIKit` + `UIViewRepresentable`.
/// No third-party `siteline/swiftui-introspect` or similar — we
/// roll the introspection ourselves.
///
/// **Usage:** place inside the tab's root content view tree with a
/// `.frame(width: 0, height: 0)` modifier so it doesn't occupy
/// layout space; pass the tab's zero-based index and the closure
/// that fires on `.began`. The closure typically flips a
/// `@State Bool` that drives a `.sheet(isPresented:)`.
struct TabBarLongPressInstaller: UIViewRepresentable {
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.minimumPressDuration = minimumPressDuration
        // Defer to the next runloop tick — the tab bar may not yet
        // be in the window's view hierarchy when SwiftUI first
        // composes the tab's content view. The async hop also lets
        // SwiftUI finish its current layout pass before we mutate
        // the UIKit tree.
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            Self.installIfNeeded(
                anchor: uiView,
                tabIndex: tabIndex,
                coordinator: coordinator
            )
        }
    }

    // MARK: - Discovery + attachment

    private static func installIfNeeded(
        anchor: UIView,
        tabIndex: Int,
        coordinator: Coordinator
    ) {
        guard let window = anchor.window else { return }
        guard let tabBar = findTabBar(in: window) else { return }
        let buttons = tabBar.subviews
            .filter { String(describing: type(of: $0)).contains("Button") }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard tabIndex >= 0, tabIndex < buttons.count else { return }
        let target = buttons[tabIndex]
        // Idempotency: if we've already wired this exact UIView,
        // bail out. The recognizer's weak target reference means a
        // recreated tab bar button automatically loses our
        // attachment and triggers re-installation on the next pass.
        if coordinator.installedOn === target { return }
        let recognizer = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        recognizer.minimumPressDuration = coordinator.minimumPressDuration
        // The user's tap still routes to UITabBar's own selection
        // handling — we just observe long-presses in parallel.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        target.addGestureRecognizer(recognizer)
        coordinator.installedOn = target
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

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        weak var installedOn: UIView?
        var minimumPressDuration: TimeInterval = 0.4
        let onLongPress: () -> Void

        init(onLongPress: @escaping () -> Void) {
            self.onLongPress = onLongPress
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            // Fire once at the moment the long-press registers —
            // `.began` is the canonical UIKit state for "the user
            // has held long enough; show the menu." Subsequent
            // states (`.changed`, `.ended`) are ignored.
            guard gesture.state == .began else { return }
            onLongPress()
        }
    }
}
