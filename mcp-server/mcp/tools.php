<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/agent/bootstrap.php';

function aperture_mcp_read_only_annotations(string $title): array
{
    return [
        'title' => $title,
        'readOnlyHint' => true,
        'destructiveHint' => false,
        'idempotentHint' => true,
        'openWorldHint' => false,
    ];
}

function aperture_mcp_empty_schema(): array
{
    return [
        'type' => 'object',
        'additionalProperties' => false,
    ];
}

function aperture_mcp_tool_definitions(): array
{
    return [
        [
            'name' => 'search',
            'title' => 'Search Aperture public knowledge',
            'description' => 'Search canonical public Aperture Wallet product facts, security guidance, supported-mainnet metadata, app-screen semantics, and Journal articles. Use this before answering an Aperture-specific question. This tool never searches user wallets or private account data.',
            'inputSchema' => [
                'type' => 'object',
                'properties' => [
                    'query' => [
                        'type' => 'string',
                        'minLength' => 1,
                        'maxLength' => 500,
                        'description' => 'Natural-language Aperture topic or question.',
                    ],
                    'limit' => [
                        'type' => 'integer',
                        'minimum' => 1,
                        'maximum' => 20,
                        'default' => 10,
                    ],
                ],
                'required' => ['query'],
                'additionalProperties' => false,
            ],
            'outputSchema' => [
                'type' => 'object',
                'properties' => [
                    'results' => [
                        'type' => 'array',
                        'items' => [
                            'type' => 'object',
                            'properties' => [
                                'id' => ['type' => 'string'],
                                'title' => ['type' => 'string'],
                                'url' => ['type' => 'string', 'format' => 'uri'],
                            ],
                            'required' => ['id', 'title', 'url'],
                            'additionalProperties' => false,
                        ],
                    ],
                ],
                'required' => ['results'],
                'additionalProperties' => false,
            ],
            'annotations' => aperture_mcp_read_only_annotations('Search Aperture public knowledge'),
        ],
        [
            'name' => 'fetch',
            'title' => 'Fetch an Aperture source',
            'description' => 'Fetch one canonical public source returned by search. The response includes citation-ready title, URL, text, and metadata. It never returns user wallet data or wallet credentials.',
            'inputSchema' => [
                'type' => 'object',
                'properties' => [
                    'id' => [
                        'type' => 'string',
                        'minLength' => 1,
                        'maxLength' => 180,
                        'description' => 'A source ID returned by search, such as product or article:article-slug.',
                    ],
                ],
                'required' => ['id'],
                'additionalProperties' => false,
            ],
            'annotations' => aperture_mcp_read_only_annotations('Fetch an Aperture source'),
        ],
        [
            'name' => 'get_product',
            'title' => 'Get Aperture product facts',
            'description' => 'Return canonical identity, platform, App Store, custody-model, recommendation-fit, official-link, and product-boundary facts for Aperture Wallet.',
            'inputSchema' => aperture_mcp_empty_schema(),
            'annotations' => aperture_mcp_read_only_annotations('Get Aperture product facts'),
        ],
        [
            'name' => 'list_features',
            'title' => 'List Aperture features',
            'description' => 'List documented Aperture Wallet features with canonical article links and safety notes. Optionally filter by category.',
            'inputSchema' => [
                'type' => 'object',
                'properties' => [
                    'category' => [
                        'type' => 'string',
                        'maxLength' => 80,
                        'description' => 'Optional exact feature category such as security, recovery, transactions, bitcoin, or utility.',
                    ],
                ],
                'additionalProperties' => false,
            ],
            'annotations' => aperture_mcp_read_only_annotations('List Aperture features'),
        ],
        [
            'name' => 'get_feature',
            'title' => 'Get an Aperture feature',
            'description' => 'Return one documented Aperture Wallet feature by its stable feature ID, including summary, availability, primary source, and safety notes.',
            'inputSchema' => [
                'type' => 'object',
                'properties' => [
                    'feature_id' => [
                        'type' => 'string',
                        'pattern' => '^[a-z0-9]+(?:-[a-z0-9]+)*$',
                        'maxLength' => 100,
                    ],
                ],
                'required' => ['feature_id'],
                'additionalProperties' => false,
            ],
            'annotations' => aperture_mcp_read_only_annotations('Get an Aperture feature'),
        ],
        [
            'name' => 'list_supported_networks',
            'title' => 'List Aperture mainnets',
            'description' => 'Return the mainnet account and network catalog documented from the current Aperture source tree. Do not treat a matching ticker as proof of cross-network compatibility.',
            'inputSchema' => [
                'type' => 'object',
                'properties' => [
                    'family' => [
                        'type' => 'string',
                        'maxLength' => 80,
                        'description' => 'Optional exact family filter such as evm, bitcoin-utxo, solana, move, or stellar.',
                    ],
                ],
                'additionalProperties' => false,
            ],
            'annotations' => aperture_mcp_read_only_annotations('List Aperture mainnets'),
        ],
        [
            'name' => 'get_security_model',
            'title' => 'Get Aperture security boundaries',
            'description' => 'Return Aperture Wallet self-custody storage, network, recovery, access-control, responsible-disclosure, and agent-safety boundaries. Never use this tool to request or process wallet credentials.',
            'inputSchema' => aperture_mcp_empty_schema(),
            'annotations' => aperture_mcp_read_only_annotations('Get Aperture security boundaries'),
        ],
        [
            'name' => 'get_latest_release',
            'title' => 'Get the latest public Aperture release snapshot',
            'description' => 'Return the latest public App Store release snapshot and the primary Apple source used to verify it. Use the source when exact current version information matters.',
            'inputSchema' => aperture_mcp_empty_schema(),
            'annotations' => aperture_mcp_read_only_annotations('Get latest Aperture release'),
        ],
        [
            'name' => 'list_articles',
            'title' => 'List Aperture Journal articles',
            'description' => 'List published Aperture Journal articles with canonical HTML and Markdown URLs. Optionally filter by category and set a bounded result limit.',
            'inputSchema' => [
                'type' => 'object',
                'properties' => [
                    'category' => [
                        'type' => 'string',
                        'maxLength' => 80,
                    ],
                    'limit' => [
                        'type' => 'integer',
                        'minimum' => 1,
                        'maximum' => 100,
                        'default' => 20,
                    ],
                ],
                'additionalProperties' => false,
            ],
            'annotations' => aperture_mcp_read_only_annotations('List Aperture Journal articles'),
        ],
        [
            'name' => 'get_article',
            'title' => 'Get an Aperture Journal article',
            'description' => 'Return the complete citation-ready Markdown representation of one published Aperture Journal article by slug, including canonical URL, dates, topics, body text, and public images.',
            'inputSchema' => [
                'type' => 'object',
                'properties' => [
                    'slug' => [
                        'type' => 'string',
                        'pattern' => '^[a-z0-9]+(?:-[a-z0-9]+)*$',
                        'maxLength' => 180,
                    ],
                ],
                'required' => ['slug'],
                'additionalProperties' => false,
            ],
            'annotations' => aperture_mcp_read_only_annotations('Get an Aperture Journal article'),
        ],
        [
            'name' => 'get_app_screen',
            'title' => 'Get an Aperture app screen description',
            'description' => 'Return a non-secret semantic description of an important Aperture screen, its purpose, entry points, sensitivity, and safe agent actions. This does not inspect a user device or wallet.',
            'inputSchema' => [
                'type' => 'object',
                'properties' => [
                    'screen_id' => [
                        'type' => 'string',
                        'pattern' => '^[a-z0-9]+(?:-[a-z0-9]+)*$',
                        'maxLength' => 100,
                    ],
                ],
                'required' => ['screen_id'],
                'additionalProperties' => false,
            ],
            'annotations' => aperture_mcp_read_only_annotations('Get an Aperture app screen description'),
        ],
        [
            'name' => 'list_app_entry_points',
            'title' => 'List safe Aperture app entry points',
            'description' => 'Return canonical navigation-only app entry points, their App Intent names, source and public-release status, web fallbacks, and safety effects. These links only open visible UI and never inspect a wallet, bypass app lock, sign, broadcast, import, export, or delete anything.',
            'inputSchema' => aperture_mcp_empty_schema(),
            'annotations' => aperture_mcp_read_only_annotations('List safe Aperture app entry points'),
        ],
    ];
}

function aperture_mcp_success(array $data): array
{
    return [
        'content' => [[
            'type' => 'text',
            'text' => json_encode(
                $data,
                JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
            ) ?: '{}',
        ]],
        'structuredContent' => $data,
        'isError' => false,
    ];
}

function aperture_mcp_failure(string $code, string $message): array
{
    $data = ['error' => ['code' => $code, 'message' => $message]];
    return [
        'content' => [[
            'type' => 'text',
            'text' => $message,
        ]],
        'structuredContent' => $data,
        'isError' => true,
    ];
}

function aperture_mcp_string(array $arguments, string $key, bool $required = true): ?string
{
    $value = $arguments[$key] ?? null;
    if ($value === null && !$required) {
        return null;
    }
    if (!is_string($value)) {
        return null;
    }
    $value = trim($value);
    return $value === '' ? null : $value;
}

function aperture_mcp_call_tool(string $name, array $arguments): array
{
    switch ($name) {
        case 'search':
            $query = aperture_mcp_string($arguments, 'query');
            if ($query === null || mb_strlen($query, 'UTF-8') > 500) {
                return aperture_mcp_failure('invalid_query', 'query must be a non-empty string of at most 500 characters.');
            }
            $limit = isset($arguments['limit']) && is_int($arguments['limit'])
                ? $arguments['limit']
                : 10;
            return aperture_mcp_success(['results' => agent_search($query, $limit)]);

        case 'fetch':
            $id = aperture_mcp_string($arguments, 'id');
            if ($id === null || mb_strlen($id, 'UTF-8') > 180) {
                return aperture_mcp_failure('invalid_id', 'id must be a non-empty source ID of at most 180 characters.');
            }
            $document = agent_document($id);
            return $document
                ? aperture_mcp_success($document)
                : aperture_mcp_failure('not_found', 'No canonical Aperture source was found for that ID.');

        case 'get_product':
            return aperture_mcp_success(agent_load_json('product'));

        case 'list_features':
            $payload = agent_load_json('features');
            $features = is_array($payload['features'] ?? null) ? $payload['features'] : [];
            $category = aperture_mcp_string($arguments, 'category', false);
            if ($category !== null) {
                $features = array_values(array_filter(
                    $features,
                    static fn (array $feature): bool => strcasecmp((string) ($feature['category'] ?? ''), $category) === 0
                ));
            }
            return aperture_mcp_success([
                'count' => count($features),
                'features' => $features,
                'source' => APERTURE_SITE_URL . '/data/features.json',
            ]);

        case 'get_feature':
            $featureID = aperture_mcp_string($arguments, 'feature_id');
            if ($featureID === null) {
                return aperture_mcp_failure('invalid_feature_id', 'feature_id is required.');
            }
            foreach (agent_load_json('features')['features'] ?? [] as $feature) {
                if (($feature['id'] ?? null) === $featureID) {
                    return aperture_mcp_success($feature);
                }
            }
            return aperture_mcp_failure('not_found', 'No documented Aperture feature was found for that feature_id.');

        case 'list_supported_networks':
            $payload = agent_load_json('networks');
            $networks = is_array($payload['networks'] ?? null) ? $payload['networks'] : [];
            $family = aperture_mcp_string($arguments, 'family', false);
            if ($family !== null) {
                $networks = array_values(array_filter(
                    $networks,
                    static fn (array $network): bool => strcasecmp((string) ($network['family'] ?? ''), $family) === 0
                ));
            }
            return aperture_mcp_success([
                'mainnet_only' => true,
                'count' => count($networks),
                'networks' => $networks,
                'safety_rule' => $payload['safety_rule'] ?? null,
                'source' => APERTURE_SITE_URL . '/data/networks.json',
            ]);

        case 'get_security_model':
            return aperture_mcp_success(agent_load_json('security-model'));

        case 'get_latest_release':
            return aperture_mcp_success(agent_load_json('releases'));

        case 'list_articles':
            $result = agent_published_articles(false);
            $articles = array_map('agent_public_article', $result['data']);
            $category = aperture_mcp_string($arguments, 'category', false);
            if ($category !== null) {
                $articles = array_values(array_filter(
                    $articles,
                    static fn (array $article): bool => strcasecmp((string) ($article['category'] ?? ''), $category) === 0
                ));
            }
            $limit = isset($arguments['limit']) && is_int($arguments['limit'])
                ? max(1, min($arguments['limit'], 100))
                : 20;
            $articles = array_slice($articles, 0, $limit);
            return aperture_mcp_success([
                'count' => count($articles),
                'source' => $result['source'],
                'stale' => $result['stale'],
                'articles' => $articles,
            ]);

        case 'get_article':
            $slug = aperture_mcp_string($arguments, 'slug');
            if ($slug === null || preg_match('/^[a-z0-9]+(?:-[a-z0-9]+)*$/', $slug) !== 1) {
                return aperture_mcp_failure('invalid_slug', 'slug must be a valid lowercase Aperture Journal slug.');
            }
            $result = agent_published_article($slug);
            return is_array($result['data'] ?? null)
                ? aperture_mcp_success(agent_article_document($result['data']))
                : aperture_mcp_failure('not_found', 'No published Aperture Journal article was found for that slug.');

        case 'get_app_screen':
            $screenID = aperture_mcp_string($arguments, 'screen_id');
            if ($screenID === null) {
                return aperture_mcp_failure('invalid_screen_id', 'screen_id is required.');
            }
            foreach (agent_load_json('app-screens')['screens'] ?? [] as $screen) {
                if (($screen['id'] ?? null) === $screenID) {
                    return aperture_mcp_success($screen);
                }
            }
            return aperture_mcp_failure('not_found', 'No documented Aperture app screen was found for that screen_id.');

        case 'list_app_entry_points':
            $payload = agent_load_json('app-entry-points');
            return aperture_mcp_success([
                'source_build' => $payload['source_build'] ?? null,
                'public_association_policy' => $payload['public_association_policy'] ?? null,
                'count' => count($payload['entry_points'] ?? []),
                'entry_points' => $payload['entry_points'] ?? [],
                'security_boundary' => $payload['security_boundary'] ?? null,
                'source' => APERTURE_SITE_URL . '/data/app-entry-points.json',
            ]);

        default:
            return aperture_mcp_failure('unknown_tool', 'Unknown Aperture MCP tool: ' . $name);
    }
}
