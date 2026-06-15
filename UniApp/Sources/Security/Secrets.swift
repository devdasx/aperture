import Foundation

/// Runtime access to the API keys Aperture needs (Li.Fi swap/bridge, ANKR
/// RPC, 0x/1inch alternates). The real values live in `Secrets.xcconfig`
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

    /// ANKR Advanced multi-chain RPC. Optional (public RPC is the fallback).
    static let ankrAPIToken: String = value("ANKR_API_TOKEN")

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

    /// `true` when the swap engine has the Li.Fi key it needs. Callers gate
    /// on this and show an honest "Swap unavailable" state otherwise.
    static var hasLifiKey: Bool { !lifiAPIKey.isEmpty }
}
