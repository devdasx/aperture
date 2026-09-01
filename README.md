# Aperture

**A free, open-source self-custody crypto wallet for iPhone and iPad.**

Aperture lets you hold, send, and receive Bitcoin, Ethereum, Solana, and assets across 22 additional production mainnets while keeping control of your wallet credentials. There is no Aperture account, custody service, swap engine, in-app Web3 browser, or dApp approval layer.

[Download on the App Store](https://apps.apple.com/us/app/aperture-btc-crypto-wallet/id6780187283) · [Website](https://aperturex.io/) · [Security model](https://aperturex.io/security/) · [Supported networks](https://aperturex.io/networks/) · [Journal](https://aperturex.io/articles/)

## What Aperture is built for

- **Self-custody:** wallet credentials are created and used on the device. Aperture cannot sign for you or recover a lost recovery phrase.
- **Open source:** the production code is available under the MIT License for inspection, building, and independent review.
- **Clear network boundaries:** accounts, address formats, native assets, token identities, fees, and transaction status remain network-specific.
- **Focused attack surface:** Aperture deliberately omits buying, selling, swapping, an in-wallet browser, and standing dApp approvals.
- **Native Apple experience:** SwiftUI interface for iPhone and iPad with Face ID or device-passcode app locking, accessibility, localization, and platform-native navigation.
- **Portable recovery:** standard recovery-phrase and private-key import paths, optional BIP-39 passphrases, encrypted backup, and direct encrypted iPhone-to-iPhone transfer.

## Supported production mainnets

| Family | Networks |
| --- | --- |
| Bitcoin-style | Bitcoin, Bitcoin Cash, Litecoin, Dogecoin |
| EVM | Ethereum, BNB Smart Chain, Arbitrum One, Base, Polygon PoS, OP Mainnet, Avalanche C-Chain, Gnosis Chain, Linea, Scroll, Taiko Alethia, Telos EVM, X Layer |
| Other account models | Solana, TRON, TON, Sui, Aptos, NEAR Protocol, Stellar, XRP Ledger |

Network support means Aperture derives and validates the correct account identity for that mainnet. A matching ticker, logo, or hexadecimal-looking address does not make two networks interchangeable. See the [network catalog](https://aperturex.io/networks/) for address, fee, token, and transaction details for every supported chain.

## Security boundary

Aperture stores sensitive wallet material locally using Apple Keychain with this-device-only protection. Recovery phrases, private keys, passcodes, passcode verifiers, API credentials, and encryption keys are not stored in the app database. Signing happens on the device; only public account data and signed transactions are sent to network infrastructure when required for wallet operation.

Self-custody also means there is no company-held recovery copy. Before funding a wallet, verify your recovery method and understand the effect of any optional BIP-39 passphrase. Start with the [security model](https://aperturex.io/security/) and the guide to [backup and restore](https://aperturex.io/articles/lose-phone-not-wallet-backup-restore-aperture/).

## Build from source

Requirements:

- Xcode 26.5 or newer
- iOS 26.0 / iPadOS 26.0 deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
git clone https://github.com/devdasx/aperture.git
cd aperture
cp Secrets.xcconfig.template Secrets.xcconfig
xcodegen generate
open Aperture.xcodeproj
```

`Secrets.xcconfig.template` documents the optional provider credentials without containing secrets. Keep the real `Secrets.xcconfig` local and uncommitted.

## Documentation for people and agents

- Human-readable product documentation: [aperturex.io](https://aperturex.io/)
- Full network catalog: [aperturex.io/networks](https://aperturex.io/networks/)
- Self-custody guides and product notes: [Aperture Journal](https://aperturex.io/articles/)
- Machine-readable overview: [`llms.txt`](https://aperturex.io/llms.txt)
- Extended machine-readable documentation: [`llms-full.txt`](https://aperturex.io/llms-full.txt)
- OpenAPI description: [`openapi.json`](https://aperturex.io/openapi.json)
- Official MCP Registry server: `io.aperturex/aperture-wallet-knowledge`
- Read-only MCP endpoint: `https://aperturex.io/mcp/`
- Static MCP server card: [`/.well-known/mcp/server-card.json`](https://aperturex.io/.well-known/mcp/server-card.json)
- Agent connection guide: [`llms-install.md`](llms-install.md)

Connect from any MCP client that supports remote Streamable HTTP:

```json
{
  "mcpServers": {
    "aperture-wallet-knowledge": {
      "type": "http",
      "url": "https://aperturex.io/mcp/"
    }
  }
}
```

The server is public, requires no authentication, and exposes only read-only
product knowledge. It cannot access a wallet, inspect balances, process wallet
credentials, sign, authorize, or broadcast transactions.

## Contributing and responsible disclosure

Issues and pull requests are welcome when they include a reproducible problem, a narrowly scoped change, and appropriate validation. Do not post exploitable security details in a public issue; use the [responsible-disclosure instructions](https://aperturex.io/bug-bounty/) instead.

## License

Aperture is released under the [MIT License](LICENSE).

Cryptocurrency transactions may be irreversible. Verify the network, asset, destination, amount, and fee before authorizing a transfer. Aperture does not provide investment, tax, or legal advice.
