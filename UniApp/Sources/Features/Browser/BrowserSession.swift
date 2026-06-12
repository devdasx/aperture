import Foundation

/// An active dApp connection — either an injected EIP-1193 session
/// from a page the user is currently browsing, OR a WalletConnect v2
/// session paired via the in-app QR scanner.
///
/// **Why an in-memory struct, not a SwiftData model.** Sessions are
/// transient — they live for as long as the page is open (injected)
/// or as long as the WalletConnect pairing remains active. They are
/// resumed cold via the WalletConnect SDK's own session store (the
/// Reown WalletKit owns persistence), not by us. The in-memory
/// `BrowserSession` is a UI-side projection so the `Connected`
/// section on `BrowserHomeView` can read a flat list without
/// reaching into the SDK on every body evaluation.
///
/// **Population.** Owned by `WalletConnectClient.sessions` (the
/// async sequence the home view subscribes to) plus
/// `DAppRequestRouter.injectedSessions` (the live injected pages).
/// The home view merges both streams into one section.
struct BrowserSession: Identifiable, Hashable, Sendable {
    /// Stable identifier — `wc:<topic>` for WalletConnect sessions,
    /// `injected:<host>:<UUID>` for injected pages.
    let id: String

    /// dApp's published name (from the WalletConnect proposer
    /// metadata or the `<title>` of the injected page).
    let dAppName: String

    /// Brand mark / favicon URL, if the dApp published one. `nil`
    /// when the page didn't expose a favicon — the row falls back
    /// to the letter chip in that case.
    let dAppIcon: URL?

    /// Hostname — the canonical "where you are" string. Always
    /// shown; even when `dAppIcon` is nil, the user reads the host.
    let dAppHost: String

    /// Chain the session is bound to. For WalletConnect this is the
    /// `requiredNamespaces.eip155.chains[0]` mapped to our
    /// `SupportedChain`; for injected pages it's the active wallet's
    /// default EVM chain.
    let chain: SupportedChain

    /// When the session started — drives the "Connected 4m" footer.
    let connectedAt: Date

    /// How the dApp reached the wallet. `.injected` for the in-app
    /// browser's EIP-1193 channel; `.walletConnect` for paired
    /// sessions over WalletConnect's relay.
    let transport: Transport

    enum Transport: String, Sendable, Hashable {
        case injected
        case walletConnect
    }
}
