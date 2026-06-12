import SwiftUI

/// Canonical Toggle wrapper. Fires the `.toggle` haptic on every
/// state flip — the design handoff's "Flip a switch" moment.
///
/// **Why a wrapper.** Native SwiftUI `Toggle` doesn't fire a haptic.
/// Per the 2026-06-10 design handoff every state change needs a
/// tactile beat (`Rigid impact` weight). Rather than ask every
/// settings file to remember `.uniHaptic(.toggle, trigger: state)`
/// after each `Toggle`, we ship the wrapper once. The haptic is
/// automatically gated by the `hapticFeedbackEnabled` preference,
/// read at fire time inside `UniHapticModifier` (never via
/// `@AppStorage` — see that modifier's doc for the 2026-06-13
/// navigation-pop rationale).
///
/// **Usage.**
/// ```swift
/// UniToggle(isOn: $backgroundRefresh) {
///     Label("Background refresh", systemImage: "arrow.clockwise")
/// }
/// ```
///
/// **Rule #10 (haptic vocabulary).** This wrapper is the ONLY way
/// to ship a Toggle in feature code. Raw `Toggle(isOn:)` is
/// forbidden outside this file and outside the DesignSystem layer.
struct UniToggle<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder let label: () -> Label

    /// Guards against the haptic firing for the *initial* /
    /// programmatic `isOn` settle that happens while the view is
    /// appearing (e.g. a stored preference loading into the binding).
    /// Only changes that land after `onAppear` bump `hapticTrigger`,
    /// and only `hapticTrigger` drives the haptic — so the toggle
    /// buzzes when the user flips it, not when state restoration does.
    @State private var hasAppeared = false
    @State private var hapticTrigger = 0

    init(isOn: Binding<Bool>, @ViewBuilder label: @escaping () -> Label) {
        self._isOn = isOn
        self.label = label
    }

    var body: some View {
        Toggle(isOn: $isOn, label: label)
            .uniHaptic(.toggle, trigger: hapticTrigger)
            .onChange(of: isOn) { _, _ in
                guard hasAppeared else { return }
                hapticTrigger &+= 1
            }
            .onAppear { hasAppeared = true }
    }
}

// MARK: - Convenience initializer (LocalizedStringKey title)

extension UniToggle where Label == Text {
    /// Convenience for the most common shape: a `LocalizedStringKey`
    /// title and no leading SF Symbol. Mirrors `Toggle("Title",
    /// isOn:)` so call sites stay terse.
    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}
