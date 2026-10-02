import 'dart:async';
import 'dart:io';
import '../providers/app_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_compress/video_compress.dart';
import 'package:provider/provider.dart';
import '../services/chat_service.dart';
import '../services/call_service.dart';
import '../services/group_chat_service.dart';
import '../services/media_cache.dart';
import '../services/media_prefetcher.dart';
import '../services/media_save_service.dart';
import '../services/outbox_service.dart';
import '../services/saved_media_store.dart';
import '../models/user_profile_model.dart';
import '../models/message_model.dart';
import '../models/call_model.dart';
import '../constants/app_theme.dart';
import '../utils/responsive.dart';
import '../utils/snack_util.dart';
import '../widgets/chat_extras.dart';
import '../widgets/forward_sheet.dart';
import '../widgets/link_preview_widget.dart';
import '../widgets/voice_message_player.dart';
import '../widgets/audio_file_message.dart';
import '../widgets/media_viewers.dart';
import '../widgets/speak_button.dart';
import '../services/tts_service.dart';
import '../services/chat_prefs.dart';
import '../utils/tanglish.dart';
import '../widgets/caption_input_sheet.dart';
import '../widgets/voice_preview_sheet.dart';
import '../widgets/gif_picker_sheet.dart';
import '../widgets/sticker_picker_sheet.dart';
import '../widgets/chat_ui.dart';
import 'call_screen.dart';
import 'image_edit_screen.dart';
import 'message_search_screen.dart';
import 'starred_messages_screen.dart';
import '../utils/image_sizing.dart';

// ── Pending message types ─────────────────────────────────────────────────────

enum _PendingStatus { sending, failed }

class _PendingItem {
  final String id;
  final MessageType type;
  final File? localFile;
  final int? voiceDuration;
  final String? gifUrl;
  final String? sticker;
  final String? fileName;
  final int? fileSizeBytes;
  final String? caption;
  final String? replyToText;
  final String? replyToId;
  final String? replyToImageUrl;
  final String? replyToSenderId;
  _PendingStatus status = _PendingStatus.sending;
  bool isCancelled = false;

  _PendingItem({
    required this.id,
    required this.type,
    this.localFile,
    this.voiceDuration,
    this.gifUrl,
    this.sticker,
    this.fileName,
    this.fileSizeBytes,
    this.caption,
    this.replyToText,
    this.replyToId,
    this.replyToImageUrl,
    this.replyToSenderId,
  });
}

// Tracks active chat for notification suppression
class ActiveChatTracker {
  static String? activeChatId;
}

class ChatDetailScreen extends StatefulWidget {
  final String currentUid;
  final UserProfileModel otherUser;

  /// Shown beside the chat list on a tablet rather than as its own page, so
  /// it has no back button.
  final bool embedded;

  const ChatDetailScreen({
    super.key,
    required this.currentUid,
    required this.otherUser,
    this.embedded = false,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final ChatService _chatService = ChatService();
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _textFocus = FocusNode();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final ImagePicker _imagePicker = ImagePicker();

  late final Stream<List<MessageModel>> _messagesStream;

  final List<_PendingItem> _pendingItems = [];

  bool _isRecording = false;
  bool _isSending = false;
  bool _showEmojiPicker = false;
  final ValueNotifier<String?> _playingNotifier = ValueNotifier(null);
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration?> _durationNotifier = ValueNotifier(null);
  // Newest message id last seen — used to anchor scroll when a new message
  // arrives while the user has scrolled up (the stream window is capped, so the
  // message count alone can't detect new arrivals).
  String? _newestMsgId;
  // "New messages" jump button — shown when messages arrive while scrolled up.
  bool _showJumpToBottom = false;
  int _unseenCount = 0;
  List<MessageModel> _currentMessages = [];
  final Map<String, GlobalKey> _messageKeys = {};

  // ── Pagination ─────────────────────────────────────────────────────────────
  final List<MessageModel> _olderMessages = [];
  final Set<String> _loadedOlderIds = {};
  bool _hasMore = true;
  bool _isLoadingMore = false;
  String? _highlightedMessageId;

  /// The row whose highlight is currently fading out. Kept separate so the
  /// fade still plays after [_highlightedMessageId] clears, without paying for
  /// an [AnimatedContainer] on every other row in the list.
  String? _fadingMessageId;
  String? _recordingPath;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  MessageModel? _replyingTo;
  Map<String, dynamic>? _chatData;
  StreamSubscription<Map<String, dynamic>?>? _chatDataSub;

  // ── Starred / pinned / typing ──────────────────────────────────────────────
  Set<String> _starredIds = {};
  StreamSubscription<Set<String>>? _starredSub;
  String? get _pinnedMessageId => _chatData?['pinnedMessageId'] as String?;
  String? get _pinnedText => _chatData?['pinnedText'] as String?;
  /// True while the other person's typing stamp is still fresh.
  bool get _otherTyping =>
      TypingState.isActive(_chatData?['typing_${widget.otherUser.uid}']);
  // Throttles typing writes: one every few seconds rather than per keystroke.
  DateTime? _lastTypingPing;
  Timer? _typingStopTimer;
  UserProfileModel? _otherUserLive;
  StreamSubscription<UserProfileModel?>? _otherUserSub;

  double _dragStartY = 0;
  bool _recordingStartedByDrag = false;

  // Chat background — null = default color
  Color? _bgColor;
  String? _bgImagePath;
  static const _defaultBgColor = Color(0xFFF0EDF8);

  String get _chatId =>
      ChatService.chatId(widget.currentUid, widget.otherUser.uid);

  @override
  void initState() {
    super.initState();
    _messagesStream = _chatService.messages(widget.currentUid, widget.otherUser.uid);
    ActiveChatTracker.activeChatId = _chatId;
    // User opened a chat room — dismiss any lingering banner for this chat.
    AppProvider.dismissBanner?.call();
    _otherUserLive = widget.otherUser;

    _chatDataSub = _chatService.chatData(widget.currentUid, widget.otherUser.uid).listen(
      (data) { if (mounted) setState(() => _chatData = data); },
    );

    _otherUserSub = _chatService.watchUserProfile(widget.otherUser.uid).listen(
      (profile) { if (mounted && profile != null) setState(() => _otherUserLive = profile); },
    );

    _chatService.markRead(widget.currentUid, widget.otherUser.uid, widget.currentUid);
    _chatService.updateOnReturn(widget.currentUid);

    _player.onPositionChanged.listen((pos) {
      _positionNotifier.value = pos;
    });
    _player.onDurationChanged.listen((dur) {
      _durationNotifier.value = dur;
    });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      final justFinished = _playingNotifier.value;
      _playingNotifier.value = null;
      _isPlayingNotifier.value = false;
      _positionNotifier.value = Duration.zero;
      _durationNotifier.value = null;
      _autoPlayNext(justFinished);
    });
    _textFocus.addListener(() {
      if (_textFocus.hasFocus && _showEmojiPicker) {
        setState(() => _showEmojiPicker = false);
      }
    });
    // Trigger load-more when user scrolls near the top (pixels near maxScrollExtent
    // because reverse:true makes the bottom pixels==0 and top == maxScrollExtent).
    _scrollCtrl.addListener(_onScroll);
    _loadBackground();

    _starredSub = _chatService.starredIds(widget.currentUid).listen(
      (ids) { if (mounted) setState(() => _starredIds = ids); },
    );
    _textCtrl.addListener(_onComposeChanged);
    _restoreDraft();
  }

  // ── Drafts ─────────────────────────────────────────────────────────────────
  //
  // Kept on-device rather than in Firestore: a draft is private until sent, and
  // syncing it would leak half-written messages to the other device.

  String get _draftKey => 'draft_$_chatId';

  Future<void> _restoreDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final draft = prefs.getString(_draftKey);
    if (draft != null && draft.isNotEmpty && mounted) {
      _textCtrl.text = draft;
      _textCtrl.selection =
          TextSelection.collapsed(offset: _textCtrl.text.length);
      setState(() {});
    }
  }

  Future<void> _saveDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      await prefs.remove(_draftKey);
    } else {
      await prefs.setString(_draftKey, text);
    }
  }

  // ── Typing ─────────────────────────────────────────────────────────────────

  /// Called on every keystroke. Writes at most one "typing" stamp every three
  /// seconds, and schedules a clear so an abandoned draft stops the indicator.
  void _onComposeChanged() {
    final now = DateTime.now();
    if (_textCtrl.text.isEmpty) {
      _typingStopTimer?.cancel();
      _setTyping(false);
      _lastTypingPing = null;
      return;
    }
    if (_lastTypingPing == null ||
        now.difference(_lastTypingPing!) > const Duration(seconds: 3)) {
      _lastTypingPing = now;
      _setTyping(true);
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 5), () {
      _lastTypingPing = null;
      _setTyping(false);
    });
  }

  void _setTyping(bool typing) {
    _chatService
        .setTyping(widget.currentUid, widget.otherUser.uid, widget.currentUid,
            typing: typing)
        .ignore();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    // Reached the bottom — clear the "new messages" button.
    if (_showJumpToBottom && _scrollCtrl.position.pixels <= 80) {
      setState(() {
        _showJumpToBottom = false;
        _unseenCount = 0;
      });
    }
    if (!_hasMore || _isLoadingMore) return;
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 250) {
      _loadMoreMessages();
    }
  }

  void _jumpToNewMessages() {
    setState(() {
      _showJumpToBottom = false;
      _unseenCount = 0;
    });
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(0,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Widget _buildJumpToBottomButton() =>
      JumpToBottomButton(unseen: _unseenCount, onTap: _jumpToNewMessages);

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMore) return;
    // Oldest timestamp currently shown (either from _olderMessages or from the stream).
    final oldest = _olderMessages.isNotEmpty
        ? _olderMessages.first.timestamp
        : (_currentMessages.isNotEmpty
            ? _currentMessages.last.timestamp   // _currentMessages is descending → last = oldest
            : null);
    if (oldest == null) return;

    setState(() => _isLoadingMore = true);
    try {
      final older = await _chatService.loadOlderMessages(
          widget.currentUid, widget.otherUser.uid, oldest);
      final fresh = older.where((m) => !_loadedOlderIds.contains(m.id)).toList();
      if (fresh.isEmpty) {
        _hasMore = false;
      } else {
        _loadedOlderIds.addAll(fresh.map((m) => m.id));
        // Prepend in ascending order (fresh is ascending from service)
        _olderMessages.insertAll(0, fresh);
        if (fresh.length < 20) _hasMore = false;
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingMore = false);
  }

  Future<void> _loadBackground() async {
    final prefs = await SharedPreferences.getInstance();
    final colorVal = prefs.getInt('chat_bg_color_$_chatId');
    final imagePath = prefs.getString('chat_bg_image_$_chatId');
    if (mounted) {
      setState(() {
        _bgColor = colorVal != null ? Color(colorVal) : null;
        _bgImagePath = imagePath;
      });
    }
  }

  Future<void> _saveBgColor(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('chat_bg_color_$_chatId', color.toARGB32());
    await prefs.remove('chat_bg_image_$_chatId');
    if (mounted) setState(() { _bgColor = color; _bgImagePath = null; });
  }

  Future<void> _saveBgImage(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_bg_image_$_chatId', path);
    await prefs.remove('chat_bg_color_$_chatId');
    if (mounted) setState(() { _bgImagePath = path; _bgColor = null; });
  }

  Future<void> _resetBackground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('chat_bg_color_$_chatId');
    await prefs.remove('chat_bg_image_$_chatId');
    if (mounted) setState(() { _bgColor = null; _bgImagePath = null; });
  }

  // ── Emoji toggle ───────────────────────────────────────────────────────────

  void _toggleEmoji() {
    if (_showEmojiPicker) {
      setState(() => _showEmojiPicker = false);
      _textFocus.requestFocus();
    } else {
      _textFocus.unfocus();
      setState(() => _showEmojiPicker = true);
    }
  }

  // ── Background picker ─────────────────────────────────────────────────────

  static const _bgColors = [
    Color(0xFFF0EDF8), // default purple-tint
    Colors.white,
    Color(0xFFE8F5E9), // green
    Color(0xFFE3F2FD), // blue
    Color(0xFFFFF8E1), // yellow
    Color(0xFFFCE4EC), // pink
    Color(0xFFEDE7F6), // deep purple
    Color(0xFFE0F7FA), // cyan
    Color(0xFF1A1A2E), // dark
    Color(0xFF2D2D44), // dark purple
  ];

  void _showBackgroundPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Chat Background',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _bgColors.map((c) {
                  final selected =
                      _bgColor?.toARGB32() == c.toARGB32() ||
                      (_bgColor == null &&
                          c.toARGB32() == _defaultBgColor.toARGB32());
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _saveBgColor(c);
                    },
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? AppColors.primary
                              : AppColors.divider,
                          width: selected ? 3 : 1.5,
                        ),
                      ),
                      child: selected
                          ? const Icon(Icons.check,
                              size: 18, color: AppColors.primary)
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.photo_library_rounded),
                  label: const Text('Gallery'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final file = await _imagePicker.pickImage(
                        source: ImageSource.gallery);
                    if (file != null) _saveBgImage(file.path);
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reset'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _resetBackground();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    Widget body = Column(
      children: [
        if (_pinnedText != null && _pinnedText!.isNotEmpty)
          PinnedBanner(
            text: _pinnedText!,
            onTapJump: () {
              final id = _pinnedMessageId;
              if (id != null) _scrollToMessage(id);
            },
            onUnpin: () => _chatService
                .unpinMessage(widget.currentUid, widget.otherUser.uid)
                .ignore(),
          ),
        Expanded(
          child: Stack(
            children: [
              _buildMessageList(),
              if (_showJumpToBottom)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _buildJumpToBottomButton(),
                ),
            ],
          ),
        ),
        if (_otherTyping)
          TypingIndicator(
              label: '${(_otherUserLive ?? widget.otherUser).name} is typing…'),
        if (_isRecording) _buildRecordingBar(),
        if (_replyingTo != null) _buildReplyBar(),
        _buildInputBar(),
        if (_showEmojiPicker) _buildEmojiPicker(),
      ],
    );

    // On a tablet keep the conversation column a readable width and centred.
    // Applied before the wallpaper wrap so the background still fills the screen.
    body = ContentWidth(maxWidth: 900, child: body);

    // No wallpaper chosen: the soft gradient canvas.
    if (_bgImagePath == null && _bgColor == null) {
      body = ChatCanvas(child: body);
    }

    // Wrap with background image if set
    if (_bgImagePath != null) {
      body = Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: FileImage(File(_bgImagePath!)),
            fit: BoxFit.cover,
          ),
        ),
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: _bgColor ?? _defaultBgColor,
      appBar: AppBar(
        titleSpacing: widget.embedded ? 16 : 0,
        automaticallyImplyLeading: !widget.embedded,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const ChatHeaderBackground(),
        title: Row(
          children: [
            GestureDetector(
              onTap: (_otherUserLive ?? widget.otherUser).photoUrl != null
                  ? () => _viewFullImage(
                      (_otherUserLive ?? widget.otherUser).photoUrl!)
                  : null,
              child: HeaderAvatar(
                photoUrl: (_otherUserLive ?? widget.otherUser).photoUrl,
                name: widget.otherUser.name,
                online: _isOtherOnline,
                radius: 19,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.otherUser.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.1),
                  ),
                  const SizedBox(height: 1),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _otherTyping ? 'typing…' : _onlineStatusText,
                      key: ValueKey(_otherTyping),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _otherTyping || _isOtherOnline
                            ? const Color(0xFFB7F5C9)
                            : Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_rounded, color: Colors.white),
            onPressed: () => _startCall(isVideo: false),
            tooltip: 'Voice call',
          ),
          IconButton(
            icon: const Icon(Icons.videocam_rounded, color: Colors.white),
            onPressed: () => _startCall(isVideo: true),
            tooltip: 'Video call',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (v) {
              if (v == 'bg') _showBackgroundPicker();
              if (v == 'search') _openSearch();
              if (v == 'starred') _openStarred();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'search',
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Search messages'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'starred',
                child: Row(
                  children: [
                    Icon(Icons.star_outline_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Starred messages'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'bg',
                child: Row(
                  children: [
                    Icon(Icons.wallpaper_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Change Background'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: body,
    );
  }

  // ── Message List ──────────────────────────────────────────────────────────

  Widget _buildMessageList() {
    return StreamBuilder<List<MessageModel>>(
      stream: _messagesStream,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        // Auto-mark as read when new messages from other person arrive while chat is open
        if (snap.hasData && snap.data!.isNotEmpty) {
          final myLastRead = _parseTimestamp(_chatData?['lastReadAt_${widget.currentUid}']);
          final hasUnread = snap.data!.any((m) =>
              m.senderId != widget.currentUid &&
              (myLastRead == null || m.timestamp.isAfter(myLastRead)));
          if (hasUnread) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _chatService.markRead(
                    widget.currentUid, widget.otherUser.uid, widget.currentUid);
              }
            });
          }
        }
        // Reverse so newest is at index 0 — ListView reverse:true shows index 0 at bottom
        final streamMsgs = (snap.data ?? []).reversed.toList(); // descending

        // Merge paginated older messages: filter out any IDs already in the stream.
        final streamIds = streamMsgs.map((m) => m.id).toSet();
        final olderFiltered = _olderMessages.reversed
            .where((m) => !streamIds.contains(m.id))
            .toList(); // also descending now

        // Messages this user removed for themselves stay in Firestore for the
        // other side but must never appear here.
        final messages = [...streamMsgs, ...olderFiltered]
            .where((m) => !m.isHiddenFor(widget.currentUid))
            .toList(); // newest → oldest

        if (messages.isEmpty && _olderMessages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.chat_bubble_outline_rounded,
                    size: 56,
                    color: AppColors.textSecondary.withValues(alpha: 0.3)),
                const SizedBox(height: 12),
                Text('Say hello to ${widget.otherUser.name}!',
                    style: TextStyle(
                        color: AppColors.textSecondary.withValues(alpha: 0.6),
                        fontSize: 14)),
              ],
            ),
          );
        }

        // When a new message arrives while the user has scrolled up, keep their
        // position instead of letting the reverse list shift under them. The
        // stream window is capped at 20, so a sliding window keeps the count the
        // same — detect arrivals by the newest message id, not the count.
        // Threshold of 300 avoids jumps from small bounce / over-scroll movements.
        final newestId = streamMsgs.isNotEmpty ? streamMsgs.first.id : null;
        final newMessageArrived = _newestMsgId != null &&
            newestId != null &&
            newestId != _newestMsgId;
        if (newMessageArrived &&
            _scrollCtrl.hasClients &&
            _scrollCtrl.position.pixels > 300) {
          final pixelsBefore = _scrollCtrl.position.pixels;
          final maxBefore = _scrollCtrl.position.maxScrollExtent;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scrollCtrl.hasClients) return;
            final delta = _scrollCtrl.position.maxScrollExtent - maxBefore;
            if (delta != 0) {
              _scrollCtrl.jumpTo((pixelsBefore + delta)
                  .clamp(0.0, _scrollCtrl.position.maxScrollExtent));
            }
          });
          // Surface the "new messages" jump button for messages from the other
          // person (my own sends scroll to the bottom on their own).
          if (streamMsgs.first.senderId != widget.currentUid) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {
                _showJumpToBottom = true;
                _unseenCount++;
              });
            });
          }
        }
        // Read a newly arrived incoming message aloud, when the user has asked
        // for that. Guarded on arrival (not on build) so a rebuild for any
        // other reason does not repeat the message.
        if (newMessageArrived &&
            streamMsgs.first.senderId != widget.currentUid &&
            streamMsgs.first.type == MessageType.text &&
            !streamMsgs.first.isDeleted) {
          final m = streamMsgs.first;
          TtsService.instance.maybeAutoRead(m.id, m.text ?? '').ignore();
        }
        _newestMsgId = newestId;
        _currentMessages = messages;

        // Scroll-to-message only ever targets a loaded message, so keys for
        // messages that have fallen out of the window are dead weight — and a
        // GlobalKey is registered process-wide, so an unbounded map of them
        // leaks for as long as the chat stays open.
        if (_messageKeys.length > messages.length * 2 + 40) {
          final live = messages.map((m) => m.id).toSet();
          _messageKeys.removeWhere((id, _) => !live.contains(id));
        }

        // Prefetch image/video/audio/voice media in the visible window so they
        // display and play instantly (and stay cached locally for ~24h).
        MediaPrefetcher.prefetch(streamMsgs.map((m) {
          switch (m.type) {
            case MessageType.image:
            case MessageType.gif:
              return m.imageUrl;
            case MessageType.video:
              return m.videoUrl;
            case MessageType.voice:
            case MessageType.audioFile:
              return m.audioUrl;
            default:
              return null;
          }
        }));

        final pendingCount = _pendingItems.length;
        // +1 for the loading indicator at the top (end of reversed list)
        final totalCount = messages.length + pendingCount + (_hasMore || _isLoadingMore ? 1 : 0);
        return ListView.builder(
          controller: _scrollCtrl,
          reverse: true,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          itemCount: totalCount,
          itemBuilder: (ctx, i) {
            // Loading indicator at the very top (highest index = top in reverse list)
            if (i == totalCount - 1 && (_hasMore || _isLoadingMore)) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: _isLoadingMore
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const SizedBox.shrink(),
                ),
              );
            }
            // Pending items occupy the bottom slots (index 0 = newest in reverse list)
            if (i < pendingCount) {
              final pItem = _pendingItems[pendingCount - 1 - i];
              return _buildPendingBubble(pItem);
            }
            final msgI = i - pendingCount;
            final msg = messages[msgI];
            final isMe = msg.senderId == widget.currentUid;
            // In reversed list: messages[msgI+1] is chronologically older.
            // Show date header above the oldest message of each day.
            final showDate = msgI == messages.length - 1 ||
                !_isSameDay(messages[msgI].timestamp, messages[msgI + 1].timestamp);
            // Consecutive messages from one person within a few minutes read
            // as one run: tighter spacing, and only the last carries a tail.
            final older = msgI + 1 < messages.length ? messages[msgI + 1] : null;
            final newer = msgI > 0 ? messages[msgI - 1] : null;
            final tail = !_sameRun(newer, msg);
            final tight = !showDate && _sameRun(older, msg);
            final key = _messageKeys.putIfAbsent(msg.id, () => GlobalKey());
            final row = Column(
              key: key,
              children: [
                if (showDate) DatePill(date: msg.timestamp),
                _SwipeToReply(
                  onReply: () => _startReply(msg),
                  child: _buildBubble(msg, isMe, tail: tail, tight: tight),
                ),
              ],
            );
            // At most one message is highlighted at a time, so wrapping every
            // row in an AnimatedContainer meant an implicit animation per
            // visible row for a colour that is almost always transparent.
            if (msg.id != _fadingMessageId) return row;
            return AnimatedContainer(
              duration: _highlightFade,
              color: _highlightedMessageId == msg.id
                  ? AppColors.primary.withValues(alpha: 0.40)
                  : Colors.transparent,
              child: row,
            );
          },
        );
      },
    );
  }

  /// Whether [other] continues the same run of messages as [msg].
  bool _sameRun(MessageModel? other, MessageModel msg) {
    if (other == null) return false;
    if (other.senderId != msg.senderId) return false;
    if (!_isSameDay(other.timestamp, msg.timestamp)) return false;
    return other.timestamp.difference(msg.timestamp).inMinutes.abs() < 3;
  }

  Widget _buildBubble(MessageModel msg, bool isMe,
      {bool tail = true, bool tight = false}) {
    if (msg.type == MessageType.sticker && !msg.isDeleted) {
      return _buildStickerBubble(msg, isMe);
    }
    // A message that is only 1-3 emoji is shown large, without a bubble.
    final jumbo = !msg.isDeleted &&
            msg.type == MessageType.text &&
            msg.replyToText == null
        ? jumboEmojiCount(msg.text ?? '')
        : 0;
    if (jumbo > 0) return _buildJumboEmoji(msg, isMe, jumbo, tight: tight);

    // A tombstone carries no media, so it always renders as a plain bubble
    // regardless of what the message used to be.
    final isMedia = !msg.isDeleted &&
        (msg.type == MessageType.image ||
            msg.type == MessageType.gif ||
            msg.type == MessageType.video);

    final Widget content = msg.isDeleted
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: DeletedBubble(isMe: isMe),
          )
        : msg.type == MessageType.document
            ? _buildDocumentBubble(msg, isMe)
            : isMedia
                ? _buildMediaBubble(msg, isMe)
                : _buildTextVoiceBubble(msg, isMe);

    return GestureDetector(
      // A deleted message has no actions worth offering.
      onLongPress: msg.isDeleted ? null : () => _showMessageOptions(msg, isMe),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: EdgeInsets.only(
                top: tight ? 2 : 7,
                left: isMe ? 52 : 0,
                right: isMe ? 0 : 52,
              ),
              constraints: BoxConstraints(maxWidth: context.bubbleMaxWidth),
              child: BubbleFrame(
                isMe: isMe,
                tail: tail,
                // Photos and videos sit inset inside the bubble, so a caption
                // shares the bubble's colour instead of floating on the page.
                padding: isMedia ? const EdgeInsets.all(4) : EdgeInsets.zero,
                child: content,
              ),
            ),
            if (msg.reactions.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  bottom: 2,
                  left: isMe ? 52 : 6,
                  right: isMe ? 6 : 52,
                ),
                child: ReactionChips(
                  reactions: msg.reactions,
                  onTap: () => _showMessageOptions(msg, isMe),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildJumboEmoji(MessageModel msg, bool isMe, int count,
      {bool tight = false}) {
    return GestureDetector(
      onLongPress: () => _showMessageOptions(msg, isMe),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(
            top: tight ? 2 : 7,
            left: isMe ? 52 : 4,
            right: isMe ? 4 : 52,
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(msg.text!.trim(),
                  style: TextStyle(fontSize: jumboEmojiSize(count), height: 1.15)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: BubbleMeta(
                  time: msg.timestamp,
                  isMe: false,
                  ticks: isMe ? _buildTickIcon(msg) : null,
                ),
              ),
              if (msg.reactions.isNotEmpty)
                ReactionChips(
                  reactions: msg.reactions,
                  onTap: () => _showMessageOptions(msg, isMe),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Document attachment bubble. Tapping opens the file in whatever app the
  /// device has registered for that type.
  Widget _buildDocumentBubble(MessageModel msg, bool isMe) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 9, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (msg.isForwarded) ForwardedLabel(isMe: isMe),
          DocumentBubble(
            fileName: msg.fileName ?? 'Document',
            sizeBytes: msg.fileSizeBytes,
            isMe: isMe,
            onOpen: () => _openDocument(msg),
          ),
          const SizedBox(height: 3),
          Text(
            DateFormat('h:mm a').format(msg.timestamp),
            style: TextStyle(
              fontSize: 10,
              color: isMe ? Colors.white70 : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDocument(MessageModel msg) async {
    final url = msg.documentUrl;
    if (url == null || url.isEmpty) return;
    final ok = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) context.showError('No app can open this file');
  }

  Widget _buildStickerBubble(MessageModel msg, bool isMe) {
    return GestureDetector(
      onLongPress: () => _showMessageOptions(msg, isMe),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(
            top: 3,
            bottom: 3,
            left: isMe ? 60 : 0,
            right: isMe ? 0 : 60,
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(msg.text ?? '', style: const TextStyle(fontSize: 56)),
              Text(
                DateFormat('h:mm a').format(msg.timestamp),
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextVoiceBubble(MessageModel msg, bool isMe) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 9, 12, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (msg.replyToText != null) ...[
            _buildReplySnippet(msg, isMe),
            const SizedBox(height: 7),
          ],
          if (msg.type == MessageType.text) ...[
            Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              child: LinkableText(
                text: msg.text ?? '',
                style: ChatStyle.body(isMe),
              ),
            ),
            // Show a link preview card for the first URL in the message
            if (containsUrl(msg.text ?? ''))
              LinkPreviewWidget(
                key: ValueKey('lp_${msg.id}'),
                url: extractFirstUrl(msg.text ?? '')!,
                isMine: isMe,
              ),
          ] else if (msg.type == MessageType.audioFile)
            _buildAudioFileBubble(msg, isMe)
          else
            _buildVoiceBubble(msg, isMe),
          const SizedBox(height: 3),
          BubbleMeta(
            time: msg.timestamp,
            isMe: isMe,
            edited: msg.isEdited,
            ticks: isMe ? _buildTickIcon(msg) : null,
            leading: [
              if (msg.type == MessageType.text) ...[
                SpeakButton(
                  messageId: msg.id,
                  text: msg.text ?? '',
                  onDark: isMe,
                ),
                const SizedBox(width: 2),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMediaBubble(MessageModel msg, bool isMe) {
    final hasCaption = msg.text != null && msg.text!.isNotEmpty;
    final ticks = isMe ? _buildTickIcon(msg) : null;
    final Widget media = msg.type == MessageType.video
        ? VideoPreview(
            videoUrl: msg.videoUrl!,
            thumbUrl: msg.videoThumbUrl,
            durationMs: msg.videoDurationMs,
            isMe: isMe,
            onTap: () => _viewFullVideo(msg.videoUrl!, messageId: msg.id),
          )
        : BubblePhoto(
            url: msg.imageUrl!,
            isMe: isMe,
            onTap: () => _viewFullImage(msg.imageUrl!, messageId: msg.id),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (msg.replyToText != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 5),
            child: _buildReplySnippet(msg, isMe),
          ),
        Stack(
          children: [
            media,
            // With no caption, the time sits on the photo itself.
            if (!hasCaption)
              Positioned(
                right: 8,
                bottom: 8,
                child: BubbleMeta(
                  time: msg.timestamp,
                  isMe: isMe,
                  ticks: ticks,
                  onMedia: true,
                ),
              ),
          ],
        ),
        if (hasCaption)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: LinkableText(
                    text: msg.text!,
                    style: ChatStyle.body(isMe),
                  ),
                ),
                const SizedBox(height: 3),
                BubbleMeta(
                  time: msg.timestamp,
                  isMe: isMe,
                  edited: msg.isEdited,
                  ticks: ticks,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildReplySnippet(MessageModel msg, bool isMe) {
    final text = msg.replyToText ?? '';
    return ReplyQuote(
      label: replyLabel(
        replyToSenderId: msg.replyToSenderId,
        currentUid: widget.currentUid,
        otherName: (_otherUserLive ?? widget.otherUser).name,
      ),
      text: text,
      isMe: isMe,
      imageUrl: msg.replyToImageUrl,
      thumbBase64: msg.replyToThumb,
      isVideo: ReplyQuote.looksLikeVideo(text),
      onTap: msg.replyToId != null
          ? () => _scrollToMessage(msg.replyToId!)
          : null,
    );
  }

  Widget _buildVoiceBubble(MessageModel msg, bool isMe) {
    return VoiceMessagePlayer(
      messageId: msg.id,
      audioUrl: msg.audioUrl,
      totalSeconds: msg.audioDurationSeconds ?? 0,
      isMine: isMe,
      playingIdNotifier: _playingNotifier,
      isPlayingNotifier: _isPlayingNotifier,
      positionNotifier: _positionNotifier,
      durationNotifier: _durationNotifier,
      onToggle: () => _togglePlay(msg),
      onSeek: _seekAudio,
    );
  }

  Widget _buildAudioFileBubble(MessageModel msg, bool isMe) {
    _ensureSavedChecked(msg.id);
    return AudioFileMessage(
      messageId: msg.id,
      audioUrl: msg.audioUrl,
      fileName: msg.fileName ?? 'Audio',
      fileSizeBytes: msg.fileSizeBytes,
      totalSeconds: msg.audioDurationSeconds ?? 0,
      isMine: isMe,
      isSaved: _savedPresent[msg.id] ?? false,
      playingIdNotifier: _playingNotifier,
      isPlayingNotifier: _isPlayingNotifier,
      positionNotifier: _positionNotifier,
      durationNotifier: _durationNotifier,
      onToggle: () => _togglePlay(msg),
      onSeek: _seekAudio,
      onDownload: () => _downloadAudio(msg),
    );
  }

  Future<bool> _downloadAudio(MessageModel msg) async {
    if (msg.audioUrl == null) return false;
    // Reuse the locally cached file (no re-download) and save into Music.
    final saved = await MediaSaveService.saveReusingCache(
      url: msg.audioUrl!,
      messageId: msg.id,
      kind: SavedMediaKind.audio,
      fileName: msg.fileName,
    );
    if (saved != null && mounted) {
      setState(() => _savedPresent[msg.id] = true);
    }
    if (!mounted) return saved != null;
    if (saved != null) {
      context.showSuccess('Saved to Music');
    } else {
      context.showError('Download failed');
    }
    return saved != null;
  }

  // Tracks which media messages are saved to the device (and still present).
  // Checked lazily per session; existsFor() self-heals if the file was deleted.
  final Map<String, bool> _savedPresent = {};

  void _ensureSavedChecked(String messageId) {
    if (_savedPresent.containsKey(messageId)) return;
    _savedPresent[messageId] = false;
    SavedMediaStore.existsFor(messageId).then((present) {
      if (present && mounted) setState(() => _savedPresent[messageId] = true);
    });
  }

  // ── Reply bar ─────────────────────────────────────────────────────────────

  Widget _buildReplyBar() {
    final msg = _replyingTo!;
    final isMyMsg = msg.senderId == widget.currentUid;
    final name = isMyMsg ? 'You' : widget.otherUser.name;
    final preview = _replyToPreviewText(msg: msg) ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Container(
        decoration: composerDecoration(),
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: ReplyQuote(
                label: 'Replying to $name',
                text: preview,
                isMe: false,
                imageUrl: _replyToImageUrl(msg: msg),
                isVideo: msg.type == MessageType.video,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded,
                  size: 20, color: ChatStyle.mist),
              onPressed: () => setState(() => _replyingTo = null),
            ),
          ],
        ),
      ),
    );
  }

  // ── Recording Bar ─────────────────────────────────────────────────────────

  Widget _buildRecordingBar() {
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (d.delta.dy > 6) _stopForPreview();
      },
      child: Container(
        color: AppColors.holiday.withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                  color: AppColors.holiday, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Text('Recording  ${_fmt(_recordingSeconds)}',
                style: const TextStyle(
                    color: AppColors.holiday,
                    fontWeight: FontWeight.w600,
                    fontSize: 14)),
            const Spacer(),
            const Text('↓ Slide down to finish',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ── Input Bar ─────────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          10, 8, 10, MediaQuery.of(context).padding.bottom + 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: composerDecoration(),
              padding: const EdgeInsets.only(left: 4, right: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _inputIconBtn(
                    icon: _showEmojiPicker
                        ? Icons.keyboard_rounded
                        : Icons.emoji_emotions_outlined,
                    onTap: _toggleEmoji,
                    color: _showEmojiPicker ? ChatStyle.violet : ChatStyle.mist,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      focusNode: _textFocus,
                      style: const TextStyle(
                          fontSize: 15.5, color: ChatStyle.ink, height: 1.35),
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: InputBorder.none,
                        filled: false,
                        hintStyle:
                            TextStyle(color: ChatStyle.mist, fontSize: 15.5),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 13),
                      ),
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      // Settings → Chats → "Enter key sends".
                      textInputAction: ChatPrefs.instance.enterSends
                          ? TextInputAction.send
                          : TextInputAction.newline,
                      onSubmitted: ChatPrefs.instance.enterSends
                          ? (_) => _sendText()
                          : null,
                      contentInsertionConfiguration: ContentInsertionConfiguration(
                        allowedMimeTypes: const [
                          'image/gif',
                          'image/jpeg',
                          'image/png',
                          'image/webp',
                        ],
                        onContentInserted: _onKeyboardContentInserted,
                      ),
                    ),
                  ),
                  _inputIconBtn(
                    icon: Icons.attach_file_rounded,
                    onTap: _showAttachmentOptions,
                  ),
                  // Hidden while typing, like every major messenger.
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _textCtrl,
                    builder: (_, val, __) => val.text.trim().isEmpty
                        ? _inputIconBtn(
                            icon: Icons.photo_camera_outlined,
                            onTap: () => _pickImage(ImageSource.camera),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Send / Mic
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _textCtrl,
            builder: (_, val, __) =>
                val.text.trim().isNotEmpty ? _sendBtn() : _micBtn(),
          ),
        ],
      ),
    );
  }

  Widget _inputIconBtn({
    required IconData icon,
    required VoidCallback onTap,
    Color color = ChatStyle.mist,
  }) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 40,
          height: 48,
          child: Icon(icon, color: color, size: 24),
        ),
      );

  Widget _buildEmojiPicker() {
    return SizedBox(
      height: 256,
      child: EmojiPicker(
        textEditingController: _textCtrl,
        config: Config(
          height: 256,
          checkPlatformCompatibility: true,
          emojiViewConfig: EmojiViewConfig(
            emojiSizeMax: 28 * (Platform.isIOS ? 1.20 : 1.0),
            columns: 8,
          ),
          skinToneConfig: const SkinToneConfig(),
          categoryViewConfig: const CategoryViewConfig(
            initCategory: Category.RECENT,
          ),
          bottomActionBarConfig: BottomActionBarConfig(
            backgroundColor: Colors.white,
            buttonColor: Colors.white,
            buttonIconColor: AppColors.primary,
          ),
        ),
      ),
    );
  }

  Widget _sendBtn() => _isSending
      ? Container(
          width: 50,
          height: 50,
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(
              shape: BoxShape.circle, gradient: ChatStyle.outgoing),
          child: const CircularProgressIndicator(
              strokeWidth: 2, color: Colors.white),
        )
      : GradientCircleButton(icon: Icons.send_rounded, onTap: _sendText);

  Widget _micBtn() {
    return GestureDetector(
      onVerticalDragStart: (d) {
        _dragStartY = d.globalPosition.dy;
        _recordingStartedByDrag = false;
      },
      onVerticalDragUpdate: (d) async {
        final dy = d.globalPosition.dy - _dragStartY;
        if (dy < -30 && !_isRecording && !_recordingStartedByDrag) {
          _recordingStartedByDrag = true;
          await _startRecording();
        }
      },
      onTap: _isRecording ? _stopForPreview : _startRecording,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: _isRecording ? 56 : 50,
        height: _isRecording ? 56 : 50,
        decoration: BoxDecoration(
          color: _isRecording ? AppColors.holiday : null,
          gradient: _isRecording ? null : ChatStyle.outgoing,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: (_isRecording ? AppColors.holiday : ChatStyle.violet)
                  .withValues(alpha: 0.4),
              blurRadius: _isRecording ? 16 : 14,
              spreadRadius: _isRecording ? 3 : 0,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Icon(
          _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
          color: Colors.white,
          size: _isRecording ? 26 : 22,
        ),
      ),
    );
  }

  // ── Attachment options ────────────────────────────────────────────────────

  void _showAttachmentOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.camera_alt_rounded,
                    color: AppColors.primary, size: 22),
              ),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.photo_library_rounded,
                    color: AppColors.primary, size: 22),
              ),
              title: const Text('Gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.videocam_rounded,
                    color: AppColors.primary, size: 22),
              ),
              title: const Text('Video'),
              onTap: () {
                Navigator.pop(ctx);
                _pickVideo();
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.audiotrack_rounded,
                    color: AppColors.primary, size: 22),
              ),
              title: const Text('Audio'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAudioFile();
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.description_rounded,
                    color: AppColors.primary, size: 22),
              ),
              title: const Text('Document'),
              subtitle: const Text('PDF, Word, Excel, and more',
                  style: TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                _pickDocument();
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.gif_rounded,
                    color: AppColors.primary, size: 26),
              ),
              title: const Text('GIF'),
              onTap: () {
                Navigator.pop(ctx);
                _showGifPicker();
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Text('😊',
                    style: TextStyle(fontSize: 22), textAlign: TextAlign.center),
              ),
              title: const Text('Sticker'),
              onTap: () {
                Navigator.pop(ctx);
                _showStickerPicker();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _onKeyboardContentInserted(KeyboardInsertedContent content) async {
    final bytes = content.data;
    if (bytes == null || !mounted) return;
    final dir = await getTemporaryDirectory();
    final ext = content.mimeType.split('/').last.split('+').first;
    final file = File(
        '${dir.path}/keyboard_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await file.writeAsBytes(bytes);
    if (!mounted) return;
    final item = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.image,
      localFile: file,
      replyToText: _replyToPreviewText(),
      replyToId: _replyingTo?.id,
      replyToImageUrl: _replyToImageUrl(),
      replyToSenderId: _replyingTo?.senderId,
    );
    if (mounted) setState(() => _replyingTo = null);
    await _enqueuePending(item);
  }

  Future<void> _pickVideo() async {
    final XFile? file = await _imagePicker.pickVideo(source: ImageSource.gallery);
    if (file == null || !mounted) return;

    final compressed = await VideoCompress.compressVideo(
      file.path,
      quality: VideoQuality.MediumQuality,
      deleteOrigin: false,
      includeAudio: true,
    );
    if (compressed?.path == null || !mounted) return;

    // Ask for an optional caption (null = user dismissed → cancel send).
    final caption = await showCaptionSheet(context);
    if (caption == null || !mounted) return;

    final item = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.video,
      localFile: File(compressed!.path!),
      caption: caption.isEmpty ? null : caption,
      replyToText: _replyToPreviewText(),
      replyToId: _replyingTo?.id,
      replyToImageUrl: _replyToImageUrl(),
      replyToSenderId: _replyingTo?.senderId,
    );
    if (mounted) setState(() => _replyingTo = null);
    await _enqueuePending(item);
  }

  Future<void> _pickAudioFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result == null || result.files.isEmpty || !mounted) return;
    final picked = result.files.single;
    if (picked.path == null) return;

    final dur = await _probeAudioDuration(picked.path!);
    if (!mounted) return;

    final item = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.audioFile,
      localFile: File(picked.path!),
      fileName: picked.name,
      fileSizeBytes: picked.size,
      voiceDuration: dur,
      replyToText: _replyToPreviewText(),
      replyToId: _replyingTo?.id,
      replyToImageUrl: _replyToImageUrl(),
      replyToSenderId: _replyingTo?.senderId,
    );
    if (mounted) setState(() => _replyingTo = null);
    await _enqueuePending(item);
  }

  /// Any file type. `FileType.any` rather than a whitelist — the receiving side
  /// opens it with whatever app handles that extension, so restricting the
  /// picker would only block legitimate files without adding safety.
  Future<void> _pickDocument() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.isEmpty || !mounted) return;
    final picked = result.files.single;
    if (picked.path == null) return;

    // Storage uploads and the receiving device both suffer on very large
    // files; 50 MB is a generous ceiling that still fails fast and clearly.
    const maxBytes = 50 * 1024 * 1024;
    if (picked.size > maxBytes) {
      context.showError('File is too large (max 50 MB)');
      return;
    }

    final item = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.document,
      localFile: File(picked.path!),
      fileName: picked.name,
      fileSizeBytes: picked.size,
      replyToText: _replyToPreviewText(),
      replyToId: _replyingTo?.id,
      replyToImageUrl: _replyToImageUrl(),
      replyToSenderId: _replyingTo?.senderId,
    );
    setState(() => _replyingTo = null);
    await _enqueuePending(item);
  }

  // Best-effort duration probe so the bubble can show total time before play.
  Future<int> _probeAudioDuration(String path) async {
    final probe = AudioPlayer();
    try {
      await probe.setSource(DeviceFileSource(path));
      // getDuration may need a moment after the source is prepared.
      for (var i = 0; i < 10; i++) {
        final d = await probe.getDuration();
        if (d != null && d.inMilliseconds > 0) return d.inSeconds;
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
    } finally {
      await probe.dispose();
    }
    return 0;
  }

  Future<void> _pickImage(ImageSource source) async {
    final XFile? file =
        await _imagePicker.pickImage(source: source, imageQuality: 85);
    if (file == null || !mounted) return;

    // Open editor — user can draw / crop and add a caption before sending
    final ImageEditResult? edited = await Navigator.push<ImageEditResult>(
      context,
      MaterialPageRoute(
          builder: (_) => ImageEditScreen(imageFile: File(file.path))),
    );
    if (edited == null || !mounted) return;

    final item = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.image,
      localFile: edited.file,
      caption: edited.caption,
      replyToText: _replyToPreviewText(),
      replyToId: _replyingTo?.id,
      replyToImageUrl: _replyToImageUrl(),
      replyToSenderId: _replyingTo?.senderId,
    );
    if (mounted) setState(() => _replyingTo = null);
    await _enqueuePending(item);
  }

  Future<void> _showGifPicker() async {
    final String? gifUrl = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const GifPickerSheet(),
    );
    if (gifUrl == null || !mounted) return;

    final item = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.gif,
      gifUrl: gifUrl,
      replyToText: _replyToPreviewText(),
      replyToId: _replyingTo?.id,
      replyToImageUrl: _replyToImageUrl(),
      replyToSenderId: _replyingTo?.senderId,
    );
    if (mounted) setState(() => _replyingTo = null);
    await _enqueuePending(item);
  }

  Future<void> _showStickerPicker() async {
    final String? sticker = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const StickerPickerSheet(),
    );
    if (sticker == null || !mounted) return;

    final item = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.sticker,
      sticker: sticker,
      replyToText: _replyToPreviewText(),
      replyToId: _replyingTo?.id,
      replyToImageUrl: _replyToImageUrl(),
      replyToSenderId: _replyingTo?.senderId,
    );
    if (mounted) setState(() => _replyingTo = null);
    await _enqueuePending(item);
  }

  // ── Pending (optimistic) bubbles ──────────────────────────────────────────

  Widget _buildPendingBubble(_PendingItem item) {
    if (item.type == MessageType.sticker) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 3, bottom: 3, left: 60),
          child: Stack(
            children: [
              Text(item.sticker!, style: const TextStyle(fontSize: 56)),
              if (item.status == _PendingStatus.sending)
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    ),
                  ),
                ),
              if (item.status == _PendingStatus.failed)
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => _retryPending(item.id),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                          color: Colors.red.shade600,
                          shape: BoxShape.circle),
                      child: const Icon(Icons.refresh_rounded,
                          color: Colors.white, size: 14),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // Voice pending bubble
    if (item.type == MessageType.voice) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: 3, bottom: 3, left: 60),
          constraints: BoxConstraints(maxWidth: context.bubbleMaxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [BoxShadow(color: AppColors.cardShadow, blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36, height: 36,
                decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                child: const Icon(Icons.mic_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Voice message',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                    if (item.voiceDuration != null)
                      Text(
                        '${item.voiceDuration! ~/ 60}:${(item.voiceDuration! % 60).toString().padLeft(2, '0')}',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              item.status == _PendingStatus.failed
                  ? GestureDetector(
                      onTap: () => _retryPending(item.id),
                      child: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 20),
                    )
                  : const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    // Audio-file pending bubble
    if (item.type == MessageType.audioFile) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: 3, bottom: 3, left: 60),
          constraints: BoxConstraints(maxWidth: context.bubbleMaxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [BoxShadow(color: AppColors.cardShadow, blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36, height: 36,
                decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                child: const Icon(Icons.audiotrack_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(item.fileName ?? 'Audio',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
              const SizedBox(width: 10),
              item.status == _PendingStatus.failed
                  ? GestureDetector(
                      onTap: () => _retryPending(item.id),
                      child: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 20),
                    )
                  : const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    // Image / Video / GIF pending bubble
    Widget content;
    if (item.type == MessageType.video) {
      content = Container(
        height: 180,
        width: double.infinity,
        color: Colors.black87,
        child: const Center(
          child: Icon(Icons.videocam_rounded, color: Colors.white54, size: 48),
        ),
      );
    } else if (item.localFile != null) {
      content = Image.file(item.localFile!,
          fit: BoxFit.cover, width: double.infinity);
    } else if (item.gifUrl != null) {
      content = CachedNetworkImage(
        imageUrl: item.gifUrl!,
        memCacheWidth: kBubbleImageDecodeWidth,
        fit: BoxFit.cover,
        width: double.infinity,
        placeholder: (_, __) =>
            Container(height: 160, color: AppColors.background),
        errorWidget: (_, __, ___) =>
            Container(height: 160, color: AppColors.background,
                child: const Icon(Icons.broken_image_outlined,
                    color: AppColors.textSecondary)),
      );
    } else {
      content = Container(height: 160, color: AppColors.background);
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 3, bottom: 3, left: 60),
        constraints: BoxConstraints(
            maxWidth: context.bubbleMaxWidth),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
                color: AppColors.cardShadow,
                blurRadius: 4,
                offset: const Offset(0, 2))
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              content,
              // Loading overlay
              if (item.status == _PendingStatus.sending)
                Positioned.fill(
                  child: Container(
                    color: Colors.black38,
                    child: const Center(
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5),
                    ),
                  ),
                ),
              // Error overlay with retry
              if (item.status == _PendingStatus.failed)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: Colors.white, size: 28),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () => _retryPending(item.id),
                          child: const Text('Tap to retry',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  decoration: TextDecoration.underline,
                                  decorationColor: Colors.white)),
                        ),
                      ],
                    ),
                  ),
                ),
              // Cancel button
              Positioned(
                top: 6,
                right: 6,
                child: GestureDetector(
                  onTap: () => _cancelPending(item.id),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _enqueuePending(_PendingItem item) async {
    if (mounted) setState(() => _pendingItems.add(item));
    _scrollToBottom();
    await _executePend(item);
  }

  Future<void> _executePend(_PendingItem item) async {
    try {
      switch (item.type) {
        case MessageType.image:
          await _chatService.sendImageMessage(
            senderUid: widget.currentUid,
            receiverUid: widget.otherUser.uid,
            imageFile: item.localFile!,
            text: item.caption,
            replyToId: item.replyToId,
            replyToText: item.replyToText,
            replyToImageUrl: item.replyToImageUrl,
            replyToSenderId: item.replyToSenderId,
          );
        case MessageType.gif:
          await _chatService.sendGifMessage(
            senderUid: widget.currentUid,
            receiverUid: widget.otherUser.uid,
            gifUrl: item.gifUrl!,
            replyToId: item.replyToId,
            replyToText: item.replyToText,
            replyToImageUrl: item.replyToImageUrl,
            replyToSenderId: item.replyToSenderId,
          );
        case MessageType.sticker:
          await _chatService.sendStickerMessage(
            senderUid: widget.currentUid,
            receiverUid: widget.otherUser.uid,
            sticker: item.sticker!,
            replyToId: item.replyToId,
            replyToText: item.replyToText,
            replyToImageUrl: item.replyToImageUrl,
            replyToSenderId: item.replyToSenderId,
          );
        case MessageType.video:
          await _chatService.sendVideoMessage(
            senderUid: widget.currentUid,
            receiverUid: widget.otherUser.uid,
            videoFile: item.localFile!,
            text: item.caption,
            replyToId: item.replyToId,
            replyToText: item.replyToText,
            replyToImageUrl: item.replyToImageUrl,
            replyToSenderId: item.replyToSenderId,
          );
        case MessageType.voice:
          await _chatService.sendVoiceMessage(
            senderUid: widget.currentUid,
            receiverUid: widget.otherUser.uid,
            audioFile: item.localFile!,
            durationSeconds: item.voiceDuration ?? 0,
            replyToId: item.replyToId,
            replyToText: item.replyToText,
            replyToImageUrl: item.replyToImageUrl,
            replyToSenderId: item.replyToSenderId,
          );
        case MessageType.audioFile:
          await _chatService.sendAudioFileMessage(
            senderUid: widget.currentUid,
            receiverUid: widget.otherUser.uid,
            audioFile: item.localFile!,
            fileName: item.fileName ?? 'audio',
            fileSizeBytes: item.fileSizeBytes ?? 0,
            durationSeconds: item.voiceDuration ?? 0,
            replyToId: item.replyToId,
            replyToText: item.replyToText,
            replyToImageUrl: item.replyToImageUrl,
            replyToSenderId: item.replyToSenderId,
          );
        case MessageType.document:
          await _chatService.sendDocumentMessage(
            senderUid: widget.currentUid,
            receiverUid: widget.otherUser.uid,
            file: item.localFile!,
            fileName: item.fileName ?? 'file',
            fileSizeBytes: item.fileSizeBytes ?? 0,
            replyToId: item.replyToId,
            replyToText: item.replyToText,
            replyToImageUrl: item.replyToImageUrl,
            replyToSenderId: item.replyToSenderId,
          );
        default:
          break;
      }
      if (mounted && !item.isCancelled) {
        setState(() => _pendingItems.removeWhere((p) => p.id == item.id));
      }
    } catch (_) {
      // Persist the attempt so leaving the screen — or the app being killed —
      // doesn't discard it. The in-screen "failed" state still lets the user
      // retry immediately; the outbox is the backstop.
      if (!item.isCancelled) {
        unawaited(OutboxService.instance.enqueue(OutboxEntry(
          id: item.id,
          type: item.type,
          senderUid: widget.currentUid,
          receiverUid: widget.otherUser.uid,
          text: item.caption,
          localPath: item.localFile?.path,
          fileName: item.fileName,
          fileSizeBytes: item.fileSizeBytes,
          durationSeconds: item.voiceDuration,
        )));
      }
      if (mounted && !item.isCancelled) {
        setState(() => item.status = _PendingStatus.failed);
      }
    }
  }

  Future<void> _retryPending(String id) async {
    final idx = _pendingItems.indexWhere((p) => p.id == id);
    if (idx == -1) return;
    final item = _pendingItems[idx];
    setState(() => item.status = _PendingStatus.sending);
    await _executePend(item);
  }

  void _cancelPending(String id) {
    final idx = _pendingItems.indexWhere((p) => p.id == id);
    if (idx == -1) return;
    _pendingItems[idx].isCancelled = true;
    setState(() => _pendingItems.removeAt(idx));
  }

  void _viewFullImage(String url, {String? messageId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenImageViewer(url: url, messageId: messageId),
      ),
    );
  }

  void _viewFullVideo(String url, {String? messageId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenVideoViewer(url: url, messageId: messageId),
      ),
    );
  }

  Future<void> _saveToGallery(String url, String messageId,
      {required bool isVideo}) async {
    // Reuse the cached file (no re-download) and save into the gallery.
    final saved = await MediaSaveService.saveReusingCache(
      url: url,
      messageId: messageId,
      kind: isVideo ? SavedMediaKind.video : SavedMediaKind.image,
    );
    if (saved != null && mounted) {
      setState(() => _savedPresent[messageId] = true);
    }
    if (!mounted) return;
    if (saved != null) {
      context.showSuccess('Saved to gallery');
    } else {
      context.showError('Save failed');
    }
  }

  // ── Message Options (long press) ──────────────────────────────────────────

  void _showMessageOptions(MessageModel msg, bool isMe) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
            ReactionPickerRow(
              current: msg.reactions[widget.currentUid],
              onPick: (emoji) {
                Navigator.pop(ctx);
                _react(msg, emoji);
              },
            ),
            const Divider(height: 12),
            ListTile(
              leading:
                  const Icon(Icons.reply_rounded, color: AppColors.primary),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(ctx);
                _startReply(msg);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.shortcut_rounded, color: AppColors.primary),
              title: const Text('Forward'),
              onTap: () {
                Navigator.pop(ctx);
                _forwardMessage(msg);
              },
            ),
            ListTile(
              leading: Icon(
                _starredIds.contains(msg.id)
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                color: Colors.amber.shade700,
              ),
              title: Text(_starredIds.contains(msg.id) ? 'Unstar' : 'Star'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleStar(msg);
              },
            ),
            ListTile(
              leading: Icon(
                _pinnedMessageId == msg.id
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                color: AppColors.primary,
              ),
              title: Text(_pinnedMessageId == msg.id ? 'Unpin' : 'Pin'),
              onTap: () {
                Navigator.pop(ctx);
                _togglePin(msg);
              },
            ),
            if (msg.type == MessageType.text && isSpeakable(msg.text ?? ''))
              ListTile(
                leading: const Icon(Icons.volume_up_rounded,
                    color: AppColors.primary),
                title: const Text('Read aloud'),
                onTap: () {
                  Navigator.pop(ctx);
                  TtsService.instance.speak(msg.id, msg.text!);
                },
              ),
            if (msg.type == MessageType.text && (msg.text ?? '').isNotEmpty)
              ListTile(
                leading:
                    const Icon(Icons.copy_rounded, color: AppColors.primary),
                title: const Text('Copy'),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: msg.text!));
                  context.showSuccess('Copied');
                },
              ),
            if (msg.type == MessageType.image || msg.type == MessageType.gif)
              ListTile(
                leading: const Icon(Icons.download_rounded,
                    color: AppColors.primary),
                title: const Text('Save to Gallery'),
                onTap: () {
                  Navigator.pop(ctx);
                  _saveToGallery(msg.imageUrl!, msg.id, isVideo: false);
                },
              ),
            if (msg.type == MessageType.video)
              ListTile(
                leading: const Icon(Icons.download_rounded,
                    color: AppColors.primary),
                title: const Text('Save to Gallery'),
                onTap: () {
                  Navigator.pop(ctx);
                  _saveToGallery(msg.videoUrl!, msg.id, isVideo: true);
                },
              ),
            if (isMe && msg.type == MessageType.text)
              ListTile(
                leading: const Icon(Icons.edit_rounded,
                    color: AppColors.primary),
                title: const Text('Edit Message'),
                onTap: () {
                  Navigator.pop(ctx);
                  _editMessage(msg);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.holiday),
              title: const Text('Delete Message',
                  style: TextStyle(color: AppColors.holiday)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMessage(msg, isMe: isMe);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MessageSearchScreen(
          title: (_otherUserLive ?? widget.otherUser).name,
          onSearch: (q) => _chatService.searchMessages(
            uid1: widget.currentUid,
            uid2: widget.otherUser.uid,
            query: q,
          ),
          // Only offer to jump if the message is in the loaded window —
          // otherwise the tap would appear to do nothing.
          onOpen: (m) => _scrollToMessage(m.id),
        ),
      ),
    );
  }

  void _openStarred() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StarredMessagesScreen(uid: widget.currentUid),
      ),
    );
  }

  // ── New message actions ────────────────────────────────────────────────────

  Future<void> _react(MessageModel msg, String emoji) async {
    await _chatService.toggleReaction(
      uid1: widget.currentUid,
      uid2: widget.otherUser.uid,
      messageId: msg.id,
      reactorUid: widget.currentUid,
      emoji: emoji,
      current: msg.reactions[widget.currentUid],
    );
  }

  Future<void> _forwardMessage(MessageModel msg) async {
    final target = await showForwardSheet(context, currentUid: widget.currentUid);
    if (target == null || !mounted) return;
    try {
      if (target.isGroup) {
        final g = target.group!;
        final provider = context.read<AppProvider>();
        await GroupChatService().forwardMessage(
          source: msg,
          groupId: g.id,
          senderId: widget.currentUid,
          senderName: provider.profile?.name ?? '',
          participants: g.participants,
          preview: ChatService.messagePreview(msg),
        );
      } else {
        await _chatService.forwardMessage(
          source: msg,
          senderUid: widget.currentUid,
          receiverUid: target.user!.uid,
        );
      }
      if (mounted) context.showSuccess('Forwarded to ${target.label}');
    } catch (_) {
      if (mounted) context.showError('Could not forward message');
    }
  }

  Future<void> _toggleStar(MessageModel msg) async {
    final starred = _starredIds.contains(msg.id);
    try {
      if (starred) {
        await _chatService.unstarMessage(widget.currentUid, msg.id);
        if (mounted) context.showSuccess('Removed from starred');
      } else {
        await _chatService.starMessage(
          uid: widget.currentUid,
          msg: msg,
          chatLabel: widget.otherUser.name,
        );
        if (mounted) context.showSuccess('Starred');
      }
    } catch (_) {
      if (mounted) context.showError('Could not update starred messages');
    }
  }

  Future<void> _togglePin(MessageModel msg) async {
    try {
      if (_pinnedMessageId == msg.id) {
        await _chatService.unpinMessage(widget.currentUid, widget.otherUser.uid);
      } else {
        await _chatService.pinMessage(
          uid1: widget.currentUid,
          uid2: widget.otherUser.uid,
          msg: msg,
          pinnedBy: widget.currentUid,
        );
      }
    } catch (_) {
      if (mounted) context.showError('Could not update the pinned message');
    }
  }

  void _editMessage(MessageModel msg) {
    final ctrl = TextEditingController(text: msg.text);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Message'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: 'Edit your message...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newText = ctrl.text.trim();
              if (newText.isEmpty) return;
              await _chatService.editMessage(
                uid1: widget.currentUid,
                uid2: widget.otherUser.uid,
                messageId: msg.id,
                newText: newText,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// "For everyone" is offered only on your own messages — you can always
  /// remove someone else's copy from your view, never from theirs.
  Future<void> _deleteMessage(MessageModel msg, {required bool isMe}) async {
    final choice =
        await showDeleteChoice(context, canDeleteForEveryone: isMe);
    if (choice == null || !mounted) return;

    try {
      if (choice == DeleteChoice.forEveryone) {
        await _chatService.deleteMessage(
          uid1: widget.currentUid,
          uid2: widget.otherUser.uid,
          messageId: msg.id,
          audioUrl: msg.audioUrl,
          imageUrl: msg.imageUrl,
          videoUrl: msg.videoUrl,
          videoThumbUrl: msg.videoThumbUrl,
          documentUrl: msg.documentUrl,
        );
        evictMediaFromCache(
            [msg.audioUrl, msg.imageUrl, msg.videoUrl, msg.videoThumbUrl, msg.documentUrl]);
        // A pin pointing at a message that no longer has content is noise.
        if (_pinnedMessageId == msg.id) {
          await _chatService.unpinMessage(
              widget.currentUid, widget.otherUser.uid);
        }
      } else {
        await _chatService.deleteMessageForMe(
          uid1: widget.currentUid,
          uid2: widget.otherUser.uid,
          messageId: msg.id,
          uid: widget.currentUid,
        );
      }
    } catch (_) {
      if (mounted) context.showError('Could not delete message');
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _startCall({required bool isVideo}) {
    if (CallService().isInCall) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are already in a call')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          callId: '',
          isOutgoing: true,
          callType: isVideo ? CallType.video : CallType.voice,
          otherUser: widget.otherUser,
          currentUid: widget.currentUid,
        ),
      ),
    );
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(0); // reverse:true → 0 = bottom
    }
  }

  Future<void> _scrollToMessage(String messageId) async {
    final index = _currentMessages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;

    final key = _messageKeys[messageId];

    // If already rendered, scroll directly to it
    if (key?.currentContext != null) {
      await Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.3,
      );
      _highlightMessage(messageId);
      return;
    }

    // Not visible — estimate pixel offset and jump there first
    // reverse:true → index 0 = bottom (pixels=0), older msgs have higher pixels
    const avgItemHeight = 72.0;
    final estimated = (index * avgItemHeight)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    await _scrollCtrl.animateTo(
      estimated,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );

    // After layout the item is now rendered — snap precisely
    await WidgetsBinding.instance.endOfFrame;
    if (key?.currentContext != null) {
      await Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.3,
      );
    }
    _highlightMessage(messageId);
  }

  static const _highlightFade = Duration(milliseconds: 300);

  void _highlightMessage(String messageId) {
    setState(() {
      _highlightedMessageId = messageId;
      _fadingMessageId = messageId;
    });
    Future.delayed(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      setState(() => _highlightedMessageId = null);
      // Keep the animated wrapper alive just long enough to fade back out.
      Future.delayed(_highlightFade, () {
        if (mounted && _highlightedMessageId == null) {
          setState(() => _fadingMessageId = null);
        }
      });
    });
  }

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    final reply = _replyingTo;
    setState(() {
      _isSending = true;
      _replyingTo = null;
    });
    try {
      await _chatService.sendTextMessage(
        senderUid: widget.currentUid,
        receiverUid: widget.otherUser.uid,
        text: text,
        replyToId: reply?.id,
        replyToText: _replyToPreviewText(msg: reply),
        replyToImageUrl: _replyToImageUrl(msg: reply),
        replyToSenderId: reply?.senderId,
      );
      _scrollToBottom();
    } catch (_) {
      if (mounted) context.showError('Failed to send message');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  String? _replyToPreviewText({MessageModel? msg}) {
    final m = msg ?? _replyingTo;
    if (m == null) return null;
    if (m.type == MessageType.text) return m.text;
    if (m.type == MessageType.voice) return '🎤 Voice message';
    if (m.type == MessageType.audioFile) return '🎵 ${m.fileName ?? 'Audio'}';
    if (m.type == MessageType.image) {
      return m.text?.isNotEmpty == true ? '📷 ${m.text}' : '📷 Photo';
    }
    if (m.type == MessageType.video) {
      return m.text?.isNotEmpty == true ? '🎥 ${m.text}' : '🎥 Video';
    }
    if (m.type == MessageType.gif) return '🎞️ GIF';
    if (m.type == MessageType.sticker) return m.text;
    return null;
  }

  String? _replyToImageUrl({MessageModel? msg}) {
    final m = msg ?? _replyingTo;
    if (m == null) return null;
    if (m.type == MessageType.image || m.type == MessageType.gif) {
      return m.imageUrl;
    }
    // A video's uploaded still doubles as its reply thumbnail.
    if (m.type == MessageType.video) return m.videoThumbUrl;
    return null;
  }

  void _startReply(MessageModel msg) {
    setState(() => _replyingTo = msg);
    _textFocus.requestFocus();
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Microphone permission required')));
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    _recordingSeconds = 0;
    await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: _recordingPath!);
    _recordingTimer =
        Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordingSeconds++);
    });
    if (mounted) setState(() => _isRecording = true);
  }

  Future<void> _stopForPreview() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();
    final path = await _recorder.stop();
    if (mounted) setState(() => _isRecording = false);

    if (path == null || _recordingSeconds < 1) return;
    final dur = _recordingSeconds;
    if (!mounted) return;

    final pendingVoice = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.voice,
      localFile: File(path),
      voiceDuration: dur,
      replyToText: _replyToPreviewText(),
      replyToId: _replyingTo?.id,
      replyToImageUrl: _replyToImageUrl(),
      replyToSenderId: _replyingTo?.senderId,
    );
    if (mounted) setState(() => _replyingTo = null);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VoicePreviewSheet(
        audioPath: path,
        durationSeconds: dur,
        onSend: () async {
          unawaited(_enqueuePending(pendingVoice));
        },
      ),
    );
  }

  Future<void> _togglePlay(MessageModel msg) async {
    if (_playingNotifier.value == msg.id) {
      // Same message — toggle between playing and paused
      if (_isPlayingNotifier.value) {
        await _player.pause();
        _isPlayingNotifier.value = false;
      } else {
        await _player.resume();
        _isPlayingNotifier.value = true;
      }
    } else {
      // Different message — reset position and start fresh
      _positionNotifier.value = Duration.zero;
      _durationNotifier.value = null;
      _playingNotifier.value = msg.id;
      _isPlayingNotifier.value = true;
      await _playFromCacheOrUrl(msg.audioUrl!);
    }
  }

  /// Plays from the locally cached file when available (instant, offline) and
  /// falls back to streaming from the URL.
  Future<void> _playFromCacheOrUrl(String url) async {
    final file = await getCachedMediaFile(url);
    if (file != null) {
      await _player.play(DeviceFileSource(file.path));
    } else {
      await _player.play(UrlSource(url));
    }
  }

  // Auto-play: after a voice message ends, find the next non-mine voice message
  // and start it automatically. _currentMessages is descending (index 0 = newest),
  // so "next in time" means searching toward lower indices.
  void _autoPlayNext(String? finishedId) {
    if (finishedId == null) return;
    final idx = _currentMessages.indexWhere((m) => m.id == finishedId);
    if (idx < 0) return;
    for (int i = idx - 1; i >= 0; i--) {
      final m = _currentMessages[i];
      if (m.type == MessageType.voice &&
          m.senderId != widget.currentUid &&
          m.audioUrl != null) {
        _positionNotifier.value = Duration.zero;
        _durationNotifier.value = null;
        _playingNotifier.value = m.id;
        _isPlayingNotifier.value = true;
        _playFromCacheOrUrl(m.audioUrl!).ignore();
        return;
      }
    }
  }

  Future<void> _seekAudio(Duration position) async {
    await _player.seek(position);
    _positionNotifier.value = position;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  DateTime? _parseTimestamp(dynamic value) {
    if (value is Timestamp) return value.toDate();
    return null;
  }

  bool get _isOtherOnline {
    final profile = _otherUserLive ?? widget.otherUser;
    return DateTime.now().difference(profile.lastSeen) < kOnlineWindow;
  }

  String get _onlineStatusText {
    final profile = _otherUserLive ?? widget.otherUser;
    final dt = profile.lastSeen;
    final now = DateTime.now();
    if (DateTime.now().difference(dt).inMinutes < 2) return 'Online';
    if (_isSameDay(dt, now)) return 'last seen today at ${DateFormat('h:mm a').format(dt)}';
    if (_isSameDay(dt, now.subtract(const Duration(days: 1)))) {
      return 'last seen yesterday at ${DateFormat('h:mm a').format(dt)}';
    }
    return 'last seen ${DateFormat('d MMM').format(dt)}';
  }

  Widget _buildTickIcon(MessageModel msg) {
    final otherUid = widget.otherUser.uid;
    final lastReadAt = _parseTimestamp(_chatData?['lastReadAt_$otherUid']);
    final lastDeliveredAt = _parseTimestamp(_chatData?['lastDeliveredAt_$otherUid']);

    final isRead = lastReadAt != null && !msg.timestamp.isAfter(lastReadAt);
    final isDelivered = lastDeliveredAt != null && !msg.timestamp.isAfter(lastDeliveredAt);

    const readColor = Color(0xFF4FC3F7);
    const pendingColor = Colors.white60;

    if (isRead) {
      return _doubleTick(readColor);
    } else if (isDelivered) {
      return _doubleTick(pendingColor);
    } else {
      return const Icon(Icons.check_rounded, size: 13, color: pendingColor);
    }
  }

  Widget _doubleTick(Color color) {
    return SizedBox(
      width: 18,
      height: 13,
      child: Stack(
        children: [
          Positioned(left: 0, child: Icon(Icons.check_rounded, size: 13, color: color)),
          Positioned(left: 5, child: Icon(Icons.check_rounded, size: 13, color: color)),
        ],
      ),
    );
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(1, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  void dispose() {
    if (ActiveChatTracker.activeChatId == _chatId) {
      ActiveChatTracker.activeChatId = null;
    }
    // Don't let a message keep being read after the chat is closed.
    TtsService.instance.stop().ignore();
    // Guarantee unread is 0 for the current user when leaving the chat,
    // regardless of whether messages arrived during this session.
    _chatService.markRead(widget.currentUid, widget.otherUser.uid, widget.currentUid).ignore();
    _chatDataSub?.cancel();
    _otherUserSub?.cancel();
    _starredSub?.cancel();
    // Persist whatever is still in the box, and stop advertising typing.
    _typingStopTimer?.cancel();
    _saveDraft().ignore();
    _setTyping(false);

    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _textFocus.dispose();
    _recordingTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    _playingNotifier.dispose();
    _isPlayingNotifier.dispose();
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    super.dispose();
  }
}

// ── Swipe-to-reply wrapper ────────────────────────────────────────────────────

class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;

  const _SwipeToReply({required this.child, required this.onReply});

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _threshold = 60.0;
  double _offset = 0;
  bool _triggered = false;
  Offset? _start;

  void _down(PointerDownEvent e)     { _start = e.localPosition; _triggered = false; }
  void _cancel(PointerCancelEvent e) { _start = null; _triggered = false; if (_offset != 0) setState(() => _offset = 0); }

  void _move(PointerMoveEvent e) {
    if (_start == null) return;
    final dx = e.localPosition.dx - _start!.dx;
    final dy = (e.localPosition.dy - _start!.dy).abs();
    if (dy > dx) { if (_offset != 0) setState(() => _offset = 0); return; }
    if (dx <= 0) return;
    final next = dx.clamp(0.0, _threshold + 12);
    setState(() => _offset = next);
    if (next >= _threshold && !_triggered) {
      _triggered = true;
      HapticFeedback.lightImpact();
    }
  }

  void _up(PointerUpEvent e) {
    if (_triggered) widget.onReply();
    _triggered = false;
    _start = null;
    if (_offset != 0) setState(() => _offset = 0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown:   _down,
      onPointerMove:   _move,
      onPointerUp:     _up,
      onPointerCancel: _cancel,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Transform.translate(offset: Offset(_offset, 0), child: widget.child),
          if (_offset > 6)
            Positioned(
              left: 0, top: 0, bottom: 0,
              child: Center(
                child: Opacity(
                  opacity: (_offset / _threshold).clamp(0.0, 1.0),
                  child: const Icon(Icons.reply_rounded,
                      color: AppColors.primary, size: 22),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Full-screen image/video viewers now live in ../widgets/media_viewers.dart
// (shared with group chat), where saving reuses the local cache and shows a
// "saved" indicator.
