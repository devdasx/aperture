import SwiftUI
import SwiftData

/// **Send · Screen 0 — "What are you sending?"**
///
/// The asset picker. Covers **every** chain/token the active wallet holds
/// — the full `SendAsset.sendable(...)` union (native chains + every
/// registry token expanded per network), mirroring `ReceiveAsset`
/// coverage exactly (Rule #21 — the full set, not a slice). A native
/// search filters across symbol, name, and network so the user finds an
/// asset fast among 100+ rows.
///
/// **Why this is screen 0.** The wallet-home Send button drops the user
/// here first (no asset is preselected from the home in the design); the
/// chosen asset shapes every later screen. The amount / review / advanced
/// screens then work for whatever was picked.
///
/// **Rule #14.** Native `.searchable` on the NavigationStack content, no
/// `placement:` override — iOS owns the placement. Locale-aware
/// `localizedStandardContains` across every human-readable field.
///
/// **Layers:** content layer — opaque list rows. Functional layer — the
/// nav bar + the search field's Liquid Glass container (iOS-owned).
struct SendAssetPickerView: View {
    let availableChains: [SupportedChain]
    let onSelect: (SendAsset) -> Void
    let onCancel: () -> Void

    @Query(sort: [SortDescriptor(\CustomTokenRecord.symbol, order: .forward)])
    private var customTokenRecords: [CustomTokenRecord]
    /// Local-first asset universe (Rule #27 §D) — the seeded `AssetRecord`
    /// rows, with the static `AssetCatalog` as the cold-launch fallback.
    @Query private var assetRecords: [AssetRecord]

    @State private var searchText: String = ""
    @State private var allAssets: [SendAsset] = []

    private var assetsKey: String {
        "\(availableChains.map(\.rawValue).joined(separator: ","))|\(customTokenRecords.count)|\(assetRecords.count)"
    }

    var body: some View {
        List {
            if availableChains.isEmpty {
                emptySection
            } else {
                if !nativeRows.isEmpty {
                    section(title: "Coins", rows: nativeRows)
                }
                if !tokenRows.isEmpty {
                    section(title: "Tokens", rows: tokenRows)
                }
                if nativeRows.isEmpty && tokenRows.isEmpty {
                    noResultsSection
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle("Send")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("Search assets"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: onCancel)
            }
        }
        .task(id: assetsKey) {
            allAssets = SendAsset.sendable(
                availableChains: Set(availableChains),
                customTokens: customTokenRecords.map { CustomTokenSnapshot(from: $0) },
                catalogAssets: AssetCatalog.assets(from: assetRecords)
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(title: LocalizedStringKey, rows: [SendAsset]) -> some View {
        Section {
            ForEach(rows) { asset in
                Button {
                    onSelect(asset)
                } label: {
                    SendAssetRow(asset: asset)
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
            }
        } header: {
            UniCaption(text: title, color: UniColors.Text.tertiary)
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            VStack(spacing: UniSpacing.s) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(UniColors.Icon.tertiary)
                UniBody(
                    text: "No assets available to send from this wallet yet.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xxl)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var noResultsSection: some View {
        Section {
            UniBody(
                text: "No assets match your search.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xl)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Filtering

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nativeRows: [SendAsset] {
        allAssets.filter { if case .native = $0 { return matches($0) } else { return false } }
    }

    private var tokenRows: [SendAsset] {
        allAssets.filter { if case .token = $0 { return matches($0) } else { return false } }
    }

    private func matches(_ asset: SendAsset) -> Bool {
        guard !query.isEmpty else { return true }
        return asset.unitTicker.localizedStandardContains(query)
            || asset.displayName.localizedStandardContains(query)
            || asset.network.displayName.localizedStandardContains(query)
            || asset.network.ticker.localizedStandardContains(query)
    }
}

// MARK: - Row

private struct SendAssetRow: View {
    let asset: SendAsset

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            SendTokenTile(asset: asset, size: 40, ringColor: UniColors.Background.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: asset.unitTicker)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: subtitle)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, UniSpacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(asset.unitTicker), \(subtitle)"))
    }

    private var subtitle: String {
        switch asset {
        case .native:
            return asset.displayName
        case .token:
            return "\(asset.displayName) · \(asset.network.displayName)"
        }
    }
}
