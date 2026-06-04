import SwiftUI

/// Ten-beat onboarding sequence. The user moves between beats by swiping the
/// system pager (`TabView` + `.tabViewStyle(.page)`). No custom animations,
/// no Skip, no Continue — only the swipe gesture itself and the two real
/// CTAs that now live on **every** slide.
///
/// Per the user's screenshot review on 2026-06-04, the CTAs (`Create new
/// wallet` / `I already have a wallet`) and the legal footer (`Terms` /
/// `Privacy`) are no longer gated behind the final slide. They appear
/// beneath every beat so the user can commit at any moment without
/// swiping through to the end. The two CTAs share one `GlassEffectContainer`
/// so they read as a single merged glass region (Rule #2 §B.3 — max two
/// glass layers per region).
///
/// Because the action region is now always present, the slide pager
/// absorbs the spare vertical space via `.frame(maxHeight: .infinity)` —
/// the hero illustration stays vertically centered in its column and the
/// composition doesn't reflow as the user swipes.
///
/// **App-bar gear** (trailing) opens Settings as a system `.sheet(...)`
/// with `.presentationDetents([.medium, .large])`. This is the only piece
/// of accessibility chrome on onboarding — Language and Appearance live
/// behind it. The gear is rendered with `.buttonStyle(.glass)` so it
/// reads as functional Liquid Glass chrome, distinct from the opaque
/// content layer of the slides (Rule #2 §B.3).
struct OnboardingView: View {
    @State private var currentIndex: Int = 0
    @State private var isShowingSettings: Bool = false
    /// Hoisted Settings navigation path. Lives here (not inside
    /// `SettingsView`) so a sheet-content rebuild on direction flip
    /// preserves the path — the rebuilt `NavigationStack` reconstructs
    /// the same pushed picker the user was on. Reset on sheet dismiss.
    @State private var settingsPath: NavigationPath = .init()

    // MARK: - Create-wallet flow state (T-002 steps 1 & 3)

    /// Toggles the risk-disclosure sheet (`CreateWalletDisclosureSheet`).
    @State private var isShowingCreateDisclosure: Bool = false
    /// Toggles the full-screen cover hosting the `RecoveryPhraseFlow`.
    @State private var isShowingRecoveryFlow: Bool = false
    /// Hoisted navigation path for the recovery-phrase flow. Hoisted for
    /// the same reason as `settingsPath`: any `.id`-driven rebuild on the
    /// cover's content (LTR/RTL flip) must preserve the path so the user
    /// stays where they were. Reset on cover dismiss.
    @State private var recoveryPath: NavigationPath = .init()

    /// Persists whether the user finished the create-wallet flow without
    /// backing up the recovery phrase. Surfaced later as a Settings row
    /// ("Back up your recovery phrase") — tracked as `T-016`. Default
    /// `false` for fresh installs.
    @AppStorage("hasUnbackedupWallet") private var hasUnbackedupWallet: Bool = false

    // Rule #12 Part G: the sheet's content is `.id`-keyed to **only the
    // layout direction**, not the full preferences. iOS locks the sheet
    // `UIHostingController`'s `semanticContentAttribute` at presentation
    // time, so a mid-flight `\.layoutDirection` flip (LTR ↔ RTL) needs a
    // content rebuild to render correctly. Theme changes (light/dark) and
    // same-direction language changes (en → es, ar → fa) do NOT need a
    // rebuild — they propagate cleanly through `.uniAppEnvironment()` and
    // preserve any pushed-picker navigation state. Using a full-preferences
    // key here would otherwise pop the user out of every sub-picker on
    // every preference change.
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    private let slides = OnboardingSlide.all

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.xs)

                slidePager
                    .frame(maxHeight: .infinity)

                bottomStack
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.bottom, UniSpacing.l)
            }
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: {
            // Reset the Settings navigation path when the sheet closes,
            // so the next presentation starts at Settings root rather
            // than wherever the user last navigated.
            settingsPath = NavigationPath()
        }) {
            // Rule #12 Parts F–H: the sheet content is keyed ONLY to the
            // layout direction (`rtl` / `ltr`), so the content tree is
            // rebuilt **only** when crossing direction boundaries.
            // `settingsPath` is hoisted to *this* view's `@State` so the
            // path survives that rebuild — the rebuilt `NavigationStack`
            // re-pushes the same picker the user was on, no bounce-back
            // to Settings root.
            SettingsView(navigationPath: $settingsPath)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Step 1 of the "Create new wallet" flow (T-002): risk disclosure
        // sheet. Acceptance dismisses this sheet, waits for its system
        // dismiss animation to settle, then opens the recovery-phrase
        // full-screen cover so the two presentations don't fight on
        // screen at once.
        .sheet(isPresented: $isShowingCreateDisclosure) {
            CreateWalletDisclosureSheet(
                onAccept: handleDisclosureAccept,
                onCancel: { isShowingCreateDisclosure = false }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Step 3 of the "Create new wallet" flow (T-002): recovery-phrase
        // display, with its own NavigationStack and an internal skip-
        // warning sheet. Cover dismissal also resets the hoisted path.
        .fullScreenCover(isPresented: $isShowingRecoveryFlow, onDismiss: {
            recoveryPath = NavigationPath()
        }) {
            RecoveryPhraseFlow(
                navigationPath: $recoveryPath,
                onDismiss: { isShowingRecoveryFlow = false },
                onUserSkippedBackup: { hasUnbackedupWallet = true },
                onUserCompletedBackup: { hasUnbackedupWallet = false }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
        }
    }

    // MARK: - Create-wallet flow handlers

    /// Disclosure → recovery phrase handoff. SwiftUI dislikes presenting a
    /// `fullScreenCover` while a `.sheet` is still animating out — the two
    /// presentation animations stack and the recovery flow can appear in
    /// front of the sheet's residual chrome. We dismiss the sheet first,
    /// then schedule the cover for the next runloop tick after the system
    /// dismiss animation completes (~0.35 s on iOS 26 for a `.large`
    /// detent). The delay is the smallest reliable fallback for
    /// `.sheet(onDismiss:)` not firing until much later in some edge
    /// cases.
    private func handleDisclosureAccept() {
        isShowingCreateDisclosure = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            isShowingRecoveryFlow = true
        }
    }

    // MARK: - Top bar (persistent chrome)

    /// Brand iris mark left (the aperture diaphragm — the literal visual
    /// rendering of the product name), settings gear right. Skip is
    /// intentionally absent — the user navigates by swiping. The gear is
    /// the only affordance for accessibility surfaces (Language /
    /// Appearance). The mark is shipped as a template SVG and tinted via
    /// `UniColors.Tint.accent` so it adapts to light/dark appearance for
    /// free.
    private var topBar: some View {
        HStack {
            Image("mark-aperture")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(UniColors.Tint.accent)
                .accessibilityLabel(Text("Aperture"))
            Spacer()
            settingsButton
        }
        .frame(height: 44)
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text("Open Settings"))
    }

    // MARK: - Slide pager (system page indicator, native swipe)

    private var slidePager: some View {
        TabView(selection: $currentIndex) {
            ForEach(slides) { slide in
                OnboardingSlideView(slide: slide, isActive: slide.id == currentIndex)
                    .tag(slide.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }

    // MARK: - Bottom stack (action region + legal footer — present on every slide)

    /// The CTA pair plus the legal footer. Previously gated behind the final
    /// slide; now persistent so the user can commit at any beat. See
    /// `MISTAKES.md` discussion and the corresponding `SHIPPED.md` entry.
    private var bottomStack: some View {
        VStack(spacing: UniSpacing.l) {
            actionRegion
            legalFooter
        }
    }

    // MARK: - Action region

    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            VStack(spacing: UniSpacing.s) {
                UniButton(title: "Create new wallet", variant: .primary) {
                    // T-002 steps 1-4 (disclosure → real-BIP-39 phrase →
                    // verify → wallet-ready placeholder) are wired here.
                    // Biometric setup (T-012), real wallet home (T-018),
                    // and passphrase persistence (T-019) still pending.
                    isShowingCreateDisclosure = true
                }

                UniButton(title: "I already have a wallet", variant: .secondary) {
                    // TODO: (T-003) navigate to "Import wallet" flow (seed phrase / private key / iCloud encrypted backup)
                }
            }
        }
    }

    // MARK: - Legal footer

    private var legalFooter: some View {
        HStack(spacing: UniSpacing.xxs) {
            UniCaption(text: "By continuing, you agree to our")

            Button {
                // TODO: (T-004) present Terms of Service
            } label: {
                UniCaption(text: "Terms", color: UniColors.Text.secondary)
            }
            .buttonStyle(.plain)

            UniCaption(text: "and")

            Button {
                // TODO: (T-005) present Privacy Policy
            } label: {
                UniCaption(text: "Privacy", color: UniColors.Text.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    OnboardingView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    OnboardingView()
        .preferredColorScheme(.dark)
}
