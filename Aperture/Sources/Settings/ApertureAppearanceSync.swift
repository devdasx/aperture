import SwiftUI
import UIKit

/// App-published appearance used by dynamic `UIColor` providers when the
/// UIKit custom-trait bridge has not delivered `ApertureAppearanceTrait`.
///
/// Midnight and Dark both force `UIUserInterfaceStyle.dark`. The only
/// discriminator is `ApertureAppearanceTrait`. SwiftUI's
/// `UITraitBridgedEnvironmentKey` path does not always reach every
/// `Color(uiColor:)` resolution site (Lists, nav chrome, detached
/// windows). Publishing the preference here keeps Cloud / Midnight /
/// Dark correct even when the trait is still `.system`.
enum ApertureAppearanceResolution: Sendable {
    nonisolated(unsafe) private static var _current: ApertureAppearance = .system
    private static let lock = NSLock()

    nonisolated static var current: ApertureAppearance {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _current
        }
        set {
            lock.lock()
            _current = newValue
            lock.unlock()
        }
    }
}

/// Pushes `ThemePreference` into UIKit trait overrides on every connected
/// window / scene so dynamic palette colors and system chrome share one
/// source of truth.
@MainActor
enum ApertureAppearanceSync {
    static func apply(_ theme: ThemePreference) {
        let appearance = theme.apertureAppearance
        ApertureAppearanceResolution.current = appearance

        let style: UIUserInterfaceStyle
        switch theme {
        case .system: style = .unspecified
        case .cloud: style = .light
        case .midnight, .dark: style = .dark
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.traitOverrides[ApertureAppearanceTrait.self] = appearance
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                window.traitOverrides[ApertureAppearanceTrait.self] = appearance
                if let root = window.rootViewController {
                    apply(appearance: appearance, style: style, to: root)
                }
            }
        }
    }

    static func apply(
        appearance: ApertureAppearance,
        style: UIUserInterfaceStyle,
        to viewController: UIViewController
    ) {
        viewController.traitOverrides[ApertureAppearanceTrait.self] = appearance
        viewController.overrideUserInterfaceStyle = style
        for child in viewController.children {
            apply(appearance: appearance, style: style, to: child)
        }
        if let presented = viewController.presentedViewController {
            apply(appearance: appearance, style: style, to: presented)
        }
    }
}

/// Zero-size host that re-applies appearance traits whenever the user's
/// theme preference changes. Embedded inside `.apertureEnvironment()` so
/// every presentation surface (window, sheet, cover) keeps Midnight vs
/// Dark honest for UIKit-backed colors.
struct ApertureAppearanceTraitBridge: UIViewControllerRepresentable {
    let theme: ThemePreference

    func makeUIViewController(context: Context) -> BridgeController {
        let controller = BridgeController()
        controller.apply(theme)
        return controller
    }

    func updateUIViewController(_ controller: BridgeController, context: Context) {
        controller.apply(theme)
    }

    final class BridgeController: UIViewController {
        private var lastThemeRaw: String?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let raw = lastThemeRaw {
                apply(ThemePreference.stored(raw))
            }
        }

        func apply(_ theme: ThemePreference) {
            let raw = theme.rawValue
            // Always publish resolution + local overrides; only walk the
            // full scene graph when the preference actually changes.
            let appearance = theme.apertureAppearance
            ApertureAppearanceResolution.current = appearance

            let style: UIUserInterfaceStyle
            switch theme {
            case .system: style = .unspecified
            case .cloud: style = .light
            case .midnight, .dark: style = .dark
            }

            traitOverrides[ApertureAppearanceTrait.self] = appearance
            overrideUserInterfaceStyle = style

            if let host = parent {
                host.traitOverrides[ApertureAppearanceTrait.self] = appearance
                host.overrideUserInterfaceStyle = style
            }
            if let window = view.window {
                window.overrideUserInterfaceStyle = style
                window.traitOverrides[ApertureAppearanceTrait.self] = appearance
                if let root = window.rootViewController {
                    root.traitOverrides[ApertureAppearanceTrait.self] = appearance
                    root.overrideUserInterfaceStyle = style
                }
            }

            if lastThemeRaw != raw {
                lastThemeRaw = raw
                ApertureAppearanceSync.apply(theme)
            }
        }
    }
}
