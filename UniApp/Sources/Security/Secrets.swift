import Foundation

/// Runtime access to the API keys Aperture needs (Li.Fi swap/bridge,
/// 0x/1inch swap alternates, 1rpc). The real values live in `Secrets.xcconfig`
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

    /// Li.Fi — the swap + cross-chain bridge aggregator (EVM + Solana).
    /// REQUIRED for Swap. https://docs.li.fi/ (API base: https://li.quest/v1)
    static let lifiAPIKey: String = value("LIFI_API_KEY")

    /// 0x swap API — optional alternate EVM swap aggregator.
    static let zeroXAPIKey: String = value("ZEROX_API_KEY")

    /// 1inch swap API — optional alternate EVM swap aggregator.
    static let oneInchAPIKey: String = value("ONEINCH_API_KEY")

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

    /// `true` when the swap engine has the Li.Fi key it needs. Callers gate
    /// on this and show an honest "Swap unavailable" state otherwise.
    static var hasLifiKey: Bool { !lifiAPIKey.isEmpty }
}
