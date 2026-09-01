# Connect Aperture Wallet Knowledge over MCP

Aperture Wallet Knowledge is a hosted, public, read-only MCP server. Do not
clone, build, or run the iOS wallet to connect an agent to this documentation
service.

## Connection

Use the production Streamable HTTP endpoint:

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

No API key, OAuth flow, account, environment variable, package installation,
or local process is required.

## Verify the connection

1. Initialize the MCP session at `https://aperturex.io/mcp/`.
2. Call `tools/list` and confirm that the server exposes 12 tools.
3. Confirm every tool declares `readOnlyHint: true`.
4. Call `get_product` or search for `self-custody security model` to verify a
   citation-ready response from the public Aperture knowledge base.

The official Registry identity is
`io.aperturex/aperture-wallet-knowledge` version `1.0.0`. The static server
card is available at
`https://aperturex.io/.well-known/mcp/server-card.json`.

## Safety boundary

This server exposes only public product, security, network, release, screen,
and Journal documentation. It cannot connect to an Aperture wallet, inspect
balances or transaction history, process recovery phrases, private keys,
passphrases, or passcodes, sign or authorize transactions, or broadcast
anything to a blockchain.

Never provide wallet credentials or other secrets to this MCP server. None
are needed for any tool.

