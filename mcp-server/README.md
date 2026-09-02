# Aperture Wallet Knowledge MCP server

This directory contains the source for Aperture's production, read-only Model Context Protocol server at `https://aperturex.io/mcp/`.

The server exposes 12 tools for public Aperture Wallet product facts, supported production mainnets, security and recovery boundaries, public release information, semantic app-screen documentation, safe navigation entry points, and Aperture Journal articles. It cannot inspect or change a wallet.

## Safety and permission boundary

- No authentication or account is required.
- No wallet connection, recovery phrase, private key, BIP-39 passphrase, app passcode, balance, signing, broadcasting, import, export, or transaction capability exists.
- Every tool is read-only, non-destructive, and idempotent.
- The service does not execute commands or arbitrary code.
- The service does not write to the filesystem. It reads only the bundled public JSON files under `data/`.
- The only outbound request is a declared HTTPS `GET` to Aperture's public Supabase article API. If that request fails, the bundled `data/article-snapshot.json` is used.
- The service contains no analytics, cookies, user profiles, or request-persistence code.
- Request bodies are limited to 256 KiB and tool arguments are schema-validated and length-bounded.

`articles/lib.php` contains a Supabase publishable client key. Publishable keys are intentionally public client identifiers; this one can only read rows and objects allowed by the project's public Row Level Security and storage policies. It is not a service-role key and grants no administrative access.

Never submit a recovery phrase, private key, BIP-39 passphrase, app passcode, backup secret, or other user wallet data to this or any AI service.

## Source layout

```text
mcp-server/
├── mcp/
│   ├── index.php       # Streamable HTTP and JSON-RPC request handling
│   ├── tools.php       # tool schemas, annotations, validation, and dispatch
│   └── health.php      # public health response
├── agent/
│   └── bootstrap.php   # public knowledge loading, search, and citation documents
├── articles/
│   └── lib.php         # read-only Journal adapter and HTML sanitization
└── data/               # canonical public product data and Journal fallback snapshot
```

## Run locally

Requirements:

- PHP 8.1 or newer
- JSON and mbstring extensions
- cURL, or `allow_url_fopen` for the HTTPS article request fallback
- DOM extension recommended for full article sanitization

From the repository root:

```sh
php -S 127.0.0.1:8787 -t mcp-server
```

The local MCP endpoint is `http://127.0.0.1:8787/mcp/` and the local health endpoint is `http://127.0.0.1:8787/mcp/health.php`.

Initialize a session:

```sh
curl --fail-with-body \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"local-review","version":"1.0.0"}}}' \
  http://127.0.0.1:8787/mcp/
```

List the tools:

```sh
curl --fail-with-body \
  --request POST \
  --header 'Content-Type: application/json' \
  --header 'MCP-Protocol-Version: 2025-11-25' \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  http://127.0.0.1:8787/mcp/
```

## Production connection

MCP clients that support remote Streamable HTTP can connect directly:

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

The canonical install guide, protocol metadata, tool inventory, and REST/OpenAPI fallback are published at `https://aperturex.io/agents/`.

## Source synchronization

These files are published from the production website source tree:

| Public path | Production source path |
| --- | --- |
| `mcp-server/mcp/` | `Website/mcp/` |
| `mcp-server/agent/bootstrap.php` | `Website/agent/bootstrap.php` |
| `mcp-server/articles/lib.php` | `Website/articles/lib.php` |
| `mcp-server/data/` | `Website/data/` |

Reviewers can compare the public tool definitions with `https://aperturex.io/.well-known/mcp/server-card.json` and exercise the live endpoint without credentials.

## License

This source is covered by the repository's MIT License.
