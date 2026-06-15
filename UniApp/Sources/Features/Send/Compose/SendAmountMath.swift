import Foundation

/// Per-chain amount math: spendable balance, send-all/MAX, and the
/// reserve/min-balance/existential-deposit/activation deduction. All
/// money math in `Decimal` (never Double). Doc-grounded per the matrix.
///
/// "Native" inputs are in display units (e.g. 1.5 BTC, 100 XRP). The
/// returned values are display units too.
enum SendAmountMath {

    /// The live account state needed to compute spendable balance.
    /// Only the fields a chain actually uses are populated; the rest
    /// stay at their defaults.
    struct AccountState: Sendable, Hashable {
        /// Total native balance (display units).
        var balance: Decimal = 0
        /// XRP: number of owned objects (drives owner reserve).
        var ownerCount: Int = 0
        /// Stellar: subentry count (drives min balance).
        var subentryCount: Int = 0
        /// Stellar: sponsoring/sponsored counts.
        var numSponsoring: Int = 0
        var numSponsored: Int = 0
        /// Stellar: selling liabilities on the native balance.
        var sellingLiabilities: Decimal = 0
        /// Polkadot: frozen + reserved (display units).
        var frozen: Decimal = 0
        var reserved: Decimal = 0
        /// NEAR: storage_usage in bytes + locked balance (display units).
        var storageUsageBytes: Int = 0
        var locked: Decimal = 0
    }

    /// The standing locked/reserved amount that can never be spent while
    /// the account stays open (display units). 0 for chains with no
    /// reserve. Used for both the spendable cap and the MAX computation.
    static func standingReserve(rule: ReserveRule, state: AccountState) -> Decimal {
        switch rule {
        case .none, .tronActivation:
            return 0
        case .xrpReserve(let base, let perObject):
            return base + Decimal(state.ownerCount) * perObject + state.sellingLiabilities
        case .stellarReserve(let baseReserve):
            let entries = Decimal(2 + state.subentryCount + state.numSponsoring - state.numSponsored)
            return entries * baseReserve + state.sellingLiabilities
        case .existentialDeposit(let ed):
            // Spendable = free − max(frozen − reserved, ED). The non-
            // spendable floor is max(frozen − reserved, ed).
            return max(state.frozen - state.reserved, ed)
        case .solanaRent(let rent):
            return rent
        case .nearStorage(let perByte):
            return state.locked + Decimal(state.storageUsageBytes) * perByte
        }
    }

    /// The maximum amount the user can send (MAX / send-all) in display
    /// units = balance − standingReserve − worstCaseFee − activation.
    /// For a token send, fee comes from the NATIVE balance, so the token
    /// MAX is the full token balance (the native-fee check is separate).
    static func maxSend(
        chain: SupportedChain,
        nativeBalance: Decimal,
        tokenBalance: Decimal?,
        isToken: Bool,
        fee: FeeChoice,
        state: AccountState,
        recipientNeedsActivation: Bool
    ) -> Decimal {
        let cap = ChainComposeCapability.capability(for: chain)
        if isToken {
            // Token MAX = full token balance (gas paid in native).
            return max(tokenBalance ?? 0, 0)
        }
        let reserve = standingReserve(rule: cap.reserve, state: state)
        var activation: Decimal = 0
        if recipientNeedsActivation, case .tronActivation(let surcharge) = cap.reserve {
            activation = surcharge
        }
        let result = nativeBalance - reserve - fee.worstCaseTotalNative - activation
        return max(result, 0)
    }

    /// Available (spendable) balance for display in the amount field's
    /// "Available" line = balance − standingReserve (fee shown
    /// separately). For token sends, available = token balance.
    static func available(
        chain: SupportedChain,
        nativeBalance: Decimal,
        tokenBalance: Decimal?,
        isToken: Bool,
        state: AccountState
    ) -> Decimal {
        if isToken { return max(tokenBalance ?? 0, 0) }
        let cap = ChainComposeCapability.capability(for: chain)
        let reserve = standingReserve(rule: cap.reserve, state: state)
        return max(nativeBalance - reserve, 0)
    }

    /// The minimum amount that must be delivered to activate a brand-new
    /// recipient (XRP base reserve, Stellar bare-account min). 0 when no
    /// activation minimum applies. Display units.
    static func activationMinimum(chain: SupportedChain) -> Decimal {
        let cap = ChainComposeCapability.capability(for: chain)
        switch cap.reserve {
        case .xrpReserve(let base, _):
            return base // first payment must deliver ≥ base reserve
        case .stellarReserve(let baseReserve):
            return baseReserve * 2 // bare account min = 2 × base reserve
        default:
            return 0
        }
    }

    /// The dust / minimum-amount floor for a single output, in display
    /// units. Bitcoin-family dust (per output type), 0 elsewhere.
    static func dustMinimum(chain: SupportedChain) -> Decimal {
        let dec = chain.nativeDecimals
        switch chain {
        case .bitcoin, .litecoin:
            return ComposeDecimal.toDisplay(294, decimals: dec) // P2WPKH dust
        case .bitcoinCash:
            return ComposeDecimal.toDisplay(546, decimals: dec)
        case .dogecoin:
            return ComposeDecimal.toDisplay(100_000, decimals: dec) // hard dust 0.001 DOGE
        default:
            return 0
        }
    }
}
