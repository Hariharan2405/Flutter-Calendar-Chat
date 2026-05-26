import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import '../constants/app_theme.dart';
import '../models/status_model.dart';
import '../services/status_service.dart';

class StatusViewerScreen extends StatefulWidget {
  final List<UserStatuses> groups; // all user groups
  final int initialGroupIndex;
  final String currentUid;

  const StatusViewerScreen({
    super.key,
    required this.groups,
    required this.initialGroupIndex,
    required this.currentUid,
  });

  @override
  State<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends State<StatusViewerScreen>
    with SingleTickerProviderStateMixin {
  final StatusService _statusService = StatusService();
  final AudioPlayer _musicPlayer = AudioPlayer();

  late AnimationController _progressCtrl;
  VideoPlayerController? _videoCtrl;

  int _groupIdx = 0;
  int _statusIdx = 0;
  bool _paused = false;
  bool _mediaLoaded = false;
  bool _showViewers = false;

  UserStatuses get _group => widget.groups[_groupIdx];
  StatusModel get _status => _group.statuses[_statusIdx];
  bool get _isOwn => _status.uid == widget.currentUid;

  @override
  void initState() {
    super.initState();
    _groupIdx = widget.initialGroupIndex;
    _progressCtrl = AnimationController(vsync: this);
    _progressCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) _advance();
    });
    _loadStatus();
  }

  @override
  void dispose() {
    _progressCtrl.dispose();
    _videoCtrl?.dispose();
    _musicPlayer.dispose();
    super.dispose();
  }

  // ── Navigation ────────────────────────────────────────────────────────────────

  void _advance() {
    if (_statusIdx < _group.statuses.length - 1) {
      _loadStatusAt(_groupIdx, _statusIdx + 1);
    } else if (_groupIdx < widget.groups.length - 1) {
      _loadStatusAt(_groupIdx + 1, 0);
    } else {
      Navigator.pop(context);
    }
  }

  void _goBack() {
    if (_statusIdx > 0) {
      _loadStatusAt(_groupIdx, _statusIdx - 1);
    } else if (_groupIdx > 0) {
      final prevGroup = widget.groups[_groupIdx - 1];
      _loadStatusAt(_groupIdx - 1, prevGroup.statuses.length - 1);
    }
  }

  void _loadStatusAt(int gIdx, int sIdx) {
    setState(() {
      _groupIdx = gIdx;
      _statusIdx = sIdx;
      _mediaLoaded = false;
      _showViewers = false;
    });
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    _progressCtrl.stop();
    _progressCtrl.reset();
    await _musicPlayer.stop();
    await _videoCtrl?.pause();
    _videoCtrl?.dispose();
    _videoCtrl = null;

    final s = _status;

    // Mark viewed (not for own statuses)
    if (!_isOwn) {
      _statusService.markViewed(s.id, widget.currentUid);
    }

    if (s.isVideo) {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(s.mediaUrl));
      await ctrl.initialize();
      if (!mounted) return;
      setState(() {
        _videoCtrl = ctrl;
        _mediaLoaded = true;
      });
      _progressCtrl.duration = ctrl.value.duration;
      ctrl.play();
    } else {
      setState(() => _mediaLoaded = true);
      _progressCtrl.duration = const Duration(seconds: 5);
      if (s.musicUrl != null) {
        _musicPlayer.play(UrlSource(s.musicUrl!));
      }
    }

    if (!_paused) _progressCtrl.forward();
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
    if (_paused) {
      _progressCtrl.stop();
      _videoCtrl?.pause();
      _musicPlayer.pause();
    } else {
      _progressCtrl.forward();
      _videoCtrl?.play();
      _musicPlayer.resume();
    }
  }

  // ── Delete ────────────────────────────────────────────────────────────────────

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Status'),
        content: const Text('Remove this status? It cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.holiday),
            onPressed: () async {
              Navigator.pop(ctx);
              await _statusService.deleteStatus(_status.id);
              if (!mounted) return;
              if (_group.statuses.length == 1) {
                Navigator.pop(context);
              } else {
                _advance();
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onLongPressStart: (_) => _togglePause(),
        onLongPressEnd: (_) { if (_paused) _togglePause(); },
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.pop(context);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Media
            _buildMedia(),
            // Dark gradient top/bottom
            _buildGradient(),
            // Top bar
            Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
            // Bottom bar
            Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar()),
            // Tap areas
            _buildTapAreas(),
            // Viewer list sheet
            if (_showViewers && _isOwn) _buildViewerSheet(),
          ],
        ),
      ),
    );
  }

  Widget _buildMedia() {
    if (_status.isVideo) {
      if (!_mediaLoaded || _videoCtrl == null) {
        return const Center(child: CircularProgressIndicator(color: Colors.white));
      }
      return Center(
        child: AspectRatio(
          aspectRatio: _videoCtrl!.value.aspectRatio,
          child: VideoPlayer(_videoCtrl!),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: _status.mediaUrl,
      fit: BoxFit.contain,
      placeholder: (_, __) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
      errorWidget: (_, __, ___) =>
          const Center(child: Icon(Icons.broken_image_outlined,
              color: Colors.white54, size: 48)),
      imageBuilder: (ctx, img) {
        if (!_mediaLoaded) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _mediaLoaded = true);
          });
        }
        return Image(image: img, fit: BoxFit.contain);
      },
    );
  }

  Widget _buildGradient() {
    return Column(
      children: [
        Container(
          height: 180,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
            ),
          ),
        ),
        const Spacer(),
        Container(
          height: 160,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress bars
            Row(
              children: List.generate(_group.statuses.length, (i) {
                return Expanded(
                  child: Container(
                    height: 2.5,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: i < _statusIdx
                          ? Container(color: Colors.white)
                          : i == _statusIdx
                              ? AnimatedBuilder(
                                  animation: _progressCtrl,
                                  builder: (_, __) => LinearProgressIndicator(
                                    value: _progressCtrl.value,
                                    backgroundColor: Colors.white38,
                                    valueColor:
                                        const AlwaysStoppedAnimation(Colors.white),
                                    minHeight: 2.5,
                                  ),
                                )
                              : Container(color: Colors.white38),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),
            // User info row
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.primary,
                  backgroundImage: _group.photoUrl != null
                      ? CachedNetworkImageProvider(_group.photoUrl!)
                      : null,
                  child: _group.photoUrl == null
                      ? Text(
                          _group.name.isNotEmpty
                              ? _group.name[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14),
                        )
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_group.name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14)),
                      Text(
                        DateFormat('h:mm a').format(_status.createdAt),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (_isOwn)
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded,
                        color: Colors.white70, size: 22),
                    onPressed: _confirmDelete,
                  ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Caption
            if (_status.caption?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _status.caption!,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      shadows: [
                        Shadow(color: Colors.black54, blurRadius: 4)
                      ]),
                ),
              ),
            // Music info
            if (_status.hasMusic)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.music_note_rounded,
                        color: Colors.white70, size: 14),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${_status.musicName ?? ''} — ${_status.musicArtist ?? ''}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            // Viewer count (for own statuses)
            if (_isOwn) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() => _showViewers = !_showViewers),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.remove_red_eye_outlined,
                        color: Colors.white70, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      '${_status.viewCount} view${_status.viewCount != 1 ? 's' : ''}',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _showViewers
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      color: Colors.white54,
                      size: 16,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTapAreas() {
    return Row(
      children: [
        // Left: go back
        Expanded(
          child: GestureDetector(
            onTap: _goBack,
            behavior: HitTestBehavior.translucent,
          ),
        ),
        // Right: go forward
        Expanded(
          child: GestureDetector(
            onTap: _advance,
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }

  Widget _buildViewerSheet() {
    final viewers = _status.viewers.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: GestureDetector(
        onTap: () {},
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.4,
          ),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    const Icon(Icons.remove_red_eye_outlined,
                        color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    Text('${viewers.length} viewer${viewers.length != 1 ? 's' : ''}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15)),
                  ],
                ),
              ),
              if (viewers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No views yet',
                      style: TextStyle(color: Colors.white54)),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: viewers.length,
                    itemBuilder: (ctx, i) {
                      final uid = viewers[i].key;
                      final viewedAt = viewers[i].value;
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: AppColors.primary.withValues(alpha: 0.3),
                          child: Text(
                            uid.isNotEmpty ? uid[0].toUpperCase() : '?',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(uid,
                            style: const TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: Text(
                          DateFormat('h:mm a, d MMM').format(viewedAt),
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
