import SwiftUI

/// Wallet-avatar colour customisation. The wallet mark is fixed to
/// Aperture's iris logo; this sheet only stages and saves the disc
/// colour.
///
/// **Why staging, not live commits.** The pre-2026-06-09 picker
/// committed every tap straight through GRDB observation reactivity — a
/// stylistic mistake in retrospect. The user couldn't preview a
/// gradient + glyph combo without writing it; if they didn't like
/// the result they had to walk back. The picker stages every edit
/// in `@State` and lands them only on Save — Apple's iOS Settings →
/// Appearance pattern. The user explores freely; commitment is
/// explicit.
///
/// **Per Rule #15:** `NavigationStack`-rooted, `navigationTitle("Wallet icon")`,
/// `.navigationBarTitleDisplayMode(.inline)`. Cancel sits in
/// `.topBarLeading`; Save lives at the bottom of the content as a
/// `UniButton(.primary)` because it's the commit action (Rule #19).
///
/// **Rule #4 carries no exception here.** Every colour flows through
/// `UniColors.WalletAvatar.gradientStops(for:)` and other named roles.
///
/// **Rule #9 (i18n).** Every string the user reads is a
/// `LocalizedStringKey` or `Text(...)` with a localized key.
struct WalletIconPickerSheet: View {
    let walletId: UUID

    @StateObject private var walletRecordsObservation = WalletRecordsObservation()
    @Environment(\.dismiss) private var dismiss

    // MARK: - Staged spec (commit on Save, discard on Cancel)

    /// The gradient the user is currently previewing.
    @State private var stagedGradient: WalletAvatarGradient = .graphite
    /// Whether the user picked a custom colour via the native colour
    /// picker (2026-06-19) — overrides `stagedGradient` when true.
    @State private var usesCustomColor: Bool = false
    /// The native colour-picker selection. Only meaningful when
    /// `usesCustomColor` is true; seeded from a persisted custom hex.
    @State private var stagedCustomColor: Color = .blue
    /// Whether the staged spec has been initialised from the wallet
    /// record. Guards against re-seeding on every body re-render.
    @State private var didSeed: Bool = false

    private var wallet: WalletRecord? {
        walletRecordsObservation.wallets.first { $0.id == walletId }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if let wallet {
                    content(wallet)
                } else {
                    missing
                }
            }
            .navigationTitle("Wallet icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.tint(UniColors.Button.text)
                }
            }
            .onAppear { seedIfNeeded() }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(_ wallet: WalletRecord) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.xl) {
                    livePreview(wallet)
                    colorSection
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.xl)
            }
            saveBar(wallet)
        }
    }

    // MARK: - Live preview

    /// The 96pt avatar at the top of the sheet. The wallet mark stays
    /// fixed to Aperture's iris; only the colour changes.
    @ViewBuilder
    private func livePreview(_ wallet: WalletRecord) -> some View {
        let customColorAnimationKey = usesCustomColor ? UniColors.WalletAvatar.hex(from: stagedCustomColor) : ""
        VStack(spacing: UniSpacing.s) {
            WalletAvatar(
                spec: stagedSpec(for: wallet),
                size: .editor
            )
            .animation(.smooth(duration: 0.18), value: stagedGradient)
            .animation(.smooth(duration: 0.18), value: usesCustomColor)
            .animation(.smooth(duration: 0.18), value: customColorAnimationKey)

            Text(verbatim: wallet.name)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Colour section

    /// A horizontal scrollable row of 12 gradient swatches, each a
    /// 40pt circle filled with its gradient. The selected swatch
    /// carries a 2pt ink ring offset 4pt outside the swatch — the
    /// classic iOS selection mark, restrained.
    @ViewBuilder
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            sectionLabel("Colour")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UniSpacing.s) {
                    ForEach(WalletAvatarGradient.allCases, id: \.self) { gradient in
                        gradientSwatch(gradient)
                    }
                }
                .padding(.horizontal, 4) // breathing room for the selection ring
                .padding(.vertical, 4)
            }

            // Native colour picker (2026-06-19) — pick any colour beyond
            // the curated presets. Selecting one overrides the preset
            // swatch; tapping a preset above clears it. The trailing tick
            // marks when a custom colour is the active choice.
            ColorPicker(selection: $stagedCustomColor, supportsOpacity: false) {
                HStack(spacing: UniSpacing.s) {
                    Image(systemName: "eyedropper.halffull")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(UniColors.Icon.secondary)
                        .frame(width: 28)
                    Text("Custom colour")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    if usesCustomColor {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(UniColors.Tint.accent)
                    }
                }
            }
            .onChange(of: stagedCustomColor) { _, _ in
                // Any movement of the colour well means the user wants
                // their custom colour (seed assigns before this fires
                // only when a custom hex existed, which is also correct).
                usesCustomColor = true
            }
        }
    }

    @ViewBuilder
    private func gradientSwatch(_ gradient: WalletAvatarGradient) -> some View {
        // A preset is "active" only when no custom colour is in play.
        let isActive = (gradient == stagedGradient) && !usesCustomColor
        Button {
            stagedGradient = gradient
            usesCustomColor = false // picking a preset clears the custom colour
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: UniColors.WalletAvatar.gradientStops(for: gradient),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 40, height: 40)
                Circle()
                    .stroke(
                        isActive ? UniColors.Text.primary : Color.clear,
                        lineWidth: 2
                    )
                    .frame(width: 48, height: 48)
            }
            .frame(width: 52, height: 52, alignment: .center)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: isActive)
        .accessibilityLabel(Text(verbatim: gradient.rawValue.capitalized))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Save bar

    /// A floating Save button anchored to the bottom of the sheet,
    /// inside a `GlassEffectContainer` so the commit affordance lives
    /// on the system's functional layer.
    @ViewBuilder
    private func saveBar(_ wallet: WalletRecord) -> some View {
        GlassEffectContainer(spacing: 0) {
            UniButton(
                title: "Save",
                variant: .primary,
                isEnabled: true
            ) {
                commit(wallet)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.s)
            .padding(.top, UniSpacing.s)
        }
    }

    // MARK: - Section label

    @ViewBuilder
    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(UniTypography.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(UniColors.Text.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    // MARK: - Seeding

    /// Initialise the staged spec from the wallet's current persisted
    /// avatar. Runs once on first appear via `didSeed`.
    private func seedIfNeeded() {
        guard !didSeed, let wallet else { return }
        let current = wallet.avatarSpec
        stagedGradient = current.gradient
        // Restore a previously-picked custom colour so re-opening the
        // picker shows it selected (2026-06-19).
        if let hex = current.customColorHex {
            usesCustomColor = true
            stagedCustomColor = UniColors.WalletAvatar.color(fromHex: hex)
        } else {
            usesCustomColor = false
        }
        didSeed = true
    }

    // MARK: - Spec composition

    /// The currently-staged spec, used both for the live preview and
    /// for the Save commit. Always includes the wallet's derived
    /// badge so the preview matches what the user will see on the
    /// home / list / switcher surfaces.
    private func stagedSpec(for wallet: WalletRecord) -> WalletAvatarSpec {
        WalletAvatarSpec.walletMark(
            gradient: stagedGradient,
            badge: WalletAvatarBadge.derive(from: wallet.kind),
            customColorHex: usesCustomColor ? UniColors.WalletAvatar.hex(from: stagedCustomColor) : nil
        )
    }

    // MARK: - Commit

    private func commit(_ wallet: WalletRecord) {
        let spec = stagedSpec(for: wallet)
        Task { @MainActor in
            _ = try? await WalletCommandRepository(database: AppDatabase.shared)
                .updateAvatar(id: wallet.id, spec: spec)
            WalletCustomSvgRenderer.invalidate(walletId: wallet.id)
            dismiss()
        }
    }

    // MARK: - Missing fallback

    private var missing: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
            UniBody(
                text: "This wallet is no longer in the local store.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
        .frame(maxWidth: .infinity)
        .padding(UniSpacing.xl)
    }
}
