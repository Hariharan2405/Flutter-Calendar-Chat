import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_theme.dart';
import '../utils/image_sizing.dart';

// ── URL detection ─────────────────────────────────────────────────────────────

// Matches http(s):// URLs and bare www. domains like www.example.com/path
final _urlRegex = RegExp(
  r'(?:https?://\S+|www\.[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}(?:[/?\S]*)?)',
  caseSensitive: false,
);

bool _isTrailingPunct(String c) =>
    c == '.' || c == ',' || c == ':' || c == ';' || c == '!' ||
    c == '?' || c == ')' || c == ']' || c == '>' ||
    c == "'" || c == '"';  // single-quote  // double-quote

String _clean(String raw) {
  var url = raw;
  while (url.isNotEmpty && _isTrailingPunct(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

String? extractFirstUrl(String text) {
  final m = _urlRegex.firstMatch(text);
  if (m == null) return null;
  final url = _clean(m.group(0)!);
  return url.length > 10 ? url : null;
}

bool containsUrl(String text) => _urlRegex.hasMatch(text);

// ── Open URL (no canLaunchUrl gate — unreliable without full <queries>) ───────

Future<void> _openUrl(String raw) async {
  // Bare domains like www.example.com need a scheme to be valid URIs.
  final url = (raw.startsWith('www.')) ? 'https://$raw' : raw;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    // Try to open in the matching native app first (YouTube, Instagram…)
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    try {
      // Fallback to in-app browser
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (_) {}
  }
}

// ── Metadata model ─────────────────────────────────────────────────────────────

class _LinkMeta {
  final String domain;
  final String? title;
  final String? description;
  final String? imageUrl;
  const _LinkMeta(
      {required this.domain, this.title, this.description, this.imageUrl});
}

// ── Global cache + dedup ──────────────────────────────────────────────────────

final _metaCache = <String, _LinkMeta?>{};
final _inFlight = <String, Future<_LinkMeta?>>{};

Future<_LinkMeta?> _fetchMeta(String url) {
  if (_metaCache.containsKey(url)) return Future.value(_metaCache[url]);
  return _inFlight.putIfAbsent(url, () async {
    final meta = await _doFetch(url);
    _metaCache[url] = meta;
    _inFlight.remove(url);
    return meta;
  });
}

// User-agents to try in order (some sites block Googlebot, some block Chrome)
const _userAgents = [
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.6367.82 Mobile Safari/537.36',
  'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
];

// Extracts an 11-char YouTube video id from any common YouTube URL shape
// (watch?v=, youtu.be/, shorts/, live/, embed/). Returns null if not YouTube.
String? _youtubeId(Uri uri) {
  final host = uri.host.toLowerCase();
  final isYt = host.contains('youtube.com') || host.contains('youtu.be');
  if (!isYt) return null;

  String? id;
  if (host.contains('youtu.be')) {
    id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
  } else if (uri.queryParameters['v'] != null) {
    id = uri.queryParameters['v'];
  } else {
    // /shorts/<id>, /live/<id>, /embed/<id>
    final segs = uri.pathSegments;
    final i = segs.indexWhere(
        (s) => s == 'shorts' || s == 'live' || s == 'embed');
    if (i != -1 && i + 1 < segs.length) id = segs[i + 1];
  }
  if (id == null) return null;
  final m = RegExp(r'^[A-Za-z0-9_-]{11}').firstMatch(id);
  return m?.group(0);
}

/// Builds link metadata for a YouTube URL without scraping: oEmbed for the
/// title/author and the deterministic thumbnail URL for the image.
Future<_LinkMeta?> _youtubeMeta(Uri uri, String domain) async {
  final id = _youtubeId(uri);
  if (id == null) return null;

  final thumb = 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
  String? title;
  String? author;
  try {
    final oembed = Uri.parse(
        'https://www.youtube.com/oembed?url=https://youtu.be/$id&format=json');
    final resp = await http.get(oembed).timeout(const Duration(seconds: 6));
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      title = data['title'] as String?;
      author = data['author_name'] as String?;
    }
  } catch (_) {}

  return _LinkMeta(
    domain: 'youtube.com',
    title: _unescape(title) ?? 'YouTube',
    description: author,
    imageUrl: thumb,
  );
}

Future<_LinkMeta?> _doFetch(String raw) async {
  try {
    final url = raw.startsWith('www.') ? 'https://$raw' : raw;
    final uri = Uri.parse(url);
    final domain = uri.host.replaceFirst(RegExp(r'^www\.'), '');

    // YouTube blocks plain scraping (consent walls / bot checks), so OG tags
    // are usually missing. Use the public oEmbed endpoint + the deterministic
    // thumbnail URL instead — reliable and fast.
    final ytMeta = await _youtubeMeta(uri, domain);
    if (ytMeta != null) return ytMeta;

    http.Response? response;
    for (final ua in _userAgents) {
      try {
        response = await http.get(uri, headers: {
          'User-Agent': ua,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
        }).timeout(const Duration(seconds: 8));
        if (response.statusCode == 200) break;
      } catch (_) {
        continue;
      }
    }

    if (response == null || response.statusCode != 200) {
      return _LinkMeta(domain: domain);
    }

    // Cap at 80 KB — OG tags are always in <head>, well within that limit
    final html = response.body.length > 81920
        ? response.body.substring(0, 81920)
        : response.body;

    final title  = _og(html, 'og:title')       ?? _og(html, 'twitter:title')       ?? _htmlTitle(html);
    final desc   = _og(html, 'og:description') ?? _og(html, 'twitter:description');
    var   img    = _og(html, 'og:image')        ?? _og(html, 'twitter:image');

    if (img != null && img.startsWith('/')) {
      img = '${uri.scheme}://${uri.host}$img';
    }

    return _LinkMeta(
      domain:      domain,
      title:       _unescape(title),
      description: _unescape(desc),
      imageUrl:    img,
    );
  } catch (_) {
    return null;
  }
}

/// Parses a meta-tag value, handling BOTH double-quoted and single-quoted
/// attributes and both attribute orderings (property before content and vice
/// versa). Double-quoted Dart strings are used for single-quote patterns to
/// avoid the raw-string delimiter conflict.
String? _og(String html, String property) {
  final esc = RegExp.escape(property);

  // ── double-quoted attrs ──────────────────────────────────────────────────
  // property="X" content="Y"
  var pat = RegExp(r'<meta[^>]+property="' + esc + r'"[^>]+content="([^"<>]{1,500})"', caseSensitive: false);
  var v = pat.firstMatch(html)?.group(1)?.trim();
  if (v != null && v.isNotEmpty) return v;

  // content="Y" property="X"
  pat = RegExp(r'<meta[^>]+content="([^"<>]{1,500})"[^>]+property="' + esc + '"', caseSensitive: false);
  v = pat.firstMatch(html)?.group(1)?.trim();
  if (v != null && v.isNotEmpty) return v;

  // name="X" content="Y"  (Twitter cards use name= instead of property=)
  pat = RegExp(r'<meta[^>]+name="' + esc + r'"[^>]+content="([^"<>]{1,500})"', caseSensitive: false);
  v = pat.firstMatch(html)?.group(1)?.trim();
  if (v != null && v.isNotEmpty) return v;

  // content="Y" name="X"
  pat = RegExp(r'<meta[^>]+content="([^"<>]{1,500})"[^>]+name="' + esc + '"', caseSensitive: false);
  v = pat.firstMatch(html)?.group(1)?.trim();
  if (v != null && v.isNotEmpty) return v;

  // ── single-quoted attrs (use double-quoted Dart string to avoid \' issue) ─
  // property='X' content='Y'
  pat = RegExp("<meta[^>]+property='" + esc + "'[^>]+content='([^'<>]{1,500})'", caseSensitive: false);
  v = pat.firstMatch(html)?.group(1)?.trim();
  if (v != null && v.isNotEmpty) return v;

  // content='Y' property='X'
  pat = RegExp("<meta[^>]+content='([^'<>]{1,500})'[^>]+property='" + esc + "'", caseSensitive: false);
  v = pat.firstMatch(html)?.group(1)?.trim();
  if (v != null && v.isNotEmpty) return v;

  // name='X' content='Y'
  pat = RegExp("<meta[^>]+name='" + esc + "'[^>]+content='([^'<>]{1,500})'", caseSensitive: false);
  v = pat.firstMatch(html)?.group(1)?.trim();
  if (v != null && v.isNotEmpty) return v;

  // content='Y' name='X'
  pat = RegExp("<meta[^>]+content='([^'<>]{1,500})'[^>]+name='" + esc + "'", caseSensitive: false);
  return pat.firstMatch(html)?.group(1)?.trim();
}

String? _htmlTitle(String html) {
  final m = RegExp(r'<title[^>]*>([^<]{1,200})</title>', caseSensitive: false).firstMatch(html);
  return m?.group(1)?.trim();
}

String? _unescape(String? s) {
  if (s == null || s.isEmpty) return null;
  return s
      .replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&#x27;', "'")
      .replaceAll('&nbsp;', ' ').trim();
}

// ── LinkableText ──────────────────────────────────────────────────────────────

class LinkableText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const LinkableText({super.key, required this.text, required this.style});

  @override
  State<LinkableText> createState() => _LinkableTextState();
}

class _LinkableTextState extends State<LinkableText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) { r.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) { r.dispose(); }
    _recognizers.clear();

    final linkStyle = widget.style.copyWith(
      decoration: TextDecoration.underline,
      decorationColor: widget.style.color,
    );

    final spans = <InlineSpan>[];
    int cursor = 0;

    for (final match in _urlRegex.allMatches(widget.text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }
      final rawUrl = match.group(0)!;
      final cleanUrl = _clean(rawUrl);
      final urlToOpen = cleanUrl.length > 10 ? cleanUrl : rawUrl;

      final rec = TapGestureRecognizer()
        ..onTap = () => _openUrl(urlToOpen);
      _recognizers.add(rec);

      spans.add(TextSpan(text: rawUrl, style: linkStyle, recognizer: rec));
      cursor = match.end;
    }

    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return RichText(text: TextSpan(style: widget.style, children: spans));
  }
}

// ── LinkPreviewWidget ─────────────────────────────────────────────────────────

class LinkPreviewWidget extends StatefulWidget {
  final String url;
  final bool isMine;

  const LinkPreviewWidget({super.key, required this.url, required this.isMine});

  @override
  State<LinkPreviewWidget> createState() => _LinkPreviewWidgetState();
}

class _LinkPreviewWidgetState extends State<LinkPreviewWidget> {
  _LinkMeta? _meta;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchMeta(widget.url).then((meta) {
      if (mounted) setState(() { _meta = meta; _loading = false; });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _shimmer();
    final meta = _meta;
    if (meta == null || (meta.title == null && meta.imageUrl == null)) {
      return const SizedBox.shrink();
    }
    return _card(meta);
  }

  Widget _shimmer() {
    final bg = widget.isMine ? Colors.white.withValues(alpha: 0.12) : Colors.grey.shade200;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      height: 48,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Center(
        child: SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: widget.isMine ? Colors.white54 : AppColors.primary.withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }

  Widget _card(_LinkMeta meta) {
    final isMine = widget.isMine;
    final bg = isMine ? Colors.white.withValues(alpha: 0.14) : const Color(0xFFF0F0F0);
    final borderColor = isMine ? Colors.white.withValues(alpha: 0.28) : Colors.grey.shade300;
    final accent      = isMine ? Colors.white70 : AppColors.primary;
    final titleColor  = isMine ? Colors.white : AppColors.textPrimary;
    final descColor   = isMine ? Colors.white.withValues(alpha: 0.65) : AppColors.textSecondary;

    return GestureDetector(
      onTap: () => _openUrl(widget.url),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (meta.imageUrl != null)
              CachedNetworkImage(
                imageUrl: meta.imageUrl!,
                memCacheWidth: kBubbleImageDecodeWidth,
                width: double.infinity,
                height: 150,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
                placeholder: (_, __) => Container(height: 80, color: Colors.black12),
              ),

            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    CachedNetworkImage(
                      imageUrl: 'https://www.google.com/s2/favicons?domain=${meta.domain}&sz=16',
                      width: 13, height: 13,
                      errorWidget: (_, __, ___) => Icon(Icons.link_rounded, size: 12, color: accent),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(meta.domain, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: accent,
                              fontWeight: FontWeight.w600, letterSpacing: 0.2)),
                    ),
                  ]),

                  if (meta.title != null) ...[
                    const SizedBox(height: 4),
                    Text(meta.title!, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                            color: titleColor, height: 1.3)),
                  ],

                  if (meta.description != null && meta.description!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(meta.description!, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: descColor, height: 1.3)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
