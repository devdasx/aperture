import SwiftUI
import Observation
import UIKit

/// Drives the full-screen Reset Aperture flow, which is presented at the APP
/// ROOT (above `RootGate`), NOT from the Settings tab. Presenting it at the
/// root is what lets the erasing→factory-fresh morph survive the wipe: once the
/// wipe empties the wallets, `RootGate` replaces `MainTabView` with onboarding
/// underneath, but this root-level cover stays on top showing the morph until
/// the user taps "Get Started" — which dismisses it onto the fresh onboarding.
@MainActor
@Observable
final class ResetFlowGate {
    static let shared = ResetFlowGate()
    private init() {}
    var isPresenting = false
}

/// **Reset Aperture — the full-screen factory-reset flow** (`design_handoff_reset`,
/// rebuilt to match the HTML reference 1:1).
///
/// Three gates in a mandatory order — nothing is deleted until every one passes:
/// Warning → Confirm (type RESET + Face ID/PIN when configured) →
/// Erasing→Factory-fresh (one morphing screen). The wipe is the shared
/// `FactoryReset.performStagedWipe`, reported stage-by-stage so the ring is
/// honest; the iris seal appears only after the wipe truly completes.
///
/// Visual contract (handoff): centered hero screens, native NavigationStack
/// pushes between gates, **leading glyphs** on reset lists, text-only action
/// buttons, and the muted brick red `UniColors.Reset.danger` (`#E0483D` /
/// `#FF5B51`) as the ONLY accent.
struct ResetApertureFlow: View {
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Route: Hashable {
        case confirm
        case erasing
    }
    @State private var path: [Route] = []

    @State private var typed = ""
    private let confirmWord = "RESET"
    private var typedMatches: Bool { typed == confirmWord }
    @State private var didFireTypedHaptic = false
    @State private var isShowingPinGate = false
    @State private var pinGateAutoPromptBiometrics = true
    /// Defers the PIN cover until the keyboard has fully retracted.
    @State private var pinGateTask: Task<Void, Never>?

    @State private var confirmFocused = false
    /// Prevents SwiftUI `.task` re-entry from starting a second wipe while
    /// the first is still in flight (nested GRDB writes reenter fatally).
    @State private var isWiping = false

    // MARK: - Tokens (handoff-exact)

    private let hPad: CGFloat = 26
    private let danger = UniColors.Reset.danger
    private static let visibleProcessStages: [FactoryReset.Stage] = [
        .wallets,
        .privateData,
        .keys,
        .security
    ]

    var body: some View {
        NavigationStack(path: $path) {
            routedScreen(warningScreen)
                .navigationDestination(for: Route.self) { route in
                    routedScreen(destination(for: route))
                }
        }
        // The reset's final gate is the app's UNIFIED lock screen — auto Face
        // ID (when the user enabled biometrics) with the PIN keypad fallback,
        // not a raw LAContext prompt. Presented after the user types RESET.
        .sheet(isPresented: $isShowingPinGate) {
            SensitiveAuthPasscodeSheet(
                accessContext: .resetAperture,
                autoPromptBiometrics: pinGateAutoPromptBiometrics,
                allowsBiometrics: true,
                onComplete: {
                    isShowingPinGate = false
                    push(.erasing)
                },
                onCancel: { isShowingPinGate = false }
            )
        }
    }

    private func push(_ route: Route) {
        guard path.last != route else { return }
        path.append(route)
    }

    @ViewBuilder
    private func routedScreen<V: View>(_ view: V) -> some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()
            view
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .confirm:
            confirmScreen
        case .erasing:
            erasingScreen
        }
    }

    // MARK: - 1 · Warning

    private var warningScreen: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(spacing: UniSpacing.mPlus) {
                        heroGlyph("trash", tint: danger)
                        bigTitle("Reset Aperture", centered: true)
                        subtitle("Resetting removes wallets, keys, balances, and private activity from this device.", centered: true)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: UniSpacing.s, trailing: 0))
                }
                resetImpactSection
            }
            .uniListPageChrome()

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    dangerButton("Continue") { push(.confirm) }
                    ghostButton("Cancel") { close() }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, UniSpacing.l)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            resetLeading(.close) { close() }
        }
    }

    private var resetImpactSection: some View {
        // Same grouped-card fill as Settings sections (`List.rowBackground`),
        // not the system inset-grouped default — that drifts off Midnight
        // cards and looks blacker than the rest of the app.
        Section {
            resetImpactRow("creditcard", "Wallets", "Every wallet you’ve created, imported, or are watching.")
            resetImpactRow("key", "Keys & Recovery Phrases", "Permanently removed from this device’s local database.")
            resetImpactRow("clock.arrow.circlepath", "Transactions & Balances", "Your wallet history, contacts, cached balances, and portfolio snapshots.")
        }
    }

    private func resetImpactRow(_ symbol: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(UniColors.Text.primary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(UniColors.Text.primary)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .uniListRowSurface()
    }

    // MARK: - 2 · Confirm (type RESET + Face ID)

    private var confirmScreen: some View {
        screenScaffold(
            title: "Reset Aperture", leading: .none,
            footer: {
                dangerButton("Erase Aperture", isEnabled: typedMatches) {
                    confirmAndAuthenticate()
                }
                ghostButton("Cancel") { close() }
            }
        ) {
            VStack(spacing: UniSpacing.mPlus) {
                heroGlyph("trash", tint: danger)
                bigTitle("One last step", centered: true)
                // P2-029: factory reset is local device only — iCloud backups remain.
                subtitle("Typing the word below confirms the reset. This erases wallets, keys, and settings on this iPhone. iCloud backups on this Apple ID are not deleted and can still restore a wallet.", centered: true)
                VStack(spacing: 10) {
                    // Localized format string; confirmation word stays fixed Latin
                    // (must match what the user types, e.g. "RESET").
                    Text(verbatim: String(
                        format: String.apertureLocalized("Type %@ to continue"),
                        confirmWord
                    ))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UniColors.Text.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
                            .fill(UniColors.Input.background)
                        RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
                            .strokeBorder(danger, lineWidth: 2)
                        ResetConfirmationTextField(
                            text: $typed,
                            isFocused: $confirmFocused,
                            tint: danger
                        )
                            .padding(.horizontal, UniSpacing.mPlus)
                            .onChange(of: typed) { _, newValue in
                                let normalized = Self.normalizedResetConfirmation(newValue)
                                if normalized != newValue {
                                    typed = normalized
                                    return
                                }
                                if normalized == confirmWord, !didFireTypedHaptic {
                                    didFireTypedHaptic = true
                                    UniHapticEngine.shared.play(.success)
                                } else if normalized != confirmWord {
                                    didFireTypedHaptic = false
                                }
                            }
                    }
                    .frame(height: UniSpacing.xxxl)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .onAppear { confirmFocused = true }
        }
    }

    /// Tapping "Erase Aperture" routes through the app's UNIFIED lock screen
    /// (`PinCodeView(.verify)`, which auto-presents Face ID when the user has
    /// enabled biometrics and otherwise shows the PIN keypad) — NOT a raw
    /// `LAContext` Face ID prompt. When no PIN is set there is nothing to
    /// verify, so typed RESET is the deliberate final gate and we proceed.
    private func confirmAndAuthenticate() {
        guard typedMatches else { return }
        guard PinCodeStorage.hasPin else {
            // No PIN to verify → the typed RESET gate is enough. Drop the
            // keyboard and go straight to the wipe.
            confirmFocused = false
            push(.erasing)
            return
        }
        // Dismiss keyboard, then biometric-first; passcode sheet only if needed.
        confirmFocused = false
        pinGateTask?.cancel()
        pinGateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let gate = await SensitiveActionAuth.gatePreferringBiometric()
            switch gate {
            case .authorized:
                push(.erasing)
            case .presentPasscode(let autoPrompt):
                pinGateAutoPromptBiometrics = autoPrompt
                isShowingPinGate = true
            }
        }
    }

    private static func normalizedResetConfirmation(_ value: String) -> String {
        value.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - 3 · Erasing — unified ProcessLyricsScreen (same as create wallet)

    /// Factory-reset process — same `ProcessLyricsScreen` as wallet setup.
    private var erasingScreen: some View {
        ProcessLyricsScreen(
            configuration: .factoryReset,
            perform: { report in
                try await runWipeReporting(report)
            },
            onPrimary: {
                close()
            },
            mapFailureMessage: { _ in
                String.apertureLocalized("Couldn’t erase Aperture. Nothing was removed — your wallets, keys, and settings are untouched. Try again.")
            }
        )
        .navigationBarBackButtonHidden(true)
    }

    /// Drive the handoff process screen from the real staged wipe (4 segments).
    private func runWipeReporting(
        _ report: @escaping @MainActor (Int, Double) async -> Void
    ) async throws {
        guard !isWiping else { return }
        isWiping = true
        defer { isWiping = false }

        func lyricIndex(for stage: FactoryReset.Stage) -> Int? {
            switch stage {
            case .wallets: return 0
            case .privateData: return 1
            case .keys: return 2
            case .security: return 3
            case .networkCache, .settings: return nil
            }
        }

        try await FactoryReset.performStagedWipe(database: AppDatabase.shared) { stage in
            if let index = lyricIndex(for: stage) {
                let fraction = Double(index + 1) / 4.0
                await report(index, fraction)
            }
        }
        await report(3, 1.0)
    }

    private func close() {
        onClose()
    }

    // MARK: - Shared scaffold + components

    private enum NavLeading { case close, none }

    /// Root close control. Pushed reset screens use the system NavigationStack
    /// back button and edge-swipe gesture.
    @ToolbarContentBuilder
    private func resetLeading(_ leading: NavLeading, onTap: @escaping () -> Void) -> some ToolbarContent {
        if leading == .close {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    UniHapticEngine.shared.play(.contextualImpact(.whisper))
                    onTap()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .regular))
                }
                .accessibilityLabel(Text("Close"))
            }
        }
    }

    @ViewBuilder
    private func screenScaffold<C: View, F: View>(
        title: LocalizedStringKey,
        leading: NavLeading,
        onLeading: @escaping () -> Void = {},
        centered: Bool = true,
        @ViewBuilder footer: () -> F,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                content()
                    .padding(.horizontal, hPad)
                    .padding(.top, UniSpacing.s)
                    .padding(.bottom, UniSpacing.xl)
                    .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            }
            .scrollIndicators(.hidden)
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) { footer() }
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, UniSpacing.l)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { resetLeading(leading, onTap: onLeading) }
    }

    private func heroGlyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 50, weight: .light))
            .foregroundStyle(tint)
            .frame(height: 62)
            .padding(.top, UniSpacing.s)
            .accessibilityHidden(true)
    }

    private func bigTitle(_ text: LocalizedStringKey, centered: Bool) -> some View {
        Text(text)
            .font(.system(size: 27, weight: .bold))
            .tracking(-0.6)
            .foregroundStyle(UniColors.Text.primary)
            .multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .padding(.top, centered ? 0 : UniSpacing.xs)
    }

    private func subtitle(_ text: LocalizedStringKey, centered: Bool) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(UniColors.Text.secondary)
            .multilineTextAlignment(centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: centered ? 330 : .infinity, alignment: centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func subtitleVerbatim(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(UniColors.Text.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 330)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Buttons (unified Liquid Glass — UniButton)

    /// Destructive CTA — glass-prominent, tinted to the reset's exact red.
    private func dangerButton(_ title: LocalizedStringKey, isEnabled: Bool = true, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        UniButton(title: title, variant: .destructive, isLoading: isLoading, isEnabled: isEnabled, tint: UniColors.Reset.danger, action: action)
    }

    /// Primary (non-destructive) CTA — glass-prominent, accent tint.
    private func primaryButton(_ title: LocalizedStringKey, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        UniButton(title: title, variant: .primary, isEnabled: isEnabled, action: action)
    }

    /// Secondary CTA — the unified `.glass` button (no longer bare text).
    private func ghostButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        UniButton(title: title, variant: .secondary, action: action)
    }
}

// MARK: - Reset confirmation input

/// UIKit-backed field for the destructive RESET confirmation. SwiftUI can ask
/// for `.characters` capitalization, but it cannot pin the keyboard language;
/// this field forces an English text input mode when one exists and normalizes
/// every typed or pasted value to uppercase.
private struct ResetConfirmationTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let tint: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EnglishUppercaseUITextField {
        let field = EnglishUppercaseUITextField(frame: .zero)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.smartQuotesType = .no
        field.textContentType = nil
        field.returnKeyType = .done
        field.textAlignment = .center
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.adjustsFontForContentSizeCategory = false
        field.accessibilityLabel = String.apertureLocalized("Type RESET to continue")
        return field
    }

    func updateUIView(_ field: EnglishUppercaseUITextField, context: Context) {
        context.coordinator.parent = self
        let normalized = Self.normalized(text)
        let uiTint = UIColor(tint)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        field.defaultTextAttributes = [
            .font: UIFont.monospacedSystemFont(ofSize: 21, weight: .bold),
            .foregroundColor: uiTint,
            .kern: 4,
            .paragraphStyle: paragraphStyle
        ]
        field.tintColor = uiTint
        field.textColor = uiTint
        field.font = .monospacedSystemFont(ofSize: 21, weight: .bold)
        field.textAlignment = .center
        field.contentHorizontalAlignment = .center

        if field.text != normalized {
            field.text = normalized
        }
        if text != normalized {
            DispatchQueue.main.async {
                text = normalized
            }
        }

        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard UIApplication.shared.applicationState == .active,
                      field.window != nil,
                      !field.isFirstResponder
                else { return }
                field.becomeFirstResponder()
            }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async {
                field.resignFirstResponder()
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ResetConfirmationTextField

        init(_ parent: ResetConfirmationTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ field: UITextField) {
            let normalized = ResetConfirmationTextField.normalized(field.text ?? "")
            if field.text != normalized {
                field.text = normalized
            }
            if parent.text != normalized {
                parent.text = normalized
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            parent.isFocused = false
            return false
        }
    }
}

private final class EnglishUppercaseUITextField: UITextField {
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes {
            guard let language = mode.primaryLanguage?.lowercased() else { continue }
            if language == "en" || language.hasPrefix("en-") {
                return mode
            }
        }
        return super.textInputMode
    }
}
