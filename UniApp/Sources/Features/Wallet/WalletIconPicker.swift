import SwiftUI
import SwiftData

/// The user-facing avatar-customisation sheet. Presented from
/// `WalletDetailView` (Settings → Wallets → <wallet>) and from the
/// MainTabView's Wallet-tab long-press `contextMenu` "Customise"
/// shortcut. One `NavigationStack`-rooted sheet (Rule #15) — title
/// "Customise wallet", a live preview at the top, two sections
/// below: 12 background colors, 18 SF Symbols. "Reset to default"
/// `UniButton(.tertiary)` in a bottom-anchored row, "Done" closes.
///
/// **Why a curated 18-symbol set, not the SF Symbols library.**
/// Per Rule #2 §A.6 *"Less, but better."* SF Symbols ships 5000+
/// glyphs; surfacing all of them is a usability disaster. The 18
/// chosen below are the wallet-class identities most users will
/// reach for — value, security, time, mobility, identity. Anyone
/// who needs something off-list can pick the closest match; the
/// next-most-frequent symbol can be added in a follow-up by
/// extending `curatedSymbols` (one line).
///
/// **Why no Cancel + Save dance.** Edits are committed to the
/// repository the moment the user taps a color or symbol — the
/// `@Query` reactivity on `WalletRecord` re-renders the preview
/// inline, and every other surface (tab icon, toolbar pill,
/// wallet-switcher row) updates simultaneously. There's no
/// "draft state" to save — the user sees their change land in
/// the tab bar through the sheet's translucency. iOS Music's
/// Now Playing color-customisation works the same way; iOS
/// Settings → Appearance flips theme live.
struct WalletIconPickerSheet: View {
    let walletId: UUID

    @Query private var matches: [WalletRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(walletId: UUID) {
        self.walletId = walletId
        _matches = Query(filter: #Predicate<WalletRecord> { $0.id == walletId })
    }

    private var wallet: WalletRecord? { matches.first }

    var body: some View {
        NavigationStack {
            Group {
                if let wallet {
                    content(wallet)
                } else {
                    missing
                }
            }
            .navigationTitle("Customise wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ wallet: WalletRecord) -> some View {
        List {
            // MARK: - Hero preview row
            //
            // The live preview anchor. As the user taps a color or
            // symbol below, `@Query` reactivity re-renders this
            // avatar in place — the user watches their choice land
            // before they tap Done. Same pattern as iOS Settings'
            // appearance switcher: the change is the confirmation.
            Section {
                VStack(spacing: UniSpacing.m) {
                    WalletAvatar(
                        symbol: wallet.iconSymbol,
                        colorHex: wallet.iconColorHex,
                        size: .hero
                    )
                    .padding(.top, UniSpacing.s)

                    Text(verbatim: wallet.name)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UniSpacing.s)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // MARK: - Color section
            //
            // 12 curated swatches in a 6-column grid. Each swatch is
            // a circle filled with its hex; the active selection
            // carries a 2pt accent ring + an inner check mark for
            // dual-affordance accessibility (color + glyph).
            Section {
                colorGrid(wallet)
                    .listRowBackground(UniColors.Background.secondary)
            } header: {
                Text("Background")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            // MARK: - Symbol section
            //
            // 18 curated SF Symbols in a 6-column grid. Each is the
            // glyph rendered in `Text.primary` on `Background.secondary`,
            // the active one fills with the wallet's chosen color so
            // the user sees the live composition under their finger.
            Section {
                symbolGrid(wallet)
                    .listRowBackground(UniColors.Background.secondary)
            } header: {
                Text("Symbol")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            // MARK: - Reset
            Section {
                UniButton(
                    title: "Reset to default",
                    variant: .tertiary
                ) {
                    Task { await update(wallet, symbol: WalletAvatarDefaults.symbol, colorHex: WalletAvatarDefaults.colorHex) }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } footer: {
                Text("Restores the default wallet identity — Ink background, Wallet glyph.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
    }

    // MARK: - Color grid

    @ViewBuilder
    private func colorGrid(_ wallet: WalletRecord) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: UniSpacing.s), count: 6)
        LazyVGrid(columns: columns, spacing: UniSpacing.s) {
            ForEach(UniColors.WalletAvatar.curated, id: \.self) { hex in
                colorSwatch(hex: hex, isActive: hex == wallet.iconColorHex) {
                    Task { await update(wallet, symbol: wallet.iconSymbol, colorHex: hex) }
                }
            }
        }
        .padding(.vertical, UniSpacing.xs)
    }

    @ViewBuilder
    private func colorSwatch(hex: String, isActive: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            // The swatch is its own miniature avatar — a circle in
            // the hex color, with a centered checkmark when active.
            // Using `WalletAvatar(symbol: "checkmark", colorHex: hex)`
            // for the active state would be honest but visually
            // noisy when the active swatch's chosen symbol differs.
            // We render a plain circle and overlay a check only
            // when active, so the affordance reads as "swatch" not
            // "wallet avatar."
            ZStack {
                WalletAvatar(symbol: "circle.fill", colorHex: hex, size: .row)
                    .opacity(0) // hidden — sizing anchor only
                Circle()
                    .fill(Color.swatchColor(hex: hex))
                    .frame(width: 36, height: 36)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xxs)
            .overlay(
                // Active ring sits just outside the circle so the
                // user reads selection without losing the swatch's
                // tone underneath.
                Circle()
                    .stroke(UniColors.Tint.accent, lineWidth: isActive ? 2 : 0)
                    .frame(width: 44, height: 44)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: isActive)
        .accessibilityLabel(Text("Color"))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Symbol grid

    @ViewBuilder
    private func symbolGrid(_ wallet: WalletRecord) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: UniSpacing.s), count: 6)
        LazyVGrid(columns: columns, spacing: UniSpacing.s) {
            ForEach(Self.curatedSymbols, id: \.self) { symbol in
                symbolSwatch(
                    symbol: symbol,
                    isActive: symbol == wallet.iconSymbol,
                    activeColorHex: wallet.iconColorHex
                ) {
                    Task { await update(wallet, symbol: symbol, colorHex: wallet.iconColorHex) }
                }
            }
        }
        .padding(.vertical, UniSpacing.xs)
    }

    @ViewBuilder
    private func symbolSwatch(
        symbol: String,
        isActive: Bool,
        activeColorHex: String,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.swatchColor(hex: activeColorHex) : UniColors.Fill.secondary)
                    .frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isActive ? .white : UniColors.Icon.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xxs)
            .overlay(
                Circle()
                    .stroke(UniColors.Tint.accent, lineWidth: isActive ? 2 : 0)
                    .frame(width: 44, height: 44)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: isActive)
        .accessibilityLabel(Text("Symbol"))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Missing wallet fallback

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

    // MARK: - Repository write

    /// Writes the new identity through `WalletRepository`. The
    /// repository is `@ModelActor`-isolated so the write happens off
    /// the main actor; SwiftData's cross-context merge lands the
    /// change on the @Query-backed view contexts, which re-render
    /// every consumer (avatar in this sheet's preview row, the tab
    /// icon, the toolbar pill, the wallet-switcher row, the
    /// wallets-list row).
    private func update(_ wallet: WalletRecord, symbol: String, colorHex: String) async {
        let id = wallet.id
        let repo = WalletRepository(modelContainer: modelContext.container)
        _ = try? await repo.updateAvatar(id: id, iconSymbol: symbol, iconColorHex: colorHex)
    }

    // MARK: - Curated symbol set
    //
    // 18 SF Symbols organised by what each says about a wallet's
    // role. The order is chosen so adjacent symbols don't read as
    // duplicates and so the user scanning the grid lands on the
    // archetype they're looking for quickly.
    //
    // - **Value / money:** wallet, credit card, dollar, banknote, sack of cash.
    // - **Security:** lock, key, shield.
    // - **Movement / speed:** bolt, paper plane, arrow circling.
    // - **Identity / nature:** star, moon, sun, leaf, sparkles.
    // - **Misc anchors:** flag, cube.
    //
    // Every glyph is a single SF Symbol name; the `.fill` variants
    // are used where they read more present in the avatar's white-on-color
    // composition.
    static let curatedSymbols: [String] = [
        "wallet.pass.fill",
        "creditcard.fill",
        "dollarsign.circle.fill",
        "banknote.fill",
        "bitcoinsign.circle.fill",
        "lock.fill",
        "key.fill",
        "shield.fill",
        "bolt.fill",
        "paperplane.fill",
        "arrow.triangle.2.circlepath",
        "star.fill",
        "moon.stars.fill",
        "sun.max.fill",
        "leaf.fill",
        "sparkles",
        "flag.fill",
        "cube.fill"
    ]
}

// MARK: - Swatch color resolver
//
// Bridge from a hex string to a SwiftUI `Color` for the picker's
// swatch fills. Uses the same fileprivate `Color.fromHex(_:)`
// declared in `WalletAvatar.swift`'s file scope, but we need a
// callable accessor from THIS file — so we expose a tiny
// `fileprivate` wrapper that delegates. Marked `fileprivate` so
// nothing outside this picker file can read a hex into a Color
// (the Rule #4 §B exception stays scoped).
private extension Color {
    static func swatchColor(hex: String) -> Color {
        // Use a sRGB decoder local to this file for the swatch
        // chips. The shared decoder in WalletAvatar.swift is
        // fileprivate to ITS file by design (one Rule #4 §B
        // carve-out per file); the picker re-implements the same
        // 12 lines so the carve-out stays scoped.
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6 else { return UniColors.Fill.secondary }
        var rgb: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&rgb) else { return UniColors.Fill.secondary }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8)  & 0xFF) / 255.0
        let b = Double(rgb         & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
