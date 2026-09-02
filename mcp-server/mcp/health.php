<?php
declare(strict_types=1);

require __DIR__ . '/tools.php';

$articles = agent_published_articles(false);
$status = $articles['data'] ? ($articles['stale'] ? 'degraded' : 'ok') : 'unavailable';
agent_json_response([
    'status' => $status,
    'service' => 'aperture-wallet-knowledge-mcp',
    'version' => APERTURE_AGENT_VERSION,
    'protocol_versions' => [
        '2026-07-28',
        '2025-11-25',
        '2025-06-18',
        '2025-03-26',
    ],
    'tools' => count(aperture_mcp_tool_definitions()),
    'article_source' => $articles['source'],
    'article_count' => count($articles['data']),
    'checked_at' => gmdate(DateTimeInterface::ATOM),
], $status === 'unavailable' ? 503 : 200);
