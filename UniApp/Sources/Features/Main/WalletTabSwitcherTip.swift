import SwiftUI
import TipKit

/// First-time-feature tip surfaced as a native iOS `TipKit` popover
/// anchored to the bottom Wallet tab, explaining the long-press
/// context menu (switch wallet, customise, create, import). Apple's
/// own apps use this exact primitive for first-feature hints —
/// Messages' "Edit message" tip, Photos' "Memories" tip, Mail's
/// "Schedule send" tip. Restrained, iOS-native, dismissable.
///
/// **Why TipKit, not a custom overlay.** Per Rule #3 (native-only),
/// `TipKit` (iOS 17+) is the canonical API for first-time feature
/// education. It owns the popover chrome, the balloon arrow pointing
/// at the source view, the dismiss button (top-right "X"), the action
/// button styling, the persistence (one-shot per `Tip` type), the
/// accessibility tree, the haptic at present, the matched-geometry
/// dismiss animation, and the Liquid Glass material. None of that is
/// worth re-implementing in app code.
///
/// **Display rule.** The user direction was explicit:
/// > *"when user have more than 1 wallet (only for first time)"*.
/// We expose `walletCount` as a `@Parameter` and `#Rule` against it —
/// the tip only becomes eligible to display when the count reaches
/// 2. Once the user dismisses the tip (via the X or by interacting
/// with the feature), `TipKit`'s data store records the dismissal
/// and the tip never reappears, even if `walletCount` later changes.
/// That's the *"only for first time"* contract.
///
/// **Voice (Rule #2 §A.6).** Title: a sentence the user might think
/// to themselves; message: the concrete affordances. No marketing
/// exclamation, no emoji, no "Pro tip:". The voice the user will
/// trust because it sounds like the rest of iOS.
struct WalletTabSwitcherTip: Tip {
    /// The current number of persisted wallets. Updated from
    /// `MainTabView` via `.onChange(of: allWallets.count)`. When this
    /// crosses 2, the tip becomes eligible.
    @Parameter
    static var walletCount: Int = 0

    var title: Text {
        Text("Switch between wallets")
    }

    var message: Text? {
        Text("Long-press the Wallet tab to switch, customise, create, or import.")
    }

    var image: Image? {
        Image(systemName: "rectangle.stack.fill")
    }

    /// Rule: only show when the user has 2 or more wallets. Below
    /// that, there's nothing useful to switch between, so the tip
    /// would teach an affordance that has no value yet.
    var rules: [Rule] {
        [
            #Rule(Self.$walletCount) { $0 >= 2 }
        ]
    }

    /// `MaxDisplayCount(1)` is the explicit *"only once, ever"*
    /// contract the user direction names: *"IT SHOULD BE SHOWN ONLY
    /// ONE TIME FOR EACH USER, NO MORE THAN ONE TIME."* Without this
    /// option, `TipKit` would re-present an eligible tip on every
    /// cold launch until the user actively dismisses it via the X.
    /// With it, the tip self-invalidates after iOS shows it once —
    /// dismissed by tap, by feature interaction, or simply by
    /// scrolling past — and never reappears. The data store
    /// (configured in `UniAppApp.init()` as
    /// `.applicationDefault`) persists the count across launches.
    var options: [any TipOption] {
        [Tips.MaxDisplayCount(1)]
    }
}
