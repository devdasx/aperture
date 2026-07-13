import Foundation

/// Shared bounds for activity history fetches and persistence.
///
/// **Per-address** limits apply when a scanner already targets one address
/// (Solana dual-path, EVM, TRON, …) so each path keeps its own deep history.
///
/// **maxDetailFetches** caps unique tx detail RPCs when Electrum returns
/// many addresses × many hashes (bitcoin-family).
enum HistoryScanLimits {
    /// Newest history legs to keep **per wallet address** (not wallet-wide).
    static let perAddress = 200

    /// Max unique transaction detail fetches in one multi-address Electrum scan.
    static let maxDetailFetches = 500
}
