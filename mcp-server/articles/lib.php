<?php
declare(strict_types=1);

const APERTURE_SUPABASE_URL = 'https://rfjdenxkgjgepgbmxxkd.supabase.co';
const APERTURE_SUPABASE_KEY = 'sb_publishable_RqWWqn3G2g6MJnlk97S2Rg_QVwx6MXV';
const APERTURE_SITE_URL = 'https://aperturex.io';
const APERTURE_IMAGE_PREFIX = APERTURE_SUPABASE_URL . '/storage/v1/object/public/article-images/';

function supabase_articles(array $parameters): array
{
    $endpoint = APERTURE_SUPABASE_URL . '/rest/v1/articles?'
        . http_build_query($parameters, '', '&', PHP_QUERY_RFC3986);
    $headers = [
        'Accept: application/json',
        'apikey: ' . APERTURE_SUPABASE_KEY,
        'User-Agent: ApertureJournal/1.0',
    ];

    if (function_exists('curl_init')) {
        $handle = curl_init($endpoint);
        curl_setopt_array($handle, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => 4,
            CURLOPT_TIMEOUT => 8,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
        ]);
        $body = curl_exec($handle);
        $curlError = curl_error($handle);
        $status = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        curl_close($handle);

        if ($body === false) {
            return ['data' => [], 'error' => 'The publishing service request failed: ' . $curlError];
        }
    } else {
        $context = stream_context_create([
            'http' => [
                'method' => 'GET',
                'timeout' => 8,
                'ignore_errors' => true,
                'header' => implode("\r\n", $headers),
            ],
        ]);
        $body = @file_get_contents($endpoint, false, $context);
        $status = response_status_from_headers($http_response_header ?? []);
        if ($body === false) {
            return ['data' => [], 'error' => 'The publishing service could not be reached.'];
        }
    }

    $decoded = json_decode($body, true);
    if ($status < 200 || $status >= 300) {
        $message = is_array($decoded)
            ? ($decoded['message'] ?? $decoded['error_description'] ?? 'Unexpected response')
            : 'Unexpected response';
        return [
            'data' => [],
            'error' => 'The publishing service returned HTTP ' . $status . ': ' . clean_error_message((string) $message),
        ];
    }
    if (!is_array($decoded)) {
        return ['data' => [], 'error' => 'The publishing service returned unreadable article data.'];
    }
    return ['data' => $decoded, 'error' => null];
}

function published_articles(int $limit = 50): array
{
    return supabase_articles([
        'select' => 'id,slug,title,excerpt,cover_image_url,cover_image_alt,category,tags,is_featured,author_name,reading_minutes,published_at,updated_at,seo_title,seo_description',
        'status' => 'eq.published',
        'published_at' => 'lte.' . gmdate('c'),
        'order' => 'is_featured.desc,published_at.desc',
        'limit' => (string) max(1, min($limit, 100)),
    ]);
}

function published_articles_with_body(int $limit = 100): array
{
    return supabase_articles([
        'select' => 'id,slug,title,excerpt,body_html,cover_image_url,cover_image_alt,category,tags,is_featured,author_name,reading_minutes,published_at,updated_at,seo_title,seo_description,version',
        'status' => 'eq.published',
        'published_at' => 'lte.' . gmdate('c'),
        'order' => 'published_at.desc',
        'limit' => (string) max(1, min($limit, 100)),
    ]);
}

function published_article(string $slug): array
{
    return supabase_articles([
        'select' => 'id,slug,title,excerpt,body_html,cover_image_url,cover_image_alt,category,tags,is_featured,author_name,reading_minutes,published_at,updated_at,seo_title,seo_description,version',
        'slug' => 'eq.' . $slug,
        'status' => 'eq.published',
        'published_at' => 'lte.' . gmdate('c'),
        'limit' => '1',
    ]);
}

function related_articles(string $articleId, string $category, int $limit = 3): array
{
    return supabase_articles([
        'select' => 'id,slug,title,excerpt,cover_image_url,cover_image_alt,category,reading_minutes,published_at',
        'id' => 'neq.' . $articleId,
        'status' => 'eq.published',
        'published_at' => 'lte.' . gmdate('c'),
        'category' => 'eq.' . $category,
        'order' => 'published_at.desc',
        'limit' => (string) max(1, min($limit, 6)),
    ]);
}

function sanitize_article_html(string $html): string
{
    if ($html === '') {
        return '';
    }
    if (!class_exists('DOMDocument')) {
        return '<p>' . escape(strip_tags($html)) . '</p>';
    }

    $document = new DOMDocument('1.0', 'UTF-8');
    $previous = libxml_use_internal_errors(true);
    $document->loadHTML(
        '<?xml encoding="utf-8" ?><div id="aperture-article-root">' . $html . '</div>',
        LIBXML_HTML_NOIMPLIED | LIBXML_HTML_NODEFDTD
    );
    libxml_clear_errors();
    libxml_use_internal_errors($previous);

    $root = $document->getElementById('aperture-article-root');
    if (!$root) {
        return '';
    }
    sanitize_article_node($root);

    $output = '';
    foreach (iterator_to_array($root->childNodes) as $child) {
        $output .= $document->saveHTML($child);
    }
    return $output;
}

function sanitize_article_node(DOMNode $node): void
{
    $allowedTags = [
        'div', 'p', 'h2', 'h3', 'h4', 'strong', 'em', 'u', 's', 'a',
        'blockquote', 'ul', 'ol', 'li', 'pre', 'code', 'br', 'hr', 'img',
        'figure', 'figcaption', 'table', 'thead', 'tbody', 'tr', 'th', 'td',
    ];
    $dropEntirely = ['script', 'style', 'iframe', 'object', 'embed', 'form', 'input', 'button', 'svg'];

    foreach (iterator_to_array($node->childNodes) as $child) {
        if ($child instanceof DOMComment) {
            $node->removeChild($child);
            continue;
        }
        if (!($child instanceof DOMElement)) {
            continue;
        }

        $tag = strtolower($child->tagName);
        if (in_array($tag, $dropEntirely, true)) {
            $node->removeChild($child);
            continue;
        }
        if (!in_array($tag, $allowedTags, true)) {
            sanitize_article_node($child);
            while ($child->firstChild) {
                $node->insertBefore($child->firstChild, $child);
            }
            $node->removeChild($child);
            continue;
        }

        sanitize_article_attributes($child, $tag);
        sanitize_article_node($child);
    }
}

function sanitize_article_attributes(DOMElement $element, string $tag): void
{
    $allowedByTag = [
        'a' => ['href', 'title'],
        'img' => ['src', 'alt', 'title', 'width', 'height'],
        'th' => ['colspan', 'rowspan'],
        'td' => ['colspan', 'rowspan'],
        'p' => ['style'],
        'h2' => ['style'],
        'h3' => ['style'],
        'h4' => ['style'],
    ];
    $allowed = $allowedByTag[$tag] ?? [];

    foreach (iterator_to_array($element->attributes) as $attribute) {
        if (!in_array(strtolower($attribute->name), $allowed, true)) {
            $element->removeAttribute($attribute->name);
        }
    }

    if ($tag === 'a') {
        $href = trim($element->getAttribute('href'));
        if (!safe_article_link($href)) {
            $element->removeAttribute('href');
        } elseif (preg_match('/^https?:/i', $href)) {
            $element->setAttribute('target', '_blank');
            $element->setAttribute('rel', 'noopener noreferrer');
        }
    }

    if ($tag === 'img') {
        $src = trim($element->getAttribute('src'));
        if (!str_starts_with($src, APERTURE_IMAGE_PREFIX)) {
            $element->parentNode?->removeChild($element);
            return;
        }
        $element->setAttribute('loading', 'lazy');
        $element->setAttribute('decoding', 'async');
        if (!$element->hasAttribute('alt')) {
            $element->setAttribute('alt', '');
        }
    }

    if ($element->hasAttribute('style')) {
        $style = trim($element->getAttribute('style'));
        if (!preg_match('/^text-align:\s*(left|center|right);?$/i', $style)) {
            $element->removeAttribute('style');
        }
    }
}

function safe_article_link(string $href): bool
{
    if ($href === '' || str_starts_with($href, '//')) {
        return false;
    }
    return preg_match('/^(https?:\/\/|mailto:|\/[^\/]|#)/i', $href) === 1;
}

function article_image_url(?string $value): ?string
{
    if (!$value || !str_starts_with($value, APERTURE_IMAGE_PREFIX)) {
        return null;
    }
    return $value;
}

function article_url(string $slug): string
{
    return APERTURE_SITE_URL . '/articles/' . rawurlencode($slug) . '/';
}

function format_article_date(?string $value): string
{
    if (!$value) {
        return '';
    }
    try {
        return (new DateTimeImmutable($value))->format('F j, Y');
    } catch (Exception) {
        return '';
    }
}

function iso_article_date(?string $value): string
{
    if (!$value) {
        return '';
    }
    try {
        return (new DateTimeImmutable($value))->format(DateTimeInterface::ATOM);
    } catch (Exception) {
        return '';
    }
}

function escape(?string $value): string
{
    return htmlspecialchars($value ?? '', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function clean_error_message(string $message): string
{
    return preg_replace('/[\r\n\t]+/', ' ', mb_substr($message, 0, 240)) ?: 'Unexpected response';
}

function response_status_from_headers(array $headers): int
{
    foreach (array_reverse($headers) as $header) {
        if (preg_match('/^HTTP\/\S+\s+(\d{3})/', $header, $matches)) {
            return (int) $matches[1];
        }
    }
    return 0;
}
