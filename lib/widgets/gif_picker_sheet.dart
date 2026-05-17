import 'dart:async';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants/app_theme.dart';

class GifPickerSheet extends StatefulWidget {
  const GifPickerSheet({super.key});

  @override
  State<GifPickerSheet> createState() => _GifPickerSheetState();
}

class _GifPickerSheetState extends State<GifPickerSheet> {
  // Tenor public test key — works for development/low volume use
  static const _apiKey = 'LIVDSRZULELA';

  final TextEditingController _searchCtrl = TextEditingController();
  List<_GifItem> _gifs = [];
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadFeatured();
    _searchCtrl.addListener(_onChanged);
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      final q = _searchCtrl.text.trim();
      if (q.isEmpty) {
        _loadFeatured();
      } else {
        _search(q);
      }
    });
  }

  Future<void> _loadFeatured() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _gifs = [];
    });
    try {
      final uri = Uri.parse(
        'https://tenor.googleapis.com/v2/featured'
        '?key=$_apiKey&limit=20&media_filter=gif,tinygif',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        setState(() => _gifs = _parse(resp.body));
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _search(String query) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _gifs = [];
    });
    try {
      final uri = Uri.parse(
        'https://tenor.googleapis.com/v2/search'
        '?q=${Uri.encodeComponent(query)}&key=$_apiKey&limit=20&media_filter=gif,tinygif',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        setState(() => _gifs = _parse(resp.body));
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  List<_GifItem> _parse(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final results = data['results'] as List;
      return results.map((r) {
        final formats = r['media_formats'] as Map<String, dynamic>;
        final gif = formats['gif'] as Map<String, dynamic>;
        final tiny = formats['tinygif'] as Map<String, dynamic>? ?? gif;
        return _GifItem(
          url: gif['url'] as String,
          preview: tiny['url'] as String,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.55,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search GIFs...',
                prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.background,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _gifs.isEmpty
                    ? const Center(
                        child: Text('No GIFs found',
                            style: TextStyle(color: AppColors.textSecondary)),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 4,
                          crossAxisSpacing: 4,
                          childAspectRatio: 1.6,
                        ),
                        itemCount: _gifs.length,
                        itemBuilder: (ctx, i) => GestureDetector(
                          onTap: () => Navigator.pop(context, _gifs[i].url),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl: _gifs[i].preview,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: AppColors.background),
                              errorWidget: (_, __, ___) => Container(
                                color: AppColors.background,
                                child: const Icon(Icons.gif_rounded,
                                    color: AppColors.textSecondary, size: 32),
                              ),
                            ),
                          ),
                        ),
                      ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}

class _GifItem {
  final String url;
  final String preview;
  _GifItem({required this.url, required this.preview});
}
