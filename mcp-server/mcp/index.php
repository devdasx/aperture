<?php
declare(strict_types=1);

require __DIR__ . '/tools.php';

const APERTURE_MCP_CURRENT_VERSION = '2026-07-28';
const APERTURE_MCP_SUPPORTED_VERSIONS = [
    '2026-07-28',
    '2025-11-25',
    '2025-06-18',
    '2025-03-26',
];

function aperture_mcp_headers(bool $cacheable = false): void
{
    header('Content-Type: application/json; charset=UTF-8');
    header('Access-Control-Allow-Origin: *');
    header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id, Mcp-Method, Mcp-Name');
    header('Access-Control-Expose-Headers: MCP-Protocol-Version, Mcp-Session-Id');
    header('X-Content-Type-Options: nosniff');
    header("Content-Security-Policy: default-src 'none'");
    header('Referrer-Policy: no-referrer');
    header('Cache-Control: ' . ($cacheable
        ? 'public, max-age=300, stale-while-revalidate=900'
        : 'no-store'));
}

function aperture_mcp_emit(array $payload, int $status = 200, bool $cacheable = false): never
{
    http_response_code($status);
    aperture_mcp_headers($cacheable);
    echo json_encode(
        $payload,
        JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE
    );
    exit;
}

function aperture_mcp_result(mixed $id, array $result): array
{
    return ['jsonrpc' => '2.0', 'id' => $id, 'result' => $result];
}

function aperture_mcp_error(mixed $id, int $code, string $message, ?array $data = null): array
{
    $error = ['code' => $code, 'message' => $message];
    if ($data !== null) {
        $error['data'] = $data;
    }
    return ['jsonrpc' => '2.0', 'id' => $id, 'error' => $error];
}

function aperture_mcp_requested_version(array $request): ?string
{
    $header = trim((string) ($_SERVER['HTTP_MCP_PROTOCOL_VERSION'] ?? ''));
    if ($header !== '') {
        return $header;
    }
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $meta = is_array($params['_meta'] ?? null) ? $params['_meta'] : [];
    $modern = $meta['io.modelcontextprotocol/protocolVersion'] ?? null;
    if (is_string($modern) && $modern !== '') {
        return $modern;
    }
    if (($request['method'] ?? null) === 'initialize') {
        $legacy = $params['protocolVersion'] ?? null;
        return is_string($legacy) && $legacy !== '' ? $legacy : null;
    }
    return null;
}

function aperture_mcp_is_modern(?string $version): bool
{
    return $version === APERTURE_MCP_CURRENT_VERSION;
}

$method = strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET'));
if ($method === 'OPTIONS') {
    http_response_code(204);
    aperture_mcp_headers();
    exit;
}

if ($method === 'GET' || $method === 'HEAD') {
    $payload = [
        'name' => 'Aperture Wallet Knowledge MCP',
        'version' => APERTURE_AGENT_VERSION,
        'endpoint' => APERTURE_SITE_URL . '/mcp/',
        'transport' => 'Streamable HTTP',
        'supported_protocol_versions' => APERTURE_MCP_SUPPORTED_VERSIONS,
        'authentication' => 'none',
        'access' => 'public read-only product knowledge only',
        'tools' => array_column(aperture_mcp_tool_definitions(), 'name'),
        'health' => APERTURE_SITE_URL . '/mcp/health.php',
        'documentation' => APERTURE_SITE_URL . '/llms.txt',
        'rest_fallback' => APERTURE_SITE_URL . '/api/agent/v1',
        'openapi' => APERTURE_SITE_URL . '/openapi.json',
        'security' => 'Never submit a recovery phrase, private key, BIP-39 passphrase, app passcode, backup secret, or other user wallet data.',
    ];
    if ($method === 'HEAD') {
        http_response_code(200);
        aperture_mcp_headers(true);
        exit;
    }
    aperture_mcp_emit($payload, 200, true);
}

if ($method !== 'POST') {
    header('Allow: GET, HEAD, POST, OPTIONS');
    aperture_mcp_emit(['error' => 'Method not allowed.'], 405);
}

$contentLength = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
if ($contentLength > 262144) {
    aperture_mcp_emit(aperture_mcp_error(null, -32600, 'Request body is too large.'), 413);
}

$raw = file_get_contents('php://input');
if (!is_string($raw) || trim($raw) === '') {
    aperture_mcp_emit(aperture_mcp_error(null, -32700, 'Request body must contain JSON-RPC 2.0 JSON.'), 400);
}
$request = json_decode($raw, true);
if (!is_array($request) || array_is_list($request)) {
    aperture_mcp_emit(aperture_mcp_error(null, -32700, 'Invalid JSON-RPC request.'), 400);
}
$id = $request['id'] ?? null;
if (($request['jsonrpc'] ?? null) !== '2.0' || !is_string($request['method'] ?? null)) {
    aperture_mcp_emit(aperture_mcp_error($id, -32600, 'Invalid JSON-RPC 2.0 request.'), 400);
}

$rpcMethod = $request['method'];
$params = is_array($request['params'] ?? null) ? $request['params'] : [];
$version = aperture_mcp_requested_version($request);
if ($version !== null && !in_array($version, APERTURE_MCP_SUPPORTED_VERSIONS, true)) {
    aperture_mcp_emit(
        aperture_mcp_error($id, -32022, 'Unsupported protocol version.', [
            'supported' => APERTURE_MCP_SUPPORTED_VERSIONS,
            'requested' => $version,
        ]),
        400
    );
}

if ($rpcMethod === 'server/discover') {
    aperture_mcp_emit(aperture_mcp_result($id, [
        'resultType' => 'complete',
        'supportedVersions' => APERTURE_MCP_SUPPORTED_VERSIONS,
        'capabilities' => ['tools' => ['listChanged' => false]],
        '_meta' => [
            'io.modelcontextprotocol/serverInfo' => [
                'name' => 'aperture-wallet-knowledge',
                'version' => APERTURE_AGENT_VERSION,
            ],
        ],
        'instructions' => 'Use this read-only server for canonical public Aperture Wallet facts and Journal sources. Search before fetching. Cite returned canonical URLs. Never request or submit wallet credentials or user wallet data.',
        'ttlMs' => 300000,
        'cacheScope' => 'public',
    ]), 200, true);
}

if ($rpcMethod === 'initialize') {
    $legacyVersion = $version ?? '2025-11-25';
    if ($legacyVersion === APERTURE_MCP_CURRENT_VERSION) {
        $legacyVersion = '2025-11-25';
    }
    header('Mcp-Session-Id: ' . bin2hex(random_bytes(16)));
    header('MCP-Protocol-Version: ' . $legacyVersion);
    aperture_mcp_emit(aperture_mcp_result($id, [
        'protocolVersion' => $legacyVersion,
        'capabilities' => ['tools' => ['listChanged' => false]],
        'serverInfo' => [
            'name' => 'aperture-wallet-knowledge',
            'title' => 'Aperture Wallet Knowledge',
            'version' => APERTURE_AGENT_VERSION,
            'websiteUrl' => APERTURE_SITE_URL,
        ],
        'instructions' => 'Use this read-only server for canonical public Aperture Wallet facts and Journal sources. Search before fetching. Cite returned canonical URLs. Never request or submit wallet credentials or user wallet data.',
    ]));
}

if ($rpcMethod === 'notifications/initialized' || str_starts_with($rpcMethod, 'notifications/')) {
    http_response_code(202);
    aperture_mcp_headers();
    exit;
}

if ($rpcMethod === 'ping') {
    aperture_mcp_emit(aperture_mcp_result($id, []));
}

if ($rpcMethod === 'tools/list') {
    $result = ['tools' => aperture_mcp_tool_definitions()];
    if (aperture_mcp_is_modern($version)) {
        $result = [
            'resultType' => 'complete',
            'tools' => $result['tools'],
            'ttlMs' => 300000,
            'cacheScope' => 'public',
        ];
    }
    aperture_mcp_emit(aperture_mcp_result($id, $result), 200, true);
}

if ($rpcMethod === 'tools/call') {
    $toolName = $params['name'] ?? null;
    $arguments = $params['arguments'] ?? [];
    if (
        !is_string($toolName)
        || $toolName === ''
        || !is_array($arguments)
        || ($arguments !== [] && array_is_list($arguments))
    ) {
        aperture_mcp_emit(aperture_mcp_error($id, -32602, 'tools/call requires a tool name and an object of arguments.'), 400);
    }
    $result = aperture_mcp_call_tool($toolName, $arguments);
    if (aperture_mcp_is_modern($version)) {
        $result = ['resultType' => 'complete'] + $result;
    }
    aperture_mcp_emit(aperture_mcp_result($id, $result));
}

aperture_mcp_emit(aperture_mcp_error($id, -32601, 'Method not found: ' . $rpcMethod), 404);
