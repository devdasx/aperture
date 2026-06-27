import Foundation

/// Runtime access to the API keys Aperture needs (1rpc, Infura, Etherscan). The real
/// values live in `Secrets.xcconfig`
/// (gitignored, local only); `project.yml` injects them into the app's
/// `Info.plist` via `$(KEY)` substituted at build time, and this enum reads
/// them back via `Bundle.main.object(forInfoDictionaryKey:)`.
///
/// **Security (Rule #16 / common-security).** No key is ever hard-coded in
/// source. The committed `UniApp/Info.plist` carries only `$(KEY)` tokens,
/// never the values. A missing key resolves to `""` so a misconfigured
/// checkout fails *honestly* (the feature reports "unavailable") instead of
/// shipping a fake/empty request — callers must check `isConfigured`.
enum Secrets {

    private static func value(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unsubstituted token (`$(KEY)`) means the xcconfig didn't define
        // it — treat as unset so callers degrade honestly.
        return trimmed.hasPrefix("$(") ? "" : trimmed
    }

    /// 1rpc.io — authenticated multi-chain RPC. When set, the RPC registry
    /// uses the keyed path (`https://1rpc.io/<key>/<chain>`) for far higher
    /// rate limits than the unauthenticated public tier (which returns a
    /// "usage limit reached" error under load). Optional — the registry's
    /// other public endpoints remain the fallback when this is empty.
    static let oneRPCKey: String = value("ONERPC_API_KEY")

    /// `true` when the 1rpc key is configured, so the registry can switch
    /// the 1rpc endpoints to the authenticated path.
    static var hasOneRPCKey: Bool { !oneRPCKey.isEmpty }

    /// Infura — the user's PAID multi-chain EVM RPC. When set, the registry
    /// routes EVM reads through Infura FIRST (the paid primary), with keyed
    /// 1rpc + publicnode as fallbacks. URL: `https://<slug>.infura.io/v3/<key>`
    /// (`mainnet` for Ethereum, `<chain>-mainnet` for the rest). Infura is
    /// EVM-only — it does not serve Bitcoin/Doge/LTC/Stellar/Tron/Solana.
    static let infuraAPIKey: String = value("INFURA_API_KEY")

    /// `true` when the Infura key is configured, so the registry adds the
    /// keyed Infura endpoint as the EVM primary.
    static var hasInfuraKey: Bool { !infuraAPIKey.isEmpty }

    /// Etherscan API V2 — optional multi-chain account-history provider.
    /// Used only for EVM transaction history when configured; public
    /// no-key explorers remain the default fallback path.
    static let etherscanAPIKey: String = value("ETHERSCAN_API_KEY")

    /// `true` when the Etherscan V2 key is configured.
    static var hasEtherscanKey: Bool { !etherscanAPIKey.isEmpty }

    /// TRONSCAN Pro API — optional richer TRON account/token provider.
    /// When set, TRON balance refresh reads TRONSCAN's token rows first
    /// (including `tokenPriceInTrx`) and falls back to TronGrid/PublicNode
    /// when the key is absent or the API rejects the request.
    static let tronScanAPIKey: String = value("TRONSCAN_API_KEY")

    /// `true` when the TRONSCAN Pro API key is configured.
    static var hasTronScanAPIKey: Bool { !tronScanAPIKey.isEmpty }

    // Alchemy keys were removed (2026-06-21): EVM data fetching is disabled and
    // `AlchemyConnector` / `AlchemyService` were deleted, so the key is dead.
    // Li.Fi / 0x / 1inch swap keys were removed (2026-06-23) with the swap feature.
}
