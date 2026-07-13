import SwiftUI

/// Wallet-avatar colour customisation. The mark is always Aperture’s
/// iris; this sheet only changes the disc / home-hero identity colour.
///
/// **Immediate apply.** Each tap writes through GRDB and refreshes home
/// chrome — no Save. Cancel only dismisses the sheet.
///
/// **Palette.** Named chromatic list (no black / grey, no freeform
/// custom colour). Neutrals already stored on a wallet still hydrate;
/// they simply are not offered here.
struct WalletIconPickerSheet: View {
    let walletId: UUID

    @StateObject private var walletRecordsObservation = WalletRecordsObservation()
    @Environment(\.dismiss) private var dismiss

    @State private var stagedGradient: WalletAvatarGradient = .blue
    @State private var didSeed: Bool = false
    /// Serialises GRDB avatar writes so rapid taps always persist the
    /// **latest** staged colour (never drop Rose because Green was mid-write).
    @State private var writeTask: Task<Void, Never>?

    private var wallet: WalletRecord? {
        walletRecordsObservation.wallets.first { $0.id == walletId }
    }

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
            // Do not cancel `writeTask` on dismiss — the last colour must
            // still flush to GRDB after the sheet closes.
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(_ wallet: WalletRecord) -> some View {
        // Logo stays pinned above the list so colour taps always show on the
        // mark — scrolling the palette must not hide the live preview.
        VStack(spacing: 0) {
            livePreview(wallet)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.s)
                .frame(maxWidth: .infinity)
                .background(UniColors.Background.primary)
                .zIndex(1)

            List {
                Section {
                    ForEach(WalletAvatarGradient.pickerCases, id: \.self) { gradient in
                        colorRow(gradient, wallet: wallet)
                    }
                } header: {
                    Text("Colour")
                        .font(UniTypography.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(UniColors.Text.secondary)
                        .textCase(.uppercase)
                } footer: {
                    Text("Colour applies immediately to this wallet’s icon and home card.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
            .uniListPageChrome()
        }
        .background(UniColors.Background.primary)
    }

    // MARK: - Live preview (pinned; not part of the scrolling list)

    @ViewBuilder
    private func livePreview(_ wallet: WalletRecord) -> some View {
        VStack(spacing: UniSpacing.s) {
            WalletAvatar(
                spec: stagedSpec(for: wallet),
                size: .editor
            )
            .animation(.smooth(duration: 0.18), value: stagedGradient)

            Text(verbatim: wallet.name)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: wallet.name))
    }

    // MARK: - Colour list

    @ViewBuilder
    private func colorRow(_ gradient: WalletAvatarGradient, wallet: WalletRecord) -> some View {
        let isActive = gradient == stagedGradient
        Button {
            select(gradient, wallet: wallet)
        } label: {
            HStack(spacing: UniSpacing.s) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: UniColors.WalletAvatar.gradientStops(for: gradient),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 36, height: 36)
                    .overlay {
                        Circle()
                            .strokeBorder(UniColors.Separator.regular.opacity(0.35), lineWidth: 0.5)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(gradient.displayName)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(gradient.displayDetail)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.accent)
                        .accessibilityHidden(true)
                }
            }
            .uniListRowHitTarget()
            .contentShape(Rectangle())
        }
        .buttonStyle(.uniListRow)
        .uniListRowSurface()
        .accessibilityLabel(Text(gradient.displayName))
        .accessibilityHint(Text(gradient.displayDetail))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .uniHaptic(.selection, trigger: isActive)
    }

    // MARK: - Selection + live write

    private func select(_ gradient: WalletAvatarGradient, wallet: WalletRecord) {
        guard gradient != stagedGradient || wallet.avatarSpec.customColorHex != nil else {
            return
        }
        stagedGradient = gradient
        apply(wallet)
    }

    /// Paint home chrome **first**, then debounce-persist. Never re-read a
    /// stale observation into chrome after write — that was clobbering Rose
    /// (etc.) back to the previous colour (often Green) under the sheet.
    private func apply(_ wallet: WalletRecord) {
        let walletId = wallet.id
        let name = wallet.name
        let spec = stagedSpec(for: wallet)

        // Immediate: balance card + app bar track the list checkmark.
        WalletHomeSwipeChrome.shared.applyIdentity(
            walletId: walletId,
            name: name,
            spec: spec
        )

        // Coalesce GRDB writes — only the last staged colour is saved.
        writeTask?.cancel()
        writeTask = Task { @MainActor in
            // Tiny debounce so flinging through the list doesn't stampede GRDB.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }

            let latest = stagedSpec(for: wallet)
            _ = try? await WalletCommandRepository(database: AppDatabase.shared)
                .updateAvatar(id: walletId, spec: latest)
            guard !Task.isCancelled else { return }

            WalletCustomSvgRenderer.invalidate(walletId: walletId)
            // Re-affirm the **written** spec — do not refresh from observation
            // (it may still hold the previous gradient for a tick).
            WalletHomeSwipeChrome.shared.applyIdentity(
                walletId: walletId,
                name: name,
                spec: latest
            )
        }
    }

    // MARK: - Seeding

    private func seedIfNeeded() {
        guard !didSeed, let wallet else { return }
        let current = wallet.avatarSpec
        // Custom hex / neutrals: land on a chromatic default for the list.
        if current.customColorHex != nil || current.gradient.isNeutralMonochrome {
            stagedGradient = .blue
        } else {
            stagedGradient = current.gradient
        }
        didSeed = true
    }

    // MARK: - Spec

    private func stagedSpec(for wallet: WalletRecord) -> WalletAvatarSpec {
        WalletAvatarSpec.walletMark(
            gradient: stagedGradient,
            badge: WalletAvatarBadge.derive(from: wallet.kind),
            customColorHex: nil
        )
    }

    // MARK: - Missing

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
        .background(UniColors.Background.primary)
    }
}
