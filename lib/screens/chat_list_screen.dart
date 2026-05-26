import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../services/chat_service.dart';
import '../services/status_service.dart';
import '../models/user_profile_model.dart';
import '../models/status_model.dart';
import '../constants/app_theme.dart';
import '../utils/snack_util.dart';
import 'chat_detail_screen.dart';
import 'status_screen.dart';
import 'status_viewer_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final ChatService _chatService = ChatService();
  final StatusService _statusService = StatusService();
  bool _checkingProfile = true;
  String? _currentUserName;
  String? _currentUserPhotoUrl;
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    ChatListTracker.isActive = true;
    _loadProfile();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppProvider>().showPendingCallIfRinging();
    });
  }

  @override
  void dispose() {
    ChatListTracker.isActive = false;
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final provider = context.read<AppProvider>();
      // Profile is already loaded by AppProvider.initialize() — just read it
      final profile = provider.profile;
      if (!mounted) return;
      setState(() {
        _currentUserName = profile?.name;
        _currentUserPhotoUrl = profile?.photoUrl;
        _checkingProfile = false;
      });
      unawaited(_chatService.updateOnReturn(provider.chatUserId));
    } catch (_) {
    } finally {
      if (mounted && _checkingProfile) {
        setState(() => _checkingProfile = false);
      }
    }
  }

  static const _triggerKey = 'chat_trigger_word';

  Future<void> _changeTriggerWord() async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getString(_triggerKey) ?? 'sandy';
    final ctrl = TextEditingController(text: current);
    if (!mounted) return;
    final newWord = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Chat shortcut keyword'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. sandy',
            helperText: 'Type this word in expense description (no amount) to open chat',
          ),
          textCapitalization: TextCapitalization.none,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().toLowerCase()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newWord != null && newWord.isNotEmpty) {
      await prefs.setString(_triggerKey, newWord);
      if (mounted) context.showSuccess('Keyword updated to "$newWord"');
    }
  }

  Future<void> _pickProfilePhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null || !mounted) return;
    final uid = context.read<AppProvider>().chatUserId;
    setState(() => _uploadingPhoto = true);
    try {
      final url = await _chatService.uploadProfilePhoto(uid, File(file.path));
      await _chatService.updatePhotoUrl(uid, url);
      if (mounted) {
        setState(() => _currentUserPhotoUrl = url);
        context.showSuccess('Profile photo updated');
      }
    } catch (_) {
      if (mounted) context.showError('Failed to upload photo');
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.read<AppProvider>().chatUserId;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          IconButton(
            icon: const Icon(Icons.circle_outlined, color: Colors.white),
            tooltip: 'Status',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StatusScreen()),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (v) {
              if (v == 'trigger') _changeTriggerWord();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'trigger',
                child: Row(
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Chat shortcut keyword'),
                  ],
                ),
              ),
            ],
          ),
          if (_currentUserName != null)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: GestureDetector(
                onTap: _uploadingPhoto ? null : _pickProfilePhoto,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white.withValues(alpha: 0.25),
                      backgroundImage: _currentUserPhotoUrl != null
                          ? CachedNetworkImageProvider(_currentUserPhotoUrl!)
                          : null,
                      child: _currentUserPhotoUrl == null
                          ? Text(
                              _currentUserName![0].toUpperCase(),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14),
                            )
                          : null,
                    ),
                    if (_uploadingPhoto)
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    else
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: const Icon(Icons.camera_alt_rounded,
                              size: 8, color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: _checkingProfile
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<List<StatusModel>>(
              stream: _statusService.allActiveStatuses(),
              builder: (ctx, statusSnap) {
                final allStatuses = statusSnap.data ?? [];
                return StreamBuilder<List<UserProfileModel>>(
                  stream: _chatService.getAllUsersExcept(uid),
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final users = snap.data ?? [];
                    if (users.isEmpty) return _buildEmpty();

                    // Build status groups so we can look up rings per user
                    final statusGroups = StatusService.groupByUser(
                      statuses: allStatuses,
                      users: users,
                      currentUid: uid,
                    );
                    final groupMap = {
                      for (final g in statusGroups) g.uid: g
                    };

                    return ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: users.length,
                      itemBuilder: (ctx, i) => _UserTile(
                        user: users[i],
                        currentUid: uid,
                        chatService: _chatService,
                        statusGroup: groupMap[users[i].uid],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline_rounded, size: 64,
                color: AppColors.textSecondary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text('No other users yet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            Text(
              'When others open the app and set their name, they\'ll appear here.',
              style: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.7),
                  fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── User Tile ─────────────────────────────────────────────────────────────────

class _UserTile extends StatefulWidget {
  final UserProfileModel user;
  final String currentUid;
  final ChatService chatService;
  final UserStatuses? statusGroup;

  const _UserTile({
    required this.user,
    required this.currentUid,
    required this.chatService,
    this.statusGroup,
  });

  @override
  State<_UserTile> createState() => _UserTileState();
}

class _UserTileState extends State<_UserTile> {
  // Streams are created once in initState so StreamBuilder never recreates
  // them on parent rebuilds. Without this, every Firestore event causes the
  // parent to rebuild, which passes new Stream instances to StreamBuilder,
  // which briefly resets to null data — causing the tile to go blank.
  late Stream<UserProfileModel?> _profileStream;
  late Stream<Map<String, dynamic>?> _chatStream;

  @override
  void initState() {
    super.initState();
    _profileStream = widget.chatService.watchUserProfile(widget.user.uid);
    _chatStream = widget.chatService.chatData(widget.currentUid, widget.user.uid);
  }

  static void _openFullScreenPhoto(BuildContext context, String url) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: url,
                placeholder: (_, __) =>
                    const Center(child: CircularProgressIndicator()),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openStatus(BuildContext context) {
    final group = widget.statusGroup;
    if (group == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatusViewerScreen(
          groups: [group],
          initialGroupIndex: 0,
          currentUid: widget.currentUid,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserProfileModel?>(
      stream: _profileStream,
      initialData: widget.user,
      builder: (ctx, profileSnap) {
        final profile = profileSnap.data ?? widget.user;
        final isOnline = DateTime.now().difference(profile.lastSeen).inMinutes < 2;

        return StreamBuilder<Map<String, dynamic>?>(
          stream: _chatStream,
          builder: (ctx, snap) {
            final data = snap.data;
            final lastMsg = data?['lastMessage'] as String? ?? '';
            final lastTime = data?['lastMessageTime'];
            final lastSenderId = data?['lastSenderId'] as String? ?? '';
            final unread = (data?['unread_${widget.currentUid}'] as int?) ?? 0;
            final isMine = lastSenderId == widget.currentUid;

            String timeStr = '';
            if (lastTime != null) {
              final dt = (lastTime as Timestamp).toDate();
              final now = DateTime.now();
              timeStr = (dt.year == now.year && dt.month == now.month && dt.day == now.day)
                  ? DateFormat('HH:mm').format(dt)
                  : DateFormat('d MMM').format(dt);
            }

            String? msgPreview = lastMsg.isEmpty
                ? null
                : isMine
                    ? 'You: $lastMsg'
                    : lastMsg;

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: GestureDetector(
                  onTap: widget.statusGroup != null
                      ? () => _openStatus(context)
                      : profile.photoUrl != null
                          ? () => _openFullScreenPhoto(context, profile.photoUrl!)
                          : null,
                  child: _StatusRingWrapper(
                    hasStatus: widget.statusGroup != null,
                    allViewed: widget.statusGroup?.allViewedBy(widget.currentUid) ?? false,
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: AppColors.primary,
                          backgroundImage: profile.photoUrl != null
                              ? CachedNetworkImageProvider(profile.photoUrl!)
                              : null,
                          child: profile.photoUrl == null
                              ? Text(
                                  profile.name.isNotEmpty ? profile.name[0].toUpperCase() : '?',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold),
                                )
                              : null,
                        ),
                        if (isOnline)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: const Color(0xFF4CAF50),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                title: Text(
                  profile.name,
                  style: TextStyle(
                      fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600,
                      color: AppColors.textPrimary),
                ),
                subtitle: msgPreview != null
                    ? Text(
                        msgPreview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: unread > 0
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                            fontWeight:
                                unread > 0 ? FontWeight.w600 : FontWeight.normal),
                      )
                    : const Text('Tap to start chatting',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                            fontStyle: FontStyle.italic)),
                trailing: SizedBox(
                  width: 60,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (timeStr.isNotEmpty)
                        Text(
                          timeStr,
                          style: TextStyle(
                              fontSize: 11,
                              color: unread > 0
                                  ? const Color(0xFF25D366)
                                  : AppColors.textSecondary,
                              fontWeight: unread > 0
                                  ? FontWeight.w600
                                  : FontWeight.normal),
                        ),
                      if (unread > 0) ...[
                        if (timeStr.isNotEmpty) const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Color(0xFF25D366),
                            shape: BoxShape.circle,
                          ),
                          constraints:
                              const BoxConstraints(minWidth: 20, minHeight: 20),
                          child: Center(
                            child: Text(
                              unread > 99 ? '99+' : '$unread',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatDetailScreen(
                      currentUid: widget.currentUid,
                      otherUser: profile,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ── Status ring wrapper ────────────────────────────────────────────────────────

class _StatusRingWrapper extends StatelessWidget {
  final bool hasStatus;
  final bool allViewed;
  final Widget child;

  const _StatusRingWrapper({
    required this.hasStatus,
    required this.allViewed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasStatus) return child;
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: allViewed
            ? null
            : const LinearGradient(
                colors: [Color(0xFF833AB4), Color(0xFFFD1D1D), Color(0xFFF77737)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        color: allViewed ? Colors.grey.shade400 : null,
      ),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: child,
      ),
    );
  }
}
