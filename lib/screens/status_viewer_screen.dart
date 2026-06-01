import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import '../constants/app_theme.dart';
import '../models/status_model.dart';
import '../services/chat_service.dart';
import '../services/status_service.dart';

class StatusViewerScreen extends StatefulWidget {
  final List<UserStatuses> groups;
  final int initialGroupIndex;
  final String currentUid;
  final String currentUserName;
  final ChatService chatService;

  const StatusViewerScreen({
    super.key,
    required this.groups,
    required this.initialGroupIndex,
    required this.currentUid,
    required this.currentUserName,
    required this.chatService,
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

  // Local mutable copy so delete immediately updates progress bars
  late List<List<StatusModel>> _mutableStatuses;

  int _groupIdx = 0;
  int _statusIdx = 0;
  bool _paused = false;
  bool _mediaLoaded = false;
  bool _showViewers = false;

  // Viewer-sheet name/photo cache
  final Map<String, String> _viewerNames = {};
  final Map<String, String?> _viewerPhotos = {};

  // Brief sent-feedback toast
  String? _feedbackText;
  Timer? _feedbackTimer;
  bool _loadingViewerNames = false;

  // Reply / react
  final TextEditingController _replyCtrl = TextEditingController();
  bool _showReplyInput = false;
  bool _sendingReply = false;

  UserStatuses get _groupInfo => widget.groups[_groupIdx];
  List<StatusModel> get _currentStatuses => _mutableStatuses[_groupIdx];
  StatusModel get _status => _currentStatuses[_statusIdx];
  bool get _isOwn => _status.uid == widget.currentUid;

  @override
  void initState() {
    super.initState();
    _groupIdx = widget.initialGroupIndex;
    _mutableStatuses = widget.groups
        .map((g) => List<StatusModel>.from(g.statuses))
        .toList();

    // Jump to the first unseen status in the initial group.
    // If all are seen, start at 0 (show all from the beginning).
    final initStatuses = _mutableStatuses[_groupIdx];
    final firstUnseen = initStatuses.indexWhere(
        (s) => !s.hasViewedBy(widget.currentUid));
    _statusIdx = firstUnseen >= 0 ? firstUnseen : 0;

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
    _replyCtrl.dispose();
    _feedbackTimer?.cancel();
    super.dispose();
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _advance() {
    if (_statusIdx < _currentStatuses.length - 1) {
      _loadStatusAt(_groupIdx, _statusIdx + 1);
    } else if (_groupIdx < _mutableStatuses.length - 1) {
      _loadStatusAt(_groupIdx + 1, 0);
    } else {
      Navigator.pop(context);
    }
  }

  void _goBack() {
    if (_statusIdx > 0) {
      _loadStatusAt(_groupIdx, _statusIdx - 1);
    } else if (_groupIdx > 0) {
      _loadStatusAt(_groupIdx - 1, _mutableStatuses[_groupIdx - 1].length - 1);
    }
  }

  void _loadStatusAt(int gIdx, int sIdx) {
    _replyCtrl.clear();
    setState(() {
      _groupIdx = gIdx;
      _statusIdx = sIdx;
      _mediaLoaded = false;
      _showViewers = false;
      _showReplyInput = false;
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
      if (s.musicUrl != null) {
        await _musicPlayer.play(UrlSource(s.musicUrl!));
        final startMs = s.musicStartMs ?? 0;
        Duration trackDur = const Duration(seconds: 30);
        try {
          trackDur = await _musicPlayer.onDurationChanged.first
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
        if (startMs > 0) {
          await _musicPlayer.seek(Duration(milliseconds: startMs));
        }
        final remaining = trackDur - Duration(milliseconds: startMs);
        _progressCtrl.duration =
            remaining > Duration.zero ? remaining : const Duration(seconds: 30);
      } else {
        _progressCtrl.duration = const Duration(seconds: 5);
      }
    }

    if (!mounted) return;
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

  // ── Viewers sheet ──────────────────────────────────────────────────────────

  void _toggleViewers() {
    setState(() => _showViewers = !_showViewers);
    if (_showViewers && !_paused) _togglePause();
    if (_showViewers) _loadViewerNames();
  }

  Future<void> _loadViewerNames() async {
    if (_loadingViewerNames) return;
    setState(() => _loadingViewerNames = true);
    for (final uid in _status.viewers.keys) {
      if (_viewerNames.containsKey(uid)) continue;
      try {
        final profile = await widget.chatService.getUserProfile(uid);
        if (mounted) {
          _viewerNames[uid] = profile?.name ?? uid;
          _viewerPhotos[uid] = profile?.photoUrl;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _loadingViewerNames = false);
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

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
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.holiday),
            onPressed: () async {
              Navigator.pop(ctx);
              final id = _status.id;
              await _statusService.deleteStatus(id);
              if (!mounted) return;
              final list = _mutableStatuses[_groupIdx];
              list.removeAt(_statusIdx);
              if (list.isEmpty) {
                Navigator.pop(context);
              } else {
                final newIdx =
                    _statusIdx >= list.length ? list.length - 1 : _statusIdx;
                setState(() {
                  _statusIdx = newIdx;
                  _mediaLoaded = false;
                  _showViewers = false;
                });
                _loadStatus();
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // ── Full profile photo ─────────────────────────────────────────────────────

  void _viewFullPhoto(String url) {
    if (!_paused) _togglePause();
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          child: InteractiveViewer(
            child: CachedNetworkImage(imageUrl: url),
          ),
        ),
      ),
    ).then((_) {
      if (mounted && _paused) _togglePause();
    });
  }

  // ── React / reply ──────────────────────────────────────────────────────────

  Future<void> _sendReply(String text) async {
    if (text.trim().isEmpty || _sendingReply) return;
    setState(() => _sendingReply = true);
    try {
      await widget.chatService.sendTextMessage(
        senderUid: widget.currentUid,
        receiverUid: _status.uid,
        text: text.trim(),
        replyToId: _status.id,
        replyToText: _status.caption?.isNotEmpty == true
            ? _status.caption
            : '📷 Status',
        replyToImageUrl:
            _status.type == 'photo' ? _status.mediaUrl : null,
        replyToSenderId: _status.uid,
      );
    } catch (_) {}
    if (mounted) {
      _replyCtrl.clear();
      // Determine feedback label: emoji reactions show the emoji, longer text shows "Message sent"
      final isEmoji = text.trim().runes.length == 1;
      final label = isEmoji ? '${text.trim()} Sent' : 'Message sent';
      setState(() {
        _sendingReply = false;
        _showReplyInput = false;
        _feedbackText = label;
      });
      // Auto-dismiss after 2 seconds
      _feedbackTimer?.cancel();
      _feedbackTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _feedbackText = null);
      });
      // Resume status after sending
      if (_paused && !_showViewers) _togglePause();
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.black,
      body: GestureDetector(
        onLongPressStart: (_) {
          if (!_showReplyInput) _togglePause();
        },
        onLongPressEnd: (_) {
          if (_paused && !_showReplyInput) _togglePause();
        },
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.pop(context);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildMedia(),
            _buildGradient(),
            _buildTapAreas(),
            Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
            Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar()),
            if (_showViewers && _isOwn) _buildViewerSheet(),
            // Sent-feedback toast
            if (_feedbackText != null)
              Center(
                child: AnimatedOpacity(
                  opacity: _feedbackText != null ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle_rounded,
                            color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          _feedbackText!,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedia() {
    if (_status.isVideo) {
      if (!_mediaLoaded || _videoCtrl == null) {
        return const Center(
            child: CircularProgressIndicator(color: Colors.white));
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
      errorWidget: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image_outlined,
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
          height: 200,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
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
              children: List.generate(_currentStatuses.length, (i) {
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
                                    valueColor: const AlwaysStoppedAnimation(
                                        Colors.white),
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
            Row(
              children: [
                // Avatar — tap to view full profile photo
                GestureDetector(
                  onTap: _groupInfo.photoUrl != null
                      ? () => _viewFullPhoto(_groupInfo.photoUrl!)
                      : null,
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: AppColors.primary,
                    backgroundImage: _groupInfo.photoUrl != null
                        ? CachedNetworkImageProvider(_groupInfo.photoUrl!)
                        : null,
                    child: _groupInfo.photoUrl == null
                        ? Text(
                            _groupInfo.name.isNotEmpty
                                ? _groupInfo.name[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14),
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_groupInfo.name,
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
                        color: Colors.white, size: 24),
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
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
                      shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                ),
              ),
            // Music chip
            if (_status.hasMusic)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
              ),
            // Own: view count
            if (_isOwn) ...[
              GestureDetector(
                onTap: _toggleViewers,
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
            // Others: emoji reactions + reply input
            if (!_isOwn) ...[
              const SizedBox(height: 4),
              // Quick emoji reactions
              if (!_showReplyInput)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: ['❤️', '😂', '😮', '😢', '👏', '🔥']
                      .map((e) => GestureDetector(
                            onTap: () => _sendReply(e),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(e,
                                  style: const TextStyle(fontSize: 22)),
                            ),
                          ))
                      .toList(),
                ),
              const SizedBox(height: 8),
              // Text reply row
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        if (!_paused) _togglePause();
                        setState(() => _showReplyInput = true);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.4)),
                        ),
                        child: _showReplyInput
                            ? TextField(
                                controller: _replyCtrl,
                                autofocus: true,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14),
                                decoration: const InputDecoration(
                                  hintText: 'Send a message…',
                                  hintStyle:
                                      TextStyle(color: Colors.white60),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 12),
                                ),
                                onSubmitted: (v) => _sendReply(v),
                              )
                            : const Center(
                                child: Text('Send a message…',
                                    style: TextStyle(
                                        color: Colors.white60,
                                        fontSize: 14)),
                              ),
                      ),
                    ),
                  ),
                  if (_showReplyInput) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _sendReply(_replyCtrl.text),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                            color: AppColors.primary, shape: BoxShape.circle),
                        child: _sendingReply
                            ? const Padding(
                                padding: EdgeInsets.all(10),
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            : const Icon(Icons.send_rounded,
                                color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ],
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
        Expanded(
          child: GestureDetector(
            onTap: _showReplyInput ? null : _goBack,
            behavior: HitTestBehavior.translucent,
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: _showReplyInput ? null : _advance,
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
            maxHeight: MediaQuery.of(context).size.height * 0.45,
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
                    Text(
                        '${viewers.length} viewer${viewers.length != 1 ? 's' : ''}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15)),
                    if (_loadingViewerNames) ...[
                      const SizedBox(width: 10),
                      const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              color: Colors.white54, strokeWidth: 1.5)),
                    ],
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
                      final name = _viewerNames[uid] ?? uid;
                      final photo = _viewerPhotos[uid];
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor:
                              AppColors.primary.withValues(alpha: 0.5),
                          backgroundImage: photo != null
                              ? CachedNetworkImageProvider(photo)
                              : null,
                          child: photo == null
                              ? Text(
                                  name.isNotEmpty
                                      ? name[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold))
                              : null,
                        ),
                        title: Text(name,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14)),
                        subtitle: Text(
                          DateFormat('h:mm a, d MMM').format(viewedAt),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
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
