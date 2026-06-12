import SwiftUI
import Observation

/// **The Send flow's single source of UI truth.**
///
/// An `@Observable` (Swift 6.2 / Rule #2 §C — never `ObservableObject`)
/// value-holder threaded through every screen of the Send flow:
/// recipient, the selected asset, the typed amount, the fee selection,
/// and the per-chain advanced parameters. It holds **only UI state** —
/// no key derivation, no signing, no RPC, no fee estimation. Those land
/// behind the `// TODO: (T-061..T-066)` seams in a later turn once the
/// design is approved on-device (the project's design-first contract).
///
/// **Why a class, not a struct.** SwiftUI's `@Observable` macro needs a
/// reference type so the flow's screens share one mutating draft as the
/// user moves recipient → amount → review. Each screen reads + writes the
/// same instance via `@Bindable` / direct mutation; the flow root owns it
/// as `@State`.
///
/// **What is MOCKED here (honest inventory).** The whole point of this
/// turn is the *design*, so the values below are placeholders:
/// - `availableBalance` — a fixed sample (`2.41`) for the active asset.
///   Real balance reads land with T-061.
/// - `unitFiatRate` — a fixed sample rate so the fiat flip + Review
///   total compute against *something*. Real pricing lands with T-061.
/// - `resolvedName` / `resolvedAddress` — a mock ENS resolution shown
///   only for the known sample input `vitalik.eth`. Real ENS/SNS/name
///   resolution lands with T-062.
/// - `isRecipientValid` — a placeholder validity flag (non-empty +
///   not obviously malformed). Real checksum / format / network-match
///   validation lands with T-062.
/// - Every fee number (presets, custom slider values, the resolved
///   network fee) — sample values per the handoff. Real fee estimation
///   lands with T-063.
@MainActor
@Observable
final class SendDraft {

    // MARK: - Recipient

    /// The raw text the user typed / pasted / scanned into the recipient
    /// field. May be an address, an ENS/SNS name, or a partial entry.
    var recipientInput: String = ""

    /// MOCK name resolution. Non-nil only for the known sample input so
    /// the design can show the positive "Resolves to …" row exactly as
    /// the handoff specifies. `// TODO: (T-062)` real resolution.
    var resolvedName: String? {
        let trimmed = recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SendMockData.isResolvableName(trimmed) else { return nil }
        return trimmed
    }

    /// MOCK resolved address for the positive row. `// TODO: (T-062)`.
    var resolvedAddress: String? {
        guard resolvedName != nil else { return nil }
        return SendMockData.sampleResolvedAddress
    }

    /// Placeholder validity gate for the recipient → amount Continue
    /// button. A real implementation checksums the address, verifies the
    /// format for the asset's chain family, and runs the network-match
    /// guard. For the design, "valid" = a non-empty input that either
    /// resolves to a name OR looks address-shaped (length floor).
    /// `// TODO: (T-062)` replace with real validation.
    var isRecipientValid: Bool {
        let trimmed = recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedName != nil { return true }
        // Address-shaped placeholder: at least 20 chars, no spaces.
        return trimmed.count >= 20 && !trimmed.contains(" ")
    }

    /// A short, display-ready recipient label for the amount / review
    /// chrome — the resolved name when we have one, else a truncated
    /// address.
    var recipientDisplay: String {
        if let name = resolvedName { return name }
        let trimmed = recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return SendDraft.shorten(trimmed)
    }

    /// MOCK: is this the first time the wallet has sent to this address?
    /// Drives the "first-send" warning on Recipient + Review. The real
    /// implementation checks the wallet's transaction history.
    /// `// TODO: (T-062)`.
    var isFirstSend: Bool {
        // For the design, treat every recipient that isn't in the mock
        // "recents" set as a first send.
        !SendMockData.recents.contains { $0.address == recipientInput }
    }

    // MARK: - Asset

    /// The asset the user is sending. `nil` until the flow picks one
    /// (the entry from the wallet-home passes a preselected asset; the
    /// asset picker can change it). Covers every chain/token via
    /// `SendAsset`.
    var asset: SendAsset?

    /// The chain the send executes on. For a native asset it's the
    /// asset's chain; for a token it's the network the user picked.
    var network: SupportedChain? {
        asset?.network
    }

    /// The ticker shown beside the big amount numerals (`ETH`, `USDC`).
    var unitTicker: String {
        asset?.unitTicker ?? ""
    }

    // MARK: - Amount

    /// The amount the user is typing, as the raw decimal string the
    /// keypad builds (`"1.5"`, `"0."`, `""`). Kept as a string so the
    /// keypad owns digit grouping / decimal-point rules and the big
    /// numerals render exactly what was typed (trailing `.` and all).
    var amountInput: String = ""

    /// Whether the amount field is showing fiat instead of crypto (the
    /// flip). When `true`, the big numerals are the fiat figure and the
    /// secondary line shows the crypto equivalent.
    var isShowingFiat: Bool = false

    /// MOCK available balance for the selected asset, in chain units.
    /// `// TODO: (T-061)` real balance read.
    var availableBalance: Decimal {
        SendMockData.sampleBalance(for: asset)
    }

    /// MOCK unit → fiat rate for the selected asset. `// TODO: (T-061)`.
    var unitFiatRate: Decimal {
        SendMockData.sampleFiatRate(for: asset)
    }

    /// The typed amount parsed to a `Decimal` (0 when empty / mid-typing
    /// a lone `.`). Always expressed in **crypto units** regardless of
    /// the fiat flip — the flip only changes presentation, the draft's
    /// canonical amount is crypto.
    var cryptoAmount: Decimal {
        let parsed = Decimal(string: normalizedAmountString) ?? .zero
        guard isShowingFiat else { return parsed }
        // When typing in fiat, convert back to crypto for the canonical
        // amount. Guard divide-by-zero on a missing rate.
        guard unitFiatRate > 0 else { return .zero }
        return parsed / unitFiatRate
    }

    /// The fiat equivalent of the current crypto amount, in the user's
    /// active currency. Used for the secondary "≈" line and the Review
    /// total.
    var fiatAmount: Decimal {
        cryptoAmount * unitFiatRate
    }

    /// Whether the amount is enough to proceed to Review — positive and
    /// within the available balance. The fee is added on Review; the
    /// real implementation reserves the fee from the balance here too.
    /// `// TODO: (T-063)` fee-aware max.
    var isAmountValid: Bool {
        cryptoAmount > 0 && cryptoAmount <= availableBalance
    }

    /// Set the amount field to the full available balance (the MAX
    /// button). A real implementation subtracts the network fee for
    /// native sends so the user isn't left unable to cover gas.
    /// `// TODO: (T-063)`.
    func applyMax() {
        isShowingFiat = false
        amountInput = WalletFormatting.native(
            availableBalance,
            decimals: network?.nativeDecimals ?? 8
        )
    }

    // MARK: - Fee

    /// The fee preset the user has chosen. Defaults to `.recommended` so
    /// the flow is sane without ever opening the Advanced sheet (the
    /// handoff's "smart defaults" principle).
    var feeSelection: SendFeeSelection = .recommended

    /// Per-chain advanced parameters the Advanced sheet edits. Shaped by
    /// family; only the fields relevant to the selected network are read.
    var advanced: SendAdvancedParams = .init()

    /// MOCK resolved network fee in fiat, for the Review row + total.
    /// `// TODO: (T-063)` real estimation.
    var networkFeeFiat: Decimal {
        SendMockData.sampleFeeFiat(for: network, selection: feeSelection)
    }

    /// MOCK resolved network fee in the chain's native units, for the
    /// non-EVM/BTC "simple fee display" chains. `// TODO: (T-063)`.
    var networkFeeNative: Decimal {
        SendMockData.sampleFeeNative(for: network, selection: feeSelection)
    }

    /// The Review total in fiat (amount + fee). Honest: for token sends
    /// the fee is paid in the network's native asset, so the total is an
    /// approximate fiat sum — the Review copy says so.
    var totalFiat: Decimal {
        fiatAmount + networkFeeFiat
    }

    // MARK: - Outcome (design-time)

    /// The terminal outcome the design walks to. The real flow sets this
    /// from the broadcast result; for the design, `.sent` is reached
    /// after the swipe + (mock) authorize, and `.failed` is reachable
    /// from a debug affordance so the failure screen can be reviewed.
    /// `// TODO: (T-066)` real broadcast result.
    var outcome: SendOutcome = .pending

    /// MOCK transaction hash shown on the Sent screen's "View on
    /// explorer". `// TODO: (T-066)`.
    var transactionHash: String {
        SendMockData.sampleTransactionHash
    }

    // MARK: - Helpers

    /// Normalize the amount string for parsing: empty → "0", a lone
    /// trailing decimal point ("1." ) → strip it for the numeric parse
    /// (the display keeps the dot; the parse doesn't need it).
    private var normalizedAmountString: String {
        if amountInput.isEmpty { return "0" }
        if amountInput == "." { return "0" }
        if amountInput.hasSuffix(".") { return String(amountInput.dropLast()) }
        return amountInput
    }

    /// Truncate an address to `prefix…suffix` form for chrome labels.
    static func shorten(_ value: String, prefix: Int = 6, suffix: Int = 4) -> String {
        WalletFormatting.shortAddress(value, prefix: prefix, suffix: suffix)
    }

    /// Reset the draft for a fresh send (called when the flow root
    /// appears so a re-entry starts clean).
    func reset() {
        recipientInput = ""
        asset = nil
        amountInput = ""
        isShowingFiat = false
        feeSelection = .recommended
        advanced = .init()
        outcome = .pending
    }
}

// MARK: - Fee selection

/// The fee preset the user picks. Two presets cover the common case per
/// the handoff (Economy/Normal vs Fast); `.custom` is engaged when the
/// user drags the Advanced sheet's slider off a preset.
enum SendFeeSelection: Hashable, Sendable {
    /// The slower / cheaper preset (Bitcoin "Economy", EVM "Normal",
    /// Solana "None").
    case economy
    /// The recommended default — lands fast, sane price. The flow's
    /// out-of-the-box selection.
    case recommended
    /// A user-tuned custom value from the Advanced sheet's slider.
    case custom
}

// MARK: - Outcome

/// Terminal state of a send for the design walk-through.
enum SendOutcome: Hashable, Sendable {
    /// Not yet committed — the default through recipient / amount /
    /// review / authorize.
    case pending
    /// Broadcast accepted (design-time: reached after swipe + authorize).
    case sent
    /// Broadcast rejected / failed. Reachable so the failure surface can
    /// be designed and reviewed.
    case failed
}
