import SwiftUI

/// **Networks multi-select sub-screen** — the user picks which
/// networks participate in their wallet-home holdings list. Pushed
/// onto the filter sheet's `NavigationStack` via the "Networks"
/// row.
///
/// **Design intent (Rule #2 §D.1):** the user names the networks
/// they care about; everything else falls quietly out of view
/// without being hidden permanently.
///
/// **The two filters compose.** This screen drives
/// `selectedNetworks` (the opt-in path — "show only these"). The
/// existing `Hidden chains` sub-screen drives `hiddenChains` (the
/// opt-out path — "always hide these"). For a row to render in the
/// wallet home, its chain must:
///
///  * be in `selectedNetworks` (OR `selectedNetworks` is empty,
///    the sentinel for "all networks visible") AND
///  * NOT be in `hiddenChains`.
///
/// The two registers stay independent so a power user can mute a
/// single chain wholesale without disturbing their narrower
/// "today I'm looking at these four chains" choice.
///
/// **Empty-set sentinel.** When the user selects every chain, the
/// stored set is also written as empty (the sentinel) so the home
/// reads "all networks visible" without enumerating every chain in
/// `@AppStorage`. The "Select all" toolbar action does this
/// explicitly — see `selectAll()`.
///
/// **Toolbar quick-actions (Rule #2 §A.5 — restraint).** One
/// trailing toolbar item: a single label that reads "Select all"
/// when at least one chain is unselected, or "Select none" when
/// every chain is selected. Same affordance, two states — one tap
/// flips the entire roster. Saves the user from tapping 27 rows
/// when they want a fresh start.
///
/// **Search.** Per Rule #14 — `.searchable(text:)` with no
/// `placement:` override. `localizedStandardContains` against the
/// chain's display name, ticker, and raw value so a query in any
/// locale matches every human-readable field on the row.
///
/// **Layout (Rule #15 §A).** Pushed sub-screen — does NOT wrap its
/// content in a `NavigationStack`. The parent sheet owns the stack
/// and the sub-screen consumes it.
struct WalletHomeNetworksView: View {
    @AppStorage(WalletHomeFilterPreferences.selectedNetworksKey)
    private var selectedJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON

    @State private var searchText: String = ""

    /// Decoded selection set — the single source every row's
    /// `isSelected` read and the toggle mutations operate on.
    /// Decoded once (seeded in `init`, re-synced via `.onChange`
    /// for external writes like the sheet's Reset) instead of the
    /// prior per-call decode in `currentSet`, which ran per row per
    /// render and could lose a toggle when two mutations raced the
    /// same pre-mutation JSON.
    @State private var selectedSet: Set<String>

    init() {
        let json = UserDefaults.standard.string(forKey: WalletHomeFilterPreferences.selectedNetworksKey)
            ?? WalletHomeFilterPreferences.defaultHiddenJSON
        _selectedSet = State(initialValue: WalletHomeFilterPreferences.decode(json))
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredChains, id: \.self) { chain in
                    NetworkRow(
                        chain: chain,
                        isSelected: isSelected(chain),
                        toggle: { toggle(chain) }
                    )
                    .listRowBackground(UniColors.Background.secondary)
                }
            } footer: {
                Text("Pick the networks to show in your wallet home. When none are picked, every network is visible.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Networks"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if allSelected {
                        selectNone()
                    } else {
                        selectAll()
                    }
                } label: {
                    Text(allSelected ? "Select none" : "Select all")
                }
            }
        }
        .uniHaptic(.selection, trigger: selectedJSON)
        .onChange(of: selectedJSON) { _, newValue in
            let decoded = WalletHomeFilterPreferences.decode(newValue)
            if decoded != selectedSet { selectedSet = decoded }
        }
    }

    // MARK: - Filter

    private var filteredChains: [SupportedChain] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SupportedChain.allCases }
        return SupportedChain.allCases.filter { chain in
            chain.displayName.localizedStandardContains(query)
                || chain.ticker.localizedStandardContains(query)
                || chain.rawValue.localizedStandardContains(query)
        }
    }

    // MARK: - State helpers

    /// `true` when every chain is selected. The persisted set is
    /// EITHER the empty sentinel (which we also treat as "all
    /// selected" for the UI) OR a set containing every chain's raw
    /// value. The pill-flip label uses this predicate.
    private var allSelected: Bool {
        if selectedSet.isEmpty { return true }  // sentinel — "all networks"
        return selectedSet.count == SupportedChain.allCases.count
    }

    /// A chain is "selected" (visible) when the set is empty
    /// (sentinel: all) OR the chain is in the set.
    private func isSelected(_ chain: SupportedChain) -> Bool {
        if selectedSet.isEmpty { return true }  // sentinel — all visible
        return selectedSet.contains(chain.rawValue)
    }

    // MARK: - Mutations

    /// Toggle one chain in/out of the explicit set. When the set
    /// transitions from "every chain selected" to "one removed",
    /// we materialize the explicit set first (so the sentinel
    /// doesn't keep claiming "all"). When it transitions back to
    /// "every chain selected", we collapse to the sentinel (empty).
    /// Mutates the in-memory `selectedSet` first, then persists —
    /// the set is the single source, so back-to-back toggles never
    /// race the same pre-mutation JSON.
    private func toggle(_ chain: SupportedChain) {
        var set = selectedSet
        if set.isEmpty {
            // Sentinel → materialize the explicit "all" set so we
            // can remove this one chain from it.
            set = Set(SupportedChain.allCases.map(\.rawValue))
        }
        if set.contains(chain.rawValue) {
            set.remove(chain.rawValue)
        } else {
            set.insert(chain.rawValue)
        }
        // Collapse back to the sentinel when every chain is now
        // selected — keeps the persisted JSON small and the read
        // path consistent with "default = all visible".
        if set.count == SupportedChain.allCases.count {
            selectedSet = []
            selectedJSON = WalletHomeFilterPreferences.defaultHiddenJSON
        } else {
            selectedSet = set
            selectedJSON = WalletHomeFilterPreferences.encode(set)
        }
    }

    private func selectAll() {
        selectedSet = []
        selectedJSON = WalletHomeFilterPreferences.defaultHiddenJSON  // sentinel
    }

    private func selectNone() {
        // Explicit empty marker set ("[]") would also be the
        // sentinel — so we write a sentinel that means "none" by
        // using a non-overlapping marker. Simpler: pick the empty
        // string as "no networks" requires re-reading the
        // contract. Cleaner: keep one sentinel ("[]" = all), and
        // for "none" store an actual empty list of explicit values
        // — but that's the same JSON. The honest fix is to
        // include a single placeholder value that is NOT a real
        // chain rawValue so the set isn't empty. We use the
        // reserved string "__none__" — never a chain rawValue, so
        // `isSelected(_:)` never matches it.
        selectedSet = [Self.noneSentinel]
        selectedJSON = WalletHomeFilterPreferences.encode([Self.noneSentinel])
    }

    /// Reserved marker used by `selectNone()` to distinguish the
    /// "user explicitly picked zero" state from the "default — all
    /// visible" state, both of which would otherwise encode to the
    /// same empty JSON. Never matches a real `SupportedChain.rawValue`.
    static let noneSentinel = "__none__"
}

// MARK: - NetworkRow

/// One row in the Networks sub-screen. Chain mark + chain display
/// name + ticker + trailing selection glyph (`checkmark` when
/// selected, `circle` when not). Toggling fires the parent's
/// closure which updates the persisted set.
///
/// **Why a custom row and not `Toggle`.** A toggle's switch chrome
/// reads as a per-row state machine; a checkmark reads as a
/// roster pick from a list. The Networks sub-screen is the
/// latter — the user is picking the networks that participate in
/// their view. Apple's own Settings → Wi-Fi networks uses the
/// same checkmark idiom for "current network."
private struct NetworkRow: View {
    let chain: SupportedChain
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: UniSpacing.s) {
                CoinMark(chain: chain, tokenSymbol: chain.ticker, contract: nil)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: chain.displayName)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                        .lineLimit(1)
                    Text(verbatim: chain.ticker)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: UniSpacing.s)
                Image(systemName: isSelected ? "checkmark" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isSelected
                        ? UniColors.Button.primaryTint
                        : UniColors.Icon.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, UniSpacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: chain.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
