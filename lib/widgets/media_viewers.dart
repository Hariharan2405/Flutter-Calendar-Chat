import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';
import '../services/media_cache.dart';
import '../services/media_save_service.dart';
import '../services/saved_media_store.dart';
import '../utils/snack_util.dart';

/// Full-screen, zoomable image viewer with a save action.
///
/// When [messageId] is provided the save reuses the local cache (no
/// re-download), writes into the gallery, and shows a "saved" indicator that
/// reappears as a download button if the file is later deleted from the device.
class FullScreenImageViewer extends StatefulWidget {
  final String url;
  final String? messageId;
  const FullScreenImageViewer({super.key, required this.url, this.messageId});

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  bool _saved = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _resolveSaved();
  }

  Future<void> _resolveSaved() async {
    if (widget.messageId == null) return;
    final saved = await SavedMediaStore.existsFor(widget.messageId!);
    if (mounted && saved) setState(() => _saved = true);
  }

  Future<void> _download() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (widget.messageId != null) {
        final uri = await MediaSaveService.saveReusingCache(
          url: widget.url,
          messageId: widget.messageId!,
          kind: SavedMediaKind.image,
        );
        if (uri == null) throw Exception('save failed');
        if (mounted) setState(() => _saved = true);
      } else {
        // No message context — reuse cache for bytes, save to gallery untracked.
        final f = await getCachedMediaFile(widget.url);
        if (f == null) throw Exception('no file');
        await Gal.putImage(f.path);
      }
      if (mounted) context.showSuccess('Saved to gallery');
    } catch (_) {
      if (mounted) context.showError('Save failed');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [_saveAction()],
      ),
      body: Center(
        child: InteractiveViewer(
          child: CachedNetworkImage(
            imageUrl: widget.url,
            cacheManager: mediaCacheManager,
            placeholder: (_, __) =>
                const Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    );
  }

  Widget _saveAction() {
    if (_saving) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                color: Colors.white, strokeWidth: 2)),
      );
    }
    if (_saved) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Tooltip(
          message: 'Saved to gallery',
          child: Icon(Icons.download_done_rounded, color: Colors.white),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download_rounded),
      tooltip: 'Save to gallery',
      onPressed: _download,
    );
  }
}

/// Full-screen video viewer that plays from the local cache and can save
/// (reusing the cache) with a saved indicator, mirroring the image viewer.
class FullScreenVideoViewer extends StatefulWidget {
  final String url;
  final String? messageId;
  const FullScreenVideoViewer({super.key, required this.url, this.messageId});

  @override
  State<FullScreenVideoViewer> createState() => _FullScreenVideoViewerState();
}

class _FullScreenVideoViewerState extends State<FullScreenVideoViewer> {
  VideoPlayerController? _ctrl;
  bool _ready = false;
  bool _saved = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _init();
    _resolveSaved();
  }

  Future<void> _init() async {
    // Play from the cached copy when available; fall back to streaming.
    final file = await getCachedMediaFile(widget.url);
    final ctrl = file != null
        ? VideoPlayerController.file(file)
        : VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _ctrl = ctrl;
    try {
      await ctrl.initialize();
      if (mounted) {
        setState(() => _ready = true);
        ctrl.play();
      }
    } catch (_) {
      // Fallback to network if the cached file failed to initialize.
      if (file != null && mounted) {
        final net = VideoPlayerController.networkUrl(Uri.parse(widget.url));
        _ctrl = net;
        try {
          await net.initialize();
          if (mounted) {
            setState(() => _ready = true);
            net.play();
          }
        } catch (_) {}
      }
    }
  }

  Future<void> _resolveSaved() async {
    if (widget.messageId == null) return;
    final saved = await SavedMediaStore.existsFor(widget.messageId!);
    if (mounted && saved) setState(() => _saved = true);
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (widget.messageId != null) {
        final uri = await MediaSaveService.saveReusingCache(
          url: widget.url,
          messageId: widget.messageId!,
          kind: SavedMediaKind.video,
        );
        if (uri == null) throw Exception('save failed');
        if (mounted) setState(() => _saved = true);
      } else {
        final f = await getCachedMediaFile(widget.url);
        if (f == null) throw Exception('no file');
        await Gal.putVideo(f.path);
      }
      if (mounted) context.showSuccess('Saved to gallery');
    } catch (_) {
      if (mounted) context.showError('Save failed');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [_saveAction()],
      ),
      body: Center(
        child: _ready && ctrl != null
            ? AspectRatio(
                aspectRatio: ctrl.value.aspectRatio,
                child: VideoPlayer(ctrl),
              )
            : const CircularProgressIndicator(color: Colors.white),
      ),
      floatingActionButton: _ready && ctrl != null
          ? FloatingActionButton(
              backgroundColor: Colors.white24,
              onPressed: () => setState(() {
                ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
              }),
              child: Icon(
                ctrl.value.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
            )
          : null,
    );
  }

  Widget _saveAction() {
    if (_saving) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                color: Colors.white, strokeWidth: 2)),
      );
    }
    if (_saved) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Tooltip(
          message: 'Saved to gallery',
          child: Icon(Icons.download_done_rounded, color: Colors.white),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download_rounded),
      tooltip: 'Save to gallery',
      onPressed: _download,
    );
  }
}
