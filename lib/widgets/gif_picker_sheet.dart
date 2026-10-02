import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants/app_theme.dart';
import 'chat_ui.dart';

/// GIF search, powered by GIPHY.
///
/// This used Tenor, whose API was discontinued (every request now returns
/// 403 "Tenor API is discontinued", and it stopped accepting new clients in
/// January 2026). GIPHY's key is free and is read from `.env` at build time,
/// like the Gemini key:  GIPHY_API_KEY=...
///
/// Returns the URL of the chosen GIF, or null if dismissed.
class GifPickerSheet extends StatefulWidget {
  const GifPickerSheet({super.key});

  @override
  State<GifPickerSheet> createState() => _GifPickerSheetState();
}

/// A quick-pick category. A null [query] means trending.
class GifCategory {
  final String label;
  final String? query;
  const GifCategory(this.label, this.query);
}

class _GifPickerSheetState extends State<GifPickerSheet> {
  static const String _apiKey = String.fromEnvironment('GIPHY_API_KEY');

  /// Tamil favourites first, then everyday reactions.
  static const List<GifCategory> categories = [
    GifCategory('🔥 Trending', null),
    GifCategory('😂 Tamil comedy', 'tamil comedy'),
    GifCategory('Vadivelu', 'vadivelu'),
    GifCategory('Goundamani', 'goundamani'),
    GifCategory('Senthil', 'senthil comedy'),
    GifCategory('Santhanam', 'santhanam'),
    GifCategory('Yogi Babu', 'yogi babu'),
    GifCategory('Vivek', 'vivek comedy'),
    GifCategory('Rajinikanth', 'rajinikanth'),
    GifCategory('Vijay', 'thalapathy vijay'),
    GifCategory('Kollywood', 'kollywood'),
    GifCategory('🤣 Haha', 'laughing'),
    GifCategory('❤️ Love', 'love'),
    GifCategory('😢 Sad', 'sad'),
    GifCategory('😡 Angry', 'angry'),
    GifCategory('😮 Wow', 'wow'),
    GifCategory('🙏 Thank you', 'thank you'),
    GifCategory('☀️ Good morning', 'good morning'),
    GifCategory('🌙 Good night', 'good night'),
    GifCategory('💃 Dance', 'dance'),
    GifCategory('🤦 Facepalm', 'facepalm'),
  ];

  /// Free keys allow up to 50 per request.
  static const int _pageSize = 30;

  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  int _category = 0;
  final List<GiphyGif> _gifs = [];
  int _offset = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  /// Bumped on every new query so a slow earlier response can't overwrite it.
  int _requestId = 0;

  String? get _query {
    final typed = _searchCtrl.text.trim();
    if (typed.isNotEmpty) return typed;
    return categories[_category].query;
  }

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onTyped);
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onTyped() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), _reload);
  }

  void _onScroll() {
    // Load the next page before the user reaches the end.
    if (_scroll.position.extentAfter < 600) _loadMore();
  }

  void _pickCategory(int i) {
    if (_searchCtrl.text.isNotEmpty) _searchCtrl.clear();
    setState(() => _category = i);
    _reload();
  }

  void _reload() {
    _requestId++;
    setState(() {
      _gifs.clear();
      _offset = 0;
      _hasMore = true;
      _error = null;
      _loading = false;
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || _apiKey.isEmpty) return;
    final id = _requestId;
    setState(() => _loading = true);
    try {
      final q = _query;
      final uri = Uri.https(
        'api.giphy.com',
        q == null ? '/v1/gifs/trending' : '/v1/gifs/search',
        {
          'api_key': _apiKey,
          if (q != null) 'q': q.length > 50 ? q.substring(0, 50) : q,
          'limit': '$_pageSize',
          'offset': '$_offset',
          'rating': 'pg-13',
          'bundle': 'messaging_non_clips',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (!mounted || id != _requestId) return;
      if (res.statusCode != 200) {
        setState(() => _error = describeGiphyError(res.statusCode));
        return;
      }
      final page = parseGiphy(res.body);
      setState(() {
        _gifs.addAll(page.gifs);
        _offset += page.gifs.length;
        _hasMore = page.gifs.isNotEmpty && _offset < page.totalCount;
      });
    } on TimeoutException {
      if (mounted && id == _requestId) {
        setState(() => _error = 'GIPHY is taking too long. Check your connection.');
      }
    } catch (_) {
      if (mounted && id == _requestId) {
        setState(() => _error = 'No internet connection.');
      }
    } finally {
      if (mounted && id == _requestId) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search GIFs — try "vadivelu"',
                prefixIcon: const Icon(Icons.search, color: ChatStyle.mist),
                filled: true,
                fillColor: const Color(0xFFF2EEFF),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: ChatStyle.violet, width: 1.5),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final selected = i == _category && _searchCtrl.text.isEmpty;
                return ChoiceChip(
                  label: Text(categories[i].label),
                  selected: selected,
                  onSelected: (_) => _pickCategory(i),
                  showCheckmark: false,
                  labelStyle: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : ChatStyle.ink,
                  ),
                  selectedColor: ChatStyle.violet,
                  backgroundColor: const Color(0xFFF2EEFF),
                  side: BorderSide.none,
                  shape: const StadiumBorder(),
                  visualDensity: VisualDensity.compact,
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Expanded(child: _body()),
          // GIPHY's terms ask for visible attribution.
          Padding(
            padding: EdgeInsets.only(
                top: 4, bottom: MediaQuery.of(context).padding.bottom + 8),
            child: const Text(
              'Powered by GIPHY',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: ChatStyle.mist),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_apiKey.isEmpty) {
      return const _Notice(
        icon: Icons.key_rounded,
        title: 'GIFs need a free GIPHY key',
        detail: 'Add GIPHY_API_KEY to the .env file and rebuild the app.',
      );
    }
    if (_error != null && _gifs.isEmpty) {
      return _Notice(
        icon: Icons.wifi_off_rounded,
        title: "Couldn't load GIFs",
        detail: _error!,
        onRetry: _reload,
      );
    }
    if (_gifs.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_gifs.isEmpty) {
      return const _Notice(
        icon: Icons.search_off_rounded,
        title: 'No GIFs found',
        detail: 'Try another word.',
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      // Extent-based so the sheet gains columns as it widens on a tablet
      // instead of scaling tiles up.
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 5,
        crossAxisSpacing: 5,
        childAspectRatio: 1.25,
      ),
      itemCount: _gifs.length + (_hasMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i >= _gifs.length) {
          return const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final gif = _gifs[i];
        return GestureDetector(
          onTap: () => Navigator.pop(context, gif.sendUrl),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: gif.previewUrl,
              memCacheWidth: 360,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 150),
              placeholder: (_, __) => Container(color: const Color(0xFFF2EEFF)),
              errorWidget: (_, __, ___) => Container(
                color: const Color(0xFFF2EEFF),
                child: const Icon(Icons.gif_rounded, color: ChatStyle.mist, size: 32),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onRetry;

  const _Notice({
    required this.icon,
    required this.title,
    required this.detail,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: ChatStyle.mist, size: 40),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: ChatStyle.ink)),
            const SizedBox(height: 6),
            Text(detail,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: ChatStyle.mist)),
            if (onRetry != null) ...[
              const SizedBox(height: 10),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

// ── GIPHY response parsing (pure, unit-tested) ──────────────────────────────

class GiphyGif {
  /// Small animated rendition for the grid.
  final String previewUrl;

  /// Rendition to send: `downsized` is capped at 2 MB, so it loads quickly in
  /// the chat; `original` is the fallback.
  final String sendUrl;

  const GiphyGif({required this.previewUrl, required this.sendUrl});
}

class GiphyPage {
  final List<GiphyGif> gifs;
  final int totalCount;
  const GiphyPage(this.gifs, this.totalCount);
}

/// Parses a GIPHY search/trending response. Malformed entries are skipped.
GiphyPage parseGiphy(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map) return const GiphyPage([], 0);
    final gifs = <GiphyGif>[];
    final data = json['data'];
    if (data is List) {
      for (final item in data) {
        if (item is! Map) continue;
        final images = item['images'];
        if (images is! Map) continue;
        String? urlOf(String rendition) {
          final r = images[rendition];
          if (r is Map && r['url'] is String && (r['url'] as String).isNotEmpty) {
            return r['url'] as String;
          }
          return null;
        }

        final send = urlOf('downsized') ?? urlOf('original');
        final preview = urlOf('fixed_width') ?? urlOf('fixed_width_small') ?? send;
        if (send == null || preview == null) continue;
        gifs.add(GiphyGif(previewUrl: preview, sendUrl: send));
      }
    }
    final pagination = json['pagination'];
    final total = pagination is Map && pagination['total_count'] is num
        ? (pagination['total_count'] as num).toInt()
        : gifs.length;
    return GiphyPage(gifs, total);
  } catch (_) {
    return const GiphyPage([], 0);
  }
}

/// A human explanation for a failed GIPHY request.
String describeGiphyError(int status) {
  switch (status) {
    case 401:
    case 403:
      return 'The GIPHY key is missing or invalid. Check GIPHY_API_KEY in .env.';
    case 429:
      return 'The free GIPHY limit is reached for this hour. Try again a little later.';
    default:
      return 'GIPHY returned an error ($status). Try again.';
  }
}
