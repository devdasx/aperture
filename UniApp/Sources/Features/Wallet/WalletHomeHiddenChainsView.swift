import SwiftUI

/// **Hidden chains sub-screen** — the per-chain visibility editor
/// pushed onto the filter sheet's `NavigationStack`. Sibling shape
/// to `WalletHomeHiddenAssetsView` but operates one level higher:
/// the user mutes a whole network (e.g., a watch-only Solana address
/// imported by mistake, or a chain the user doesn't care to see in
/// their portfolio). When a chain is muted, every coin and every
/// token on that chain is hidden from the wallet-home holdings list
/// — so the user mutes once instead of toggling N rows.
///
/// **Design intent (Rule #2 §D.1):** give the user a quiet way to
/// suppress an entire network from their daily view without losing
/// the wallet itself. The chain stays a real chain in the wallet
/// (addresses still derive, scanner still scans, balances still
/// land in SwiftData); the home view simply omits it.
///
/// **Layout.** Single section listing every `SupportedChain.allCases`
/// in canonical order. Each row carries the chain's logo, display
/// name, ticker, and a `Toggle` for "hidden." No search affordance —
/// 27 chains is small enough to scan visually, and a search field on
/// such a short list reads as noise.
///
/// **Persistence.** Writes through the same `@AppStorage`-backed
/// JSON helper as `WalletHomeHiddenAssetsView` but against the
/// separate `hiddenChainsKey` storage key so the two registers stay
/// independent — a user can mute the BSC chain wholesale without
/// affecting their per-asset hides.
///
/// **Honesty (Rule #2 §A.7).** A muted chain is a muted chain — its
/// rows do not render. No "you have N hidden balances on this chain"
/// nag; the user wanted them gone and they're gone. The parent
/// filter sheet's preview header is the one place that surfaces
/// "Showing N of M assets" so the user always knows the total.
///
/// **Layout (Rule #15 §A).** Pushed sub-screen — does NOT wrap its
/// content in a `NavigationStack`. The parent sheet owns the stack
/// and the sub-screen consumes it.
struct WalletHomeHiddenChainsView: View {
    @AppStorage(WalletHomeFilterPreferences.hiddenChainsKey)
    private var hiddenJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON

    /// Decoded hidden-chains set — the single source the row
    /// bindings read and mutate. Decoded once (seeded in `init`,
    /// re-synced via `.onChange` for external writes like the
    /// sheet's Reset) instead of the prior per-row
    /// read-decode-mutate-encode-write round-trip, which decoded
    /// per render and could lose a toggle when two writes raced.
    @State private var hiddenSet: Set<String>

    init() {
        let json = UserDefaults.standard.string(forKey: WalletHomeFilterPreferences.hiddenChainsKey)
            ?? WalletHomeFilterPreferences.defaultHiddenJSON
        _hiddenSet = State(initialValue: WalletHomeFilterPreferences.decode(json))
    }

    var body: some View {
        List {
            Section {
                ForEach(SupportedChain.allCases, id: \.self) { chain in
                    AssetVisibilityRow(
                        leadingMark: AnyView(chainMark(for: chain)),
                        title: chain.displayName,
                        subtitle: chain.ticker,
                        isHidden: bindingFor(chain)
                    )
                    .listRowBackground(UniColors.Background.secondary)
                }
            } footer: {
                Text("Hiding a chain hides every coin and token on it from the wallet home. The addresses stay in your wallet — only the display changes.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Hidden chains"))
        .navigationBarTitleDisplayMode(.large)
        .uniHaptic(.selection, trigger: hiddenJSON)
        .onChange(of: hiddenJSON) { _, newValue in
            let decoded = WalletHomeFilterPreferences.decode(newValue)
            if decoded != hiddenSet { hiddenSet = decoded }
        }
    }

    @ViewBuilder
    private func chainMark(for chain: SupportedChain) -> some View {
        CoinMark(chain: chain, tokenSymbol: chain.ticker, contract: nil)
            .frame(width: 36, height: 36)
    }

    /// `Binding<Bool>` for one chain's "hidden" toggle. Same shape
    /// as the asset bindings in `WalletHomeHiddenAssetsView` but
    /// keyed by `SupportedChain.rawValue`. Reads + mutates the
    /// in-memory `hiddenSet` and encodes the updated set back to
    /// `@AppStorage` — single source, no per-row decode, no lost
    /// updates.
    private func bindingFor(_ chain: SupportedChain) -> Binding<Bool> {
        let key = chain.rawValue
        return Binding(
            get: { hiddenSet.contains(key) },
            set: { newValue in
                if newValue { hiddenSet.insert(key) } else { hiddenSet.remove(key) }
                hiddenJSON = WalletHomeFilterPreferences.encode(hiddenSet)
            }
        )
    }
}
