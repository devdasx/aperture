import SwiftUI

/// Shared chain picker used by Methods B (private key) and C
/// (watch-only). Per Rule #14 — native `.searchable(text:)` with no
/// `placement:` override; the system renders the bottom-floating
/// Liquid Glass field on iPhone iOS 26.
///
/// Filter uses `localizedStandardContains` against the chain's display
/// name and ticker.
struct ChainPickerView: View {
    let title: LocalizedStringKey
    let onPick: (SupportedChain) -> Void

    @State private var searchText: String = ""

    private var filteredChains: [SupportedChain] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SupportedChain.allCases }
        return SupportedChain.allCases.filter { chain in
            chain.displayName.localizedStandardContains(query)
                || chain.ticker.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredChains, id: \.self) { chain in
                    Button {
                        onPick(chain)
                    } label: {
                        chainRow(chain)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search"))
    }

    private func chainRow(_ chain: SupportedChain) -> some View {
        HStack(spacing: UniSpacing.s) {
            // Logo with SF Symbol fallback (per Rule #7 — bundled
            // brand assets when present, SF Symbol "circle.fill" as a
            // neutral placeholder when not).
            chainLogo(for: chain)
                .frame(width: 32, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: chain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: chain.ticker)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, UniSpacing.xxs)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func chainLogo(for chain: SupportedChain) -> some View {
        if let assetName = chain.logoAssetName,
           UIImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .frame(width: 24, height: 24)
                .clipShape(Circle())
        } else {
            Image(systemName: "circle.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
        }
    }
}
