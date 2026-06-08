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
///
/// **2026-06-07 splash → onboarding shared element.** `AppRoot` owns the
/// `@Namespace logoNamespace` and the `AppPhase` machine, and threads
/// both into this view. The welcome slide carries the
/// `matchedGeometryEffect` destination for the splash logo (id `"logo"`),
/// and every other onboarding chrome element — gear, headline, body,
/// open-source badge, page dots, primary/secondary CTAs, legal footer —
/// fades + drops 16pt as the phase advances out of `.splash`, staggered
/// per the design handoff (`design_handoff_splash_to_onboarding/README.md`).
/// The logo itself is excluded from the fade (it owns the matched-geometry
/// motion).
struct OnboardingView: View {
    @State private var currentIndex: Int = 0
    @State private var isShowingSettings: Bool = false
    /// Toggles the `OpenSourceSheet`. Presented from the welcome slide's
    /// restrained "Open source" badge — the first security-touching
    /// anchor a user sees per session (Rule #16 §A.4 / §C).
    @State private var isShowingOpenSource: Bool = false
    /// Hoisted Settings navigation path. Lives here (not inside
    /// Hoisted Settings navigation path so the sheet's content rebuild
    /// on an RTL/LTR direction flip preserves the user's current picker
    /// destination (Rule #12 §G).
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

    /// Toggles the full-screen cover hosting the `ImportWalletFlow`.
    @State private var isShowingImportFlow: Bool = false
    /// Hoisted navigation path for the import-wallet flow (Rule #12 §G).
    @State private var importPath: NavigationPath = .init()

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

    /// Logo namespace owned by `AppRoot`. Wired through to the welcome
    /// slide's hero so `matchedGeometryEffect` can claim the logo as the
    /// splash → onboarding shared element.
    let logoNamespace: Namespace.ID
    /// The 3-phase machine from `AppRoot`. Drives every non-logo
    /// onboarding element's staggered fade-in once the splash starts
    /// dissolving.
    let phase: AppPhase

    /// `true` once the splash has begun dissolving — drives the fade-in
    /// of every onboarding chrome element. The logo itself is gated
    /// inside `WordmarkIllustration` via `matchedGeometryEffect`, NOT
    /// via this flag.
    private var contentVisible: Bool { phase != .splash }

    var body: some View {
        NavigationStack {
            ZStack {
                UniColors.Background.primary.ignoresSafeArea()

                VStack(spacing: 0) {
                    slidePager
                        .frame(maxHeight: .infinity)

                    pageDots
                        .padding(.bottom, UniSpacing.m)
                        .modifier(OnboardingStaggeredFadeIn(
                            visible: contentVisible,
                            delay: 0.30
                        ))

                    bottomStack
                        .padding(.horizontal, UniSpacing.l)
                        .padding(.bottom, UniSpacing.l)
                }
            }
            // Match the wallet-home pattern exactly: the settings gear
            // lives inside a system `.toolbar { ToolbarItem(.topBarLeading) }`
            // so iOS 26 renders it inside the native Liquid Glass nav
            // bar — same chrome, same blur-on-scroll, same RTL flip,
            // same accessibility. Per M-002/M-003 the symbol is bare
            // `gearshape` (no `.circle` variant, no `.buttonStyle(.glass)`
            // wrapper) — the nav bar IS the Liquid Glass surface; a
            // glass wrapper would produce double-chrome.
            //
            // Empty `.navigationTitle("")` + `.inline` display mode
            // keeps the nav bar minimal (matches wallet-home which also
            // uses no title — the screen's hero IS the title).
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .regular))
                            .modifier(OnboardingStaggeredFadeIn(
                                visible: contentVisible,
                                delay: 0.04
                            ))
                    }
                    .accessibilityLabel(Text("Settings"))
                }
            }
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: {
            settingsPath = NavigationPath()
        }) {
            // Rule #12 Parts F–H: sheet content keyed to layout
            // direction so an RTL/LTR flip rebuilds the tree.
            // `settingsPath` is hoisted to *this* view so the path
            // survives that rebuild — the rebuilt NavigationStack
            // re-pushes the same picker the user was on.
            // Pre-wallet Settings — slim variant carrying only the
            // rows that make sense before any wallet exists
            // (Language, Appearance, Currency, Haptic, Help, About,
            // Acknowledgments). The post-wallet sections (Wallets,
            // Security, Privacy, Hide-balance toggles, Advanced) are
            // only reachable from the wallet home's `SettingsView`.
            OnboardingSettingsView(navigationPath: $settingsPath)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
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
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
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
            // Tell iOS to paint the grouped-page color UNDER the
            // cover's host view. Without this, the cover's default
            // `systemBackground` (white) paints behind the
            // NavigationStack and bleeds through anywhere the inner
            // `.background()` doesn't reach (the safe-area top, the
            // gaps around the seed-phrase grid). The 2026-06-07
            // color flip exposed this: pre-flip every layer was
            // approximately white so the bleed was invisible. Same
            // treatment as `.sheet(...)` callers that use
            // `.presentationBackground(...)` to opt out of the
            // host-default white.
            .presentationBackground(UniColors.Background.primary)
        }
        // Sibling cover for the Import Wallet flow (T-003). Mirrors the
        // create-wallet pattern: hoisted NavigationPath, .id key on
        // layout direction, .uniAppEnvironment for theme/locale, cover
        // dismissed via `onDismiss`.
        .fullScreenCover(isPresented: $isShowingImportFlow, onDismiss: {
            importPath = NavigationPath()
        }) {
            ImportWalletFlow(
                navigationPath: $importPath,
                onDismiss: { isShowingImportFlow = false },
                onCompleted: { _ in
                    // Wallet imported — clear the no-wallet flag and
                    // dismiss. Future T-018 wallet-home surfaces will
                    // observe the persisted state and route here.
                    hasUnbackedupWallet = false
                    isShowingImportFlow = false
                }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            // Same host-level backing as the recovery cover above —
            // see that block for the why.
            .presentationBackground(UniColors.Background.primary)
        }
        // Rule #16 §C — the open-source verification anchor. Presented
        // from the welcome slide's badge (and reusable from any future
        // custody surface). Per Rule #12 §G the content is `.id`-keyed
        // to layout direction so an LTR ↔ RTL flip rebuilds the host;
        // `.uniAppEnvironment()` re-applies theme/locale; opaque-white
        // background per Rule #15.
        .sheet(isPresented: $isShowingOpenSource) {
            OpenSourceSheet()
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
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

    // MARK: - Slide pager (custom dots, native swipe)

    /// The page dots ship as system chrome by default
    /// (`indexDisplayMode: .always`). We hide them and render our own
    /// row below so the dots can fade in on their own delay (0.30s) per
    /// the splash → onboarding design handoff, independent of the
    /// TabView's content — which carries the matchedGeometryEffect
    /// logo destination and therefore can't be opacity-gated as a unit.
    private var slidePager: some View {
        TabView(selection: $currentIndex) {
            ForEach(slides) { slide in
                OnboardingSlideView(
                    slide: slide,
                    isActive: slide.id == currentIndex,
                    onOpenSourceTap: { isShowingOpenSource = true },
                    logoNamespace: logoNamespace,
                    phase: phase
                )
                .tag(slide.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Custom page-dot row. Matches the iOS-26 system style — 6pt dots
    /// at 8pt spacing, primary tint for the active index, tertiary for
    /// the rest. The active dot uses a `Capsule` 18pt wide so the
    /// current slide is unambiguous; iOS does the same in its first-
    /// party page indicators.
    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(slides) { slide in
                Capsule()
                    .fill(slide.id == currentIndex
                          ? UniColors.Text.primary
                          : UniColors.Text.tertiary.opacity(0.4))
                    .frame(
                        width: slide.id == currentIndex ? 18 : 6,
                        height: 6
                    )
                    .animation(.easeInOut(duration: 0.2), value: currentIndex)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Bottom stack (action region + legal footer — present on every slide)

    /// The CTA pair plus the legal footer. Previously gated behind the final
    /// slide; now persistent so the user can commit at any beat. See
    /// `MISTAKES.md` discussion and the corresponding `SHIPPED.md` entry.
    private var bottomStack: some View {
        VStack(spacing: UniSpacing.l) {
            actionRegion
            legalFooter
                .modifier(OnboardingStaggeredFadeIn(
                    visible: contentVisible,
                    delay: 0.48
                ))
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
                .modifier(OnboardingStaggeredFadeIn(
                    visible: contentVisible,
                    delay: 0.36
                ))

                UniButton(title: "I already have a wallet", variant: .secondary) {
                    isShowingImportFlow = true
                }
                .modifier(OnboardingStaggeredFadeIn(
                    visible: contentVisible,
                    delay: 0.42
                ))
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

// MARK: - Staggered fade-in modifier (shared by OnboardingView and OnboardingSlideView)

/// Per the splash → onboarding design handoff:
/// > Onboarding content fades in with a 16pt rise over 0.5s, eased with
/// > `cubic-bezier(.2,.8,.2,1)`, staggered per element so the screen
/// > settles into place beat by beat instead of slamming in all at once.
///
/// The logo is **excluded** from this modifier — it owns the
/// `matchedGeometryEffect` motion and must be visible the moment the
/// splash starts dissolving so the shared-element transition has a
/// destination to fly into.
struct OnboardingStaggeredFadeIn: ViewModifier {
    let visible: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 16)
            .animation(
                .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5).delay(delay),
                value: visible
            )
    }
}

// MARK: - Previews

#Preview("Light") {
    OnboardingViewPreviewWrapper()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    OnboardingViewPreviewWrapper()
        .preferredColorScheme(.dark)
}

/// Wraps `OnboardingView` for previews — the real call site receives
/// the namespace + phase from `AppRoot`. Previews stand in with a
/// dummy namespace and the post-transition phase so all chrome is
/// visible.
private struct OnboardingViewPreviewWrapper: View {
    @Namespace private var ns
    var body: some View {
        OnboardingView(logoNamespace: ns, phase: .onboarding)
    }
}
