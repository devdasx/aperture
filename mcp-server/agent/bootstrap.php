<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/articles/lib.php';

const APERTURE_AGENT_VERSION = '1.0.0';
const APERTURE_AGENT_REVIEW_DATE = '2026-08-31';

function agent_data_path(string $name): string
{
    return dirname(__DIR__) . '/data/' . $name . '.json';
}

function agent_load_json(string $name): array
{
    if (preg_match('/^[a-z0-9-]+$/', $name) !== 1) {
        return [];
    }
    $path = agent_data_path($name);
    if (!is_file($path) || !is_readable($path)) {
        return [];
    }
    $decoded = json_decode((string) file_get_contents($path), true);
    return is_array($decoded) ? $decoded : [];
}

function agent_snapshot_articles(): array
{
    $snapshot = agent_load_json('article-snapshot');
    return is_array($snapshot['articles'] ?? null)
        ? $snapshot['articles']
        : [];
}

function agent_published_articles(bool $withBody = false): array
{
    $result = $withBody
        ? published_articles_with_body(100)
        : published_articles(100);
    if (!$result['error'] && is_array($result['data'])) {
        return [
            'data' => $result['data'],
            'source' => 'live-publishing-database',
            'stale' => false,
            'error' => null,
        ];
    }

    $snapshot = agent_snapshot_articles();
    if ($snapshot) {
        if (!$withBody) {
            $snapshot = array_map('agent_public_article', $snapshot);
        }
        return [
            'data' => $snapshot,
            'source' => 'deployment-snapshot',
            'stale' => true,
            'error' => $result['error'],
        ];
    }

    return [
        'data' => [],
        'source' => 'unavailable',
        'stale' => false,
        'error' => $result['error'] ?: 'Article data is unavailable.',
    ];
}

function agent_published_article(string $slug): array
{
    if (preg_match('/^[a-z0-9]+(?:-[a-z0-9]+)*$/', $slug) !== 1) {
        return ['data' => null, 'source' => 'invalid', 'stale' => false];
    }

    $result = published_article($slug);
    if (!$result['error'] && isset($result['data'][0])) {
        return [
            'data' => $result['data'][0],
            'source' => 'live-publishing-database',
            'stale' => false,
        ];
    }

    foreach (agent_snapshot_articles() as $article) {
        if (($article['slug'] ?? null) === $slug) {
            return [
                'data' => $article,
                'source' => 'deployment-snapshot',
                'stale' => true,
            ];
        }
    }

    return ['data' => null, 'source' => 'unavailable', 'stale' => false];
}

function agent_public_article(array $article): array
{
    unset($article['body_html'], $article['id']);
    $slug = (string) ($article['slug'] ?? '');
    $article['url'] = article_url($slug);
    $article['markdown_url'] = APERTURE_SITE_URL . '/articles/'
        . rawurlencode($slug) . '.md';
    return $article;
}

function agent_html_to_markdown(string $html): string
{
    $safe = sanitize_article_html($html);
    if ($safe === '') {
        return '';
    }

    $safe = preg_replace_callback(
        '/<img\b[^>]*>/i',
        static function (array $match): string {
            $tag = $match[0];
            $src = '';
            $alt = '';
            if (preg_match('/\bsrc=(?:"([^"]*)"|\'([^\']*)\')/i', $tag, $srcMatch)) {
                $src = html_entity_decode(
                    $srcMatch[1] !== '' ? $srcMatch[1] : ($srcMatch[2] ?? ''),
                    ENT_QUOTES | ENT_HTML5,
                    'UTF-8'
                );
            }
            if (preg_match('/\balt=(?:"([^"]*)"|\'([^\']*)\')/i', $tag, $altMatch)) {
                $alt = html_entity_decode(
                    $altMatch[1] !== '' ? $altMatch[1] : ($altMatch[2] ?? ''),
                    ENT_QUOTES | ENT_HTML5,
                    'UTF-8'
                );
            }
            if (!str_starts_with($src, APERTURE_IMAGE_PREFIX)) {
                return '';
            }
            return "\n![" . str_replace([']', "\n"], ['', ' '], $alt)
                . '](' . $src . ")\n";
        },
        $safe
    ) ?? $safe;

    $replacements = [
        '/<h2\b[^>]*>/i' => "\n\n## ",
        '/<h3\b[^>]*>/i' => "\n\n### ",
        '/<h4\b[^>]*>/i' => "\n\n#### ",
        '/<li\b[^>]*>/i' => "\n- ",
        '/<blockquote\b[^>]*>/i' => "\n\n> ",
        '/<br\s*\/?\s*>/i' => "\n",
        '/<hr\s*\/?\s*>/i' => "\n\n---\n\n",
        '/<\/(p|div|h2|h3|h4|li|blockquote|ul|ol|pre|figure|figcaption|tr|table)>/i' => "\n\n",
    ];
    foreach ($replacements as $pattern => $replacement) {
        $safe = preg_replace($pattern, $replacement, $safe) ?? $safe;
    }

    $text = html_entity_decode(
        strip_tags($safe),
        ENT_QUOTES | ENT_HTML5,
        'UTF-8'
    );
    $text = preg_replace('/[ \t]+\n/', "\n", $text) ?? $text;
    $text = preg_replace('/\n[ \t]+/', "\n", $text) ?? $text;
    $text = preg_replace('/\n{3,}/', "\n\n", $text) ?? $text;
    return trim($text);
}

function agent_article_markdown(array $article): string
{
    $slug = (string) ($article['slug'] ?? '');
    $title = trim((string) ($article['title'] ?? 'Untitled article'));
    $url = article_url($slug);
    $tags = array_values(array_filter(array_map(
        static fn ($tag): string => trim((string) $tag),
        is_array($article['tags'] ?? null) ? $article['tags'] : []
    )));
    $lines = [
        '# ' . $title,
        '',
        '- Canonical URL: ' . $url,
        '- Category: ' . trim((string) ($article['category'] ?? 'Journal')),
        '- Author: ' . trim((string) ($article['author_name'] ?? 'Aperture Editorial')),
        '- Published: ' . iso_article_date($article['published_at'] ?? null),
        '- Updated: ' . iso_article_date($article['updated_at'] ?? null),
        '- Reading time: ' . max(1, (int) ($article['reading_minutes'] ?? 1)) . ' minutes',
    ];
    if ($tags) {
        $lines[] = '- Topics: ' . implode(', ', $tags);
    }
    $lines[] = '';
    $lines[] = trim((string) ($article['excerpt'] ?? ''));
    $lines[] = '';

    $cover = article_image_url($article['cover_image_url'] ?? null);
    if ($cover) {
        $alt = trim((string) ($article['cover_image_alt'] ?? 'Article cover'));
        $lines[] = '![' . str_replace(']', '', $alt) . '](' . $cover . ')';
        $lines[] = '';
    }

    $lines[] = agent_html_to_markdown((string) ($article['body_html'] ?? ''));
    $lines[] = '';
    $lines[] = '---';
    $lines[] = '';
    $lines[] = 'Security: Never share a recovery phrase, private key, BIP-39 passphrase, app passcode, or backup secret with Aperture support or an AI assistant.';
    return trim(implode("\n", $lines)) . "\n";
}

function agent_article_document(array $article): array
{
    $slug = (string) ($article['slug'] ?? '');
    return [
        'id' => 'article:' . $slug,
        'title' => (string) ($article['title'] ?? 'Untitled article'),
        'url' => article_url($slug),
        'text' => agent_article_markdown($article),
        'metadata' => [
            'type' => 'article',
            'slug' => $slug,
            'category' => (string) ($article['category'] ?? 'Journal'),
            'tags' => is_array($article['tags'] ?? null) ? $article['tags'] : [],
            'published_at' => iso_article_date($article['published_at'] ?? null),
            'updated_at' => iso_article_date($article['updated_at'] ?? null),
        ],
    ];
}

function agent_static_document_definitions(): array
{
    return [
        'product' => ['Aperture Wallet product facts', '/data/product.json'],
        'features' => ['Aperture Wallet feature catalog', '/data/features.json'],
        'networks' => ['Aperture Wallet mainnet catalog', '/data/networks.json'],
        'security-model' => ['Aperture Wallet security model', '/data/security-model.json'],
        'app-screens' => ['Aperture app semantic screen catalog', '/data/app-screens.json'],
        'app-entry-points' => ['Aperture safe app entry-point contract', '/data/app-entry-points.json'],
        'releases' => ['Aperture public release information', '/data/releases.json'],
    ];
}

function agent_static_documents(): array
{
    $documents = [];
    foreach (agent_static_document_definitions() as $id => [$title, $path]) {
        $payload = agent_load_json($id);
        if (!$payload) {
            continue;
        }
        $documents[] = [
            'id' => $id,
            'title' => $title,
            'url' => APERTURE_SITE_URL . $path,
            'text' => json_encode(
                $payload,
                JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
            ) ?: '',
            'metadata' => [
                'type' => 'canonical-product-data',
                'last_reviewed' => $payload['last_reviewed'] ?? APERTURE_AGENT_REVIEW_DATE,
            ],
        ];
    }
    return $documents;
}

function agent_documents(): array
{
    $documents = agent_static_documents();
    $articles = agent_published_articles(true);
    foreach ($articles['data'] as $article) {
        $documents[] = agent_article_document($article);
    }
    return $documents;
}

function agent_document(string $id): ?array
{
    if (str_starts_with($id, 'article:')) {
        $result = agent_published_article(substr($id, 8));
        return is_array($result['data'] ?? null)
            ? agent_article_document($result['data'])
            : null;
    }
    foreach (agent_static_documents() as $document) {
        if ($document['id'] === $id) {
            return $document;
        }
    }
    return null;
}

function agent_normalize_search(string $value): string
{
    $value = mb_strtolower(trim($value), 'UTF-8');
    return preg_replace('/\s+/u', ' ', $value) ?? $value;
}

function agent_search(string $query, int $limit = 10): array
{
    $query = agent_normalize_search($query);
    $limit = max(1, min($limit, 20));
    $tokens = array_values(array_unique(array_filter(
        preg_split('/[^\p{L}\p{N}]+/u', $query) ?: [],
        static fn (string $token): bool => mb_strlen($token, 'UTF-8') >= 2
    )));

    $scored = [];
    foreach (agent_documents() as $position => $document) {
        $title = agent_normalize_search((string) $document['title']);
        $id = agent_normalize_search((string) $document['id']);
        $text = agent_normalize_search((string) $document['text']);
        $score = $query === '' ? max(1, 1000 - $position) : 0;
        if ($query !== '' && str_contains($title, $query)) {
            $score += 80;
        }
        if ($query !== '' && str_contains($id, $query)) {
            $score += 40;
        }
        foreach ($tokens as $token) {
            if (str_contains($title, $token)) {
                $score += 14;
            }
            if (str_contains($id, $token)) {
                $score += 8;
            }
            if (str_contains($text, $token)) {
                $score += 2;
            }
        }
        if ($score > 0) {
            $scored[] = ['score' => $score, 'position' => $position, 'document' => $document];
        }
    }
    usort($scored, static function (array $left, array $right): int {
        return ($right['score'] <=> $left['score'])
            ?: ($left['position'] <=> $right['position']);
    });

    return array_map(
        static fn (array $item): array => [
            'id' => $item['document']['id'],
            'title' => $item['document']['title'],
            'url' => $item['document']['url'],
        ],
        array_slice($scored, 0, $limit)
    );
}

function agent_json_response(array $payload, int $status = 200, string $contentType = 'application/json'): never
{
    http_response_code($status);
    header('Content-Type: ' . $contentType . '; charset=UTF-8');
    header('Cache-Control: public, max-age=60, stale-while-revalidate=300');
    header('Access-Control-Allow-Origin: *');
    header('X-Content-Type-Options: nosniff');
    echo json_encode(
        $payload,
        JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE
    );
    exit;
}

function agent_text_response(string $body, string $contentType = 'text/plain', int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: ' . $contentType . '; charset=UTF-8');
    header('Cache-Control: public, max-age=300, stale-while-revalidate=900');
    header('Access-Control-Allow-Origin: *');
    header('X-Content-Type-Options: nosniff');
    echo $body;
    exit;
}
