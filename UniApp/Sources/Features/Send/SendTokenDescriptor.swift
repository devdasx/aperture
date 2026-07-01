import Foundation

/// Exact token identity selected in the Send flow.
///
/// A ticker is not enough for sending: "USDT" can mean ERC-20, TRC-20,
/// SPL, NEP-141, TON Jetton, and more. This value carries the chain,
/// on-chain identifier, and decimals from the database-backed catalog or
/// custom token row all the way into `SendDraft`.
struct SendTokenDescriptor: Codable, Hashable, Sendable, Identifiable {
    let symbol: String
    let name: String
    let chain: SupportedChain
    let contract: String
    let decimals: Int
    let source: Source

    enum Source: String, Codable, Sendable {
        case catalog
        case custom
    }

    var id: String {
        "\(chain.rawValue)|\(contractKey)"
    }

    var contractKey: String {
        chain.family == .evm ? contract.lowercased() : contract
    }

    /// Tokens we can honestly submit through the current signer stack.
    /// Native DOT is sendable, but Polkadot Asset Hub tokens need a
    /// separate parachain endpoint and extrinsic path.
    var isSendSupported: Bool {
        chain != .polkadot
    }

    init(
        symbol: String,
        name: String,
        chain: SupportedChain,
        contract: String,
        decimals: Int,
        source: Source
    ) {
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleanName.isEmpty ? self.symbol : cleanName
        self.chain = chain
        self.contract = contract
        self.decimals = decimals
        self.source = source
    }

    init(catalog asset: CatalogAsset) {
        self.init(
            symbol: asset.symbol,
            name: asset.name,
            chain: asset.chain,
            contract: asset.contract,
            decimals: asset.decimals,
            source: .catalog
        )
    }

    init(custom token: CustomTokenSnapshot) {
        self.init(
            symbol: token.symbol,
            name: token.name,
            chain: token.chain,
            contract: token.contract,
            decimals: token.decimals,
            source: .custom
        )
    }
}
