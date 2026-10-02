import 'dart:math' as math;
import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/group_model.dart';
import '../providers/app_provider.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../services/status_service.dart';
import '../services/media_prefetcher.dart';
import '../models/user_profile_model.dart';
import '../models/status_model.dart';
import '../constants/app_theme.dart';
import '../utils/snack_util.dart';
import '../services/system_services.dart';
import 'chat_detail_screen.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';
import 'profile_photo_crop_screen.dart';
import 'status_screen.dart';
import '../utils/responsive.dart';
import 'status_viewer_screen.dart';
import '../widgets/media_viewers.dart';
import '../widgets/chat_ui.dart';
import 'settings_screen.dart';
import '../utils/image_sizing.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final ChatService _chatService = ChatService();
  final GroupChatService _groupService = GroupChatService();
  final StatusService _statusService = StatusService();
  bool _checkingProfile = true;
  String? _currentUserName;
  String? _currentUserPhotoUrl;
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    ChatListTracker.isActive = true;
    // User entered the chat list — dismiss any lingering banner immediately.
    AppProvider.dismissBanner?.call();
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
            helperText:
                'Type this word in expense description (no amount) to open chat',
          ),
          textCapitalization: TextCapitalization.none,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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

  Future<void> _pickNotifSound() async {
    final provider = context.read<AppProvider>();
    try {
      // null return = user cancelled the picker (pressed back)
      final uri = await SystemServices.pickNotificationSound(
          currentUri: provider.notifSoundUri);
      if (!mounted) return;
      await provider.setNotifSound(uri);
      // Play a brief preview so the user hears the selected sound immediately
      if (uri != '') SystemServices.playNotificationSound(uri).ignore();
      final label = uri == null
          ? 'Default'
          : uri == ''
              ? 'Silent'
              : 'Custom sound';
      context.showSuccess('Notification sound: $label');
    } catch (_) {
      // User pressed back without selecting — no-op
    }
  }

  /// Tapping your own avatar has two reasonable meanings once a photo is set,
  /// so ask instead of guessing — viewing was previously unreachable.
  Future<void> _onOwnAvatarTap() async {
    final url = _currentUserPhotoUrl;
    if (url == null) {
      await _pickProfilePhoto();
      return;
    }
    final view = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.person_rounded, color: AppColors.primary),
              title: const Text('View photo'),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded,
                  color: AppColors.primary),
              title: const Text('Change photo'),
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (view == null || !mounted) return;
    if (view) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => FullScreenImageViewer(url: url)),
      );
    } else {
      await _pickProfilePhoto();
    }
  }

  Future<void> _pickProfilePhoto() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 95);
    if (picked == null || !mounted) return;

    // Let the user position and zoom before uploading
    final cropped =
        await ProfilePhotoCropScreen.push(context, File(picked.path));
    if (cropped == null || !mounted) return;

    final uid = context.read<AppProvider>().chatUserId;
    setState(() => _uploadingPhoto = true);
    try {
      // Both steps are bounded. A Firestore write only completes once the
      // server acknowledges it, and a stalled upload never completes at all,
      // so without a deadline the spinner could run forever with nothing to
      // tell the user what went wrong.
      final url = await _chatService
          .uploadProfilePhoto(uid, cropped)
          .timeout(const Duration(seconds: 60));
      await _chatService
          .updatePhotoUrl(uid, url)
          .timeout(const Duration(seconds: 20));
      if (mounted) {
        context.read<AppProvider>().updateProfilePhoto(url);
        setState(() => _currentUserPhotoUrl = url);
        context.showSuccess('Profile photo updated');
      }
    } on TimeoutException {
      if (mounted) {
        context.showError('Upload timed out — check your connection');
      }
    } catch (e) {
      if (mounted) {
        final denied = e.toString().contains('permission-denied');
        context.showError(denied
            ? 'Not allowed to update the photo — deploy the Firestore rules'
            : 'Failed to upload photo');
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  // ── Tablet split view ──────────────────────────────────────────────────────

  /// The chat open beside the list on a tablet, and which one it is.
  Widget? _pane;
  String? _paneId;

  /// Side by side only on a real tablet with room for both; phones, even in
  /// landscape, keep opening chats as their own page.
  bool _splitView(BuildContext context) =>
      context.isTablet && MediaQuery.sizeOf(context).width >= 720;

  void _openInPane(String id, Widget chat) {
    if (_paneId == id) return;
    setState(() {
      _paneId = id;
      _pane = KeyedSubtree(key: ValueKey(id), child: chat);
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = _buildListScaffold(context);
    if (!_splitView(context)) return list;
    final listWidth =
        (MediaQuery.sizeOf(context).width * 0.38).clamp(320.0, 420.0);
    return Material(
      color: Colors.white,
      child: Row(
        children: [
          SizedBox(
            width: listWidth,
            child: ChatPaneScope(
              selectedId: _paneId,
              open: _openInPane,
              child: list,
            ),
          ),
          const VerticalDivider(
              width: 1, thickness: 1, color: Color(0xFFE7E3F3)),
          Expanded(child: _pane ?? const _EmptyPane()),
        ],
      ),
    );
  }

  Widget _buildListScaffold(BuildContext context) {
    final uid = context.read<AppProvider>().chatUserId;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const ChatHeaderBackground(),
        centerTitle: false,
        titleSpacing: 20,
        title: const Text(
          'Messages',
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome_motion_rounded,
                color: Colors.white),
            tooltip: 'Status',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StatusScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_rounded, color: Colors.white),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  onEditPhoto: _onOwnAvatarTap,
                  onChangeShortcutKeyword: _changeTriggerWord,
                  onPickNotificationSound: _pickNotifSound,
                ),
              ),
            ),
          ),
          if (_currentUserName != null)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: GestureDetector(
                onTap: _uploadingPhoto ? null : _onOwnAvatarTap,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white.withValues(alpha: 0.25),
                      backgroundImage: _currentUserPhotoUrl != null
                          ? avatarImage(_currentUserPhotoUrl!, radius: 18)
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
      floatingActionButton: DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: ChatStyle.outgoing,
          boxShadow: [
            BoxShadow(
                color: Color(0x555B30DC), blurRadius: 18, offset: Offset(0, 8)),
          ],
        ),
        child: FloatingActionButton(
          backgroundColor: Colors.transparent,
          elevation: 0,
          highlightElevation: 0,
          tooltip: 'New group',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
          ),
          child: const Icon(Icons.group_add_rounded, color: Colors.white),
        ),
      ),
      body: SizedBox(
        width: double.infinity,
        child: _checkingProfile
            ? const Center(child: CircularProgressIndicator())
            : StreamBuilder<List<StatusModel>>(
                stream: _statusService.allActiveStatuses(),
                builder: (ctx, statusSnap) {
                  final allStatuses = statusSnap.data ?? [];
                  // Prefetch status media into the local cache so opening a
                  // status shows instantly instead of waiting on the network.
                  MediaPrefetcher.prefetch(allStatuses.map((s) => s.mediaUrl));
                  return StreamBuilder<List<UserProfileModel>>(
                    stream: _chatService.getAllUsersExcept(uid),
                    builder: (ctx, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final users = snap.data ?? [];

                      final statusGroups = StatusService.groupByUser(
                        statuses: allStatuses,
                        users: users,
                        currentUid: uid,
                      );
                      final groupMap = {for (final g in statusGroups) g.uid: g};

                      return StreamBuilder<QuerySnapshot>(
                        // One query for every conversation this user is in.
                        // Previously each row opened its own chat listener, so a
                        // list of N people held N listeners; this holds one.
                        stream: _chatService.allChatsFor(uid),
                        builder: (ctx, chatsSnap) {
                          final chatMap = <String, Map<String, dynamic>>{
                            for (final d in chatsSnap.data?.docs ?? [])
                              d.id: d.data() as Map<String, dynamic>,
                          };
                          return _buildList(
                            uid: uid,
                            users: users,
                            groupMap: groupMap,
                            chatMap: chatMap,
                            stories: statusGroups
                                .where((g) => g.uid != uid)
                                .toList(),
                          );
                        },
                      );
                    },
                  );
                },
              ),
      ),
    );
  }

  Widget _buildList({
    required String uid,
    required List<UserProfileModel> users,
    required Map<String, UserStatuses> groupMap,
    required Map<String, Map<String, dynamic>> chatMap,
    required List<UserStatuses> stories,
  }) {
    // Rows cap at a readable width and centre on a wide screen.
    final side = math.max(0.0, (MediaQuery.sizeOf(context).width - 840) / 2);
    return CustomScrollView(
      slivers: [
        // ── Status row, on the header gradient ─────────────────────────
        SliverToBoxAdapter(
          child: _StoriesBand(
            stories: stories,
            currentUid: uid,
            myName: _currentUserName ?? '',
            myPhotoUrl: _currentUserPhotoUrl,
            sidePadding: side,
          ),
        ),
        // ── Groups ─────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: StreamBuilder<List<GroupModel>>(
            stream: _groupService.getAllGroupsFor(uid),
            builder: (ctx, groupSnap) {
              final groups = groupSnap.data ?? [];
              if (groups.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: side),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionLabel('Groups'),
                    ...groups.map((g) => _GroupTile(group: g, currentUid: uid)),
                    const _SectionLabel('Chats'),
                  ],
                ),
              );
            },
          ),
        ),
        // ── People ─────────────────────────────────────────────────────
        if (users.isEmpty)
          SliverFillRemaining(hasScrollBody: false, child: _buildEmpty())
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 0, side, 96),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _UserTile(
                  user: users[i],
                  currentUid: uid,
                  statusGroup: groupMap[users[i].uid],
                  chatData: chatMap[ChatService.chatId(uid, users[i].uid)],
                ),
                childCount: users.length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline_rounded,
                size: 64,
                color: AppColors.textSecondary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text('No other users yet',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            Text(
              'When others open the app and set their name, they\'ll appear here.',
              style: TextStyle(
                  color: AppColors.textSecondary.withValues(alpha: 0.7),
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

/// A single person's row. Both the profile and the chat metadata arrive as
/// plain values from the parent's two collection streams — the tile opens no
/// listeners of its own, so the screen holds a fixed number regardless of how
/// many people are listed.
class _UserTile extends StatelessWidget {
  final UserProfileModel user;
  final String currentUid;
  final UserStatuses? statusGroup;
  final Map<String, dynamic>? chatData;

  const _UserTile({
    required this.user,
    required this.currentUid,
    this.statusGroup,
    this.chatData,
  });

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
    final group = statusGroup;
    if (group == null) return;
    final provider = context.read<AppProvider>();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatusViewerScreen(
          groups: [group],
          initialGroupIndex: 0,
          currentUid: currentUid,
          currentUserName: provider.profile?.name ?? '',
          chatService: ChatService(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = user;
    final isOnline =
        DateTime.now().difference(profile.lastSeen) < kOnlineWindow;

    final data = chatData;
    final lastMsg = data?['lastMessage'] as String? ?? '';
    final lastTime = data?['lastMessageTime'];
    final lastSenderId = data?['lastSenderId'] as String? ?? '';
    final unread = (data?['unread_$currentUid'] as int?) ?? 0;
    final isMine = lastSenderId == currentUid;

    String timeStr = '';
    if (lastTime != null) {
      final dt = (lastTime as Timestamp).toDate();
      final now = DateTime.now();
      timeStr =
          (dt.year == now.year && dt.month == now.month && dt.day == now.day)
              ? DateFormat('h:mm a').format(dt)
              : DateFormat('d MMM').format(dt);
    }

    String? msgPreview = lastMsg.isEmpty
        ? null
        : isMine
            ? 'You: $lastMsg'
            : lastMsg;

    final chatId = ChatService.chatId(currentUid, profile.uid);
    return _ChatRow(
      selected: ChatPaneScope.selectedOf(context) == chatId,
      onTap: () => ChatPaneScope.openOrPush(
        context,
        id: chatId,
        build: (embedded) => ChatDetailScreen(
          currentUid: currentUid,
          otherUser: profile,
          embedded: embedded,
        ),
      ),
      avatar: GestureDetector(
        onTap: statusGroup != null
            ? () => _openStatus(context)
            : profile.photoUrl != null
                ? () => _openFullScreenPhoto(context, profile.photoUrl!)
                : null,
        // Long-press always opens the full profile photo,
        // even when the user has a status ring.
        onLongPress: profile.photoUrl != null
            ? () => _openFullScreenPhoto(context, profile.photoUrl!)
            : null,
        child: _StatusRingWrapper(
          hasStatus: statusGroup != null,
          allViewed: statusGroup?.allViewedBy(currentUid) ?? false,
          child: _Avatar(
            photoUrl: profile.photoUrl,
            name: profile.name,
            online: isOnline,
          ),
        ),
      ),
      title: profile.name,
      subtitle: msgPreview ?? 'Tap to start chatting',
      subtitleMuted: msgPreview == null,
      time: timeStr,
      unread: unread,
    );
  }
}

// ── Group tile ────────────────────────────────────────────────────────────────

class _GroupTile extends StatelessWidget {
  final GroupModel group;
  final String currentUid;

  const _GroupTile({required this.group, required this.currentUid});

  @override
  Widget build(BuildContext context) {
    final unread = group.unreadFor(currentUid);
    final lastTime = group.lastMessageTime;
    String timeStr = '';
    if (lastTime != null) {
      final now = DateTime.now();
      timeStr = (lastTime.year == now.year &&
              lastTime.month == now.month &&
              lastTime.day == now.day)
          ? DateFormat('h:mm a').format(lastTime)
          : DateFormat('d MMM').format(lastTime);
    }

    String preview = '';
    if (group.lastMessage.isNotEmpty) {
      final isMine = group.lastSenderId == currentUid;
      final sender = isMine ? 'You' : group.lastSenderName;
      preview = sender.isNotEmpty
          ? '$sender: ${group.lastMessage}'
          : group.lastMessage;
    }

    return _ChatRow(
      selected: ChatPaneScope.selectedOf(context) == 'group:${group.id}',
      onTap: () => ChatPaneScope.openOrPush(
        context,
        id: 'group:${group.id}',
        build: (embedded) => GroupChatScreen(
          groupId: group.id,
          currentUid: currentUid,
          initialName: group.name,
          embedded: embedded,
        ),
      ),
      avatar: _Avatar(
        photoUrl: group.iconUrl,
        name: group.name,
        icon: Icons.groups_rounded,
      ),
      title: group.name,
      subtitle:
          preview.isNotEmpty ? preview : '${group.participants.length} members',
      subtitleMuted: preview.isEmpty,
      time: timeStr,
      unread: unread,
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
        gradient: allViewed ? null : ChatStyle.storyRing,
        color: allViewed ? const Color(0xFFD4D0E3) : null,
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

// ── Chat row ──────────────────────────────────────────────────────────────────

/// One conversation in the list: avatar, name, last message, time, unread.
class _ChatRow extends StatelessWidget {
  final Widget avatar;
  final String title;
  final String subtitle;
  final bool subtitleMuted;
  final String time;
  final int unread;
  final VoidCallback onTap;

  /// The chat currently open in the tablet split view.
  final bool selected;

  const _ChatRow({
    required this.avatar,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.unread,
    required this.onTap,
    this.subtitleMuted = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasUnread = unread > 0;
    return Material(
      color: selected ? const Color(0xFFF1ECFF) : Colors.white,
      child: InkWell(
        onTap: onTap,
        splashColor: ChatStyle.violet.withValues(alpha: 0.06),
        highlightColor: ChatStyle.violet.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              avatar,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight:
                                  hasUnread ? FontWeight.w800 : FontWeight.w700,
                              color: ChatStyle.ink,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                        if (time.isNotEmpty)
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  hasUnread ? FontWeight.w700 : FontWeight.w500,
                              color:
                                  hasUnread ? ChatStyle.violet : ChatStyle.mist,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 1.2,
                              fontStyle: subtitleMuted
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                              fontWeight:
                                  hasUnread ? FontWeight.w600 : FontWeight.w400,
                              color: hasUnread
                                  ? const Color(0xFF3B3756)
                                  : ChatStyle.mist,
                            ),
                          ),
                        ),
                        if (hasUnread) ...[
                          const SizedBox(width: 8),
                          _UnreadBadge(count: unread),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: ChatStyle.outgoing,
        borderRadius: BorderRadius.circular(11),
        boxShadow: const [
          BoxShadow(
              color: Color(0x405B30DC), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Avatar with an initial or icon fallback and an optional online dot.
class _Avatar extends StatelessWidget {
  final String? photoUrl;
  final String name;
  final bool online;
  final IconData? icon;
  static const double radius = 27;

  const _Avatar({
    required this.photoUrl,
    required this.name,
    this.online = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: photoUrl == null ? ChatStyle.outgoing : null,
            image: photoUrl != null
                ? DecorationImage(
                    image: avatarImage(photoUrl!, radius: radius),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          alignment: Alignment.center,
          child: photoUrl == null
              ? (icon != null
                  ? Icon(icon, color: Colors.white, size: radius * 0.95)
                  : Text(
                      initial,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: radius * 0.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ))
              : null,
        ),
        if (online)
          Positioned(
            right: 1,
            bottom: 1,
            child: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                color: ChatStyle.online,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: ChatStyle.mist,
            letterSpacing: 1.2,
          ),
        ),
      );
}

// ── Status row ────────────────────────────────────────────────────────────────

/// Your status and everyone else's, on the header gradient, with the list's
/// white sheet curving up underneath.
class _StoriesBand extends StatelessWidget {
  final List<UserStatuses> stories;
  final String currentUid;
  final String myName;
  final String? myPhotoUrl;
  final double sidePadding;

  const _StoriesBand({
    required this.stories,
    required this.currentUid,
    required this.myName,
    required this.myPhotoUrl,
    this.sidePadding = 0,
  });

  void _open(BuildContext context, int index) {
    final provider = context.read<AppProvider>();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatusViewerScreen(
          groups: stories,
          initialGroupIndex: index,
          currentUid: currentUid,
          currentUserName: provider.profile?.name ?? '',
          chatService: ChatService(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Unviewed first, so what's new is what you see.
    final ordered = [...stories]..sort((a, b) {
        final av = a.allViewedBy(currentUid) ? 1 : 0;
        final bv = b.allViewedBy(currentUid) ? 1 : 0;
        return av - bv;
      });
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: ChatStyle.header),
      child: Column(
        children: [
          SizedBox(
            height: 104,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(12 + sidePadding, 4, 12, 0),
              children: [
                _StoryBubble(
                  label: 'My status',
                  photoUrl: myPhotoUrl,
                  name: myName,
                  ring: null,
                  addBadge: true,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const StatusScreen()),
                  ),
                ),
                for (final g in ordered)
                  _StoryBubble(
                    label: g.name.split(' ').first,
                    photoUrl: g.photoUrl,
                    name: g.name,
                    ring:
                        g.allViewedBy(currentUid) ? null : ChatStyle.storyRing,
                    onTap: () => _open(context, stories.indexOf(g)),
                  ),
              ],
            ),
          ),
          // The white list sheet starts here, with rounded shoulders.
          Container(
            height: 22,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
            ),
          ),
        ],
      ),
    );
  }
}

class _StoryBubble extends StatelessWidget {
  final String label;
  final String? photoUrl;
  final String name;
  final Gradient? ring;
  final bool addBadge;
  final VoidCallback onTap;

  const _StoryBubble({
    required this.label,
    required this.photoUrl,
    required this.name,
    required this.ring,
    required this.onTap,
    this.addBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 74,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: ring,
                    color: ring == null
                        ? Colors.white.withValues(alpha: 0.35)
                        : null,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: ChatStyle.violet,
                    ),
                    child: CircleAvatar(
                      radius: 27,
                      backgroundColor: Colors.white.withValues(alpha: 0.22),
                      backgroundImage: photoUrl != null
                          ? avatarImage(photoUrl!, radius: 27)
                          : null,
                      child: photoUrl == null
                          ? Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
                if (addBadge)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: ChatStyle.storyRing,
                        border: Border.all(color: ChatStyle.violet, width: 2),
                      ),
                      child: const Icon(Icons.add_rounded,
                          color: Colors.white, size: 15),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tablet split view ─────────────────────────────────────────────────────────

/// Lets a tile open its chat beside the list on a tablet. Absent on a phone,
/// where tiles push the chat as a page as before.
class ChatPaneScope extends InheritedWidget {
  final String? selectedId;
  final void Function(String id, Widget chat) open;

  const ChatPaneScope({
    super.key,
    required this.selectedId,
    required this.open,
    required super.child,
  });

  static ChatPaneScope? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatPaneScope>();

  static String? selectedOf(BuildContext context) => _of(context)?.selectedId;

  /// Opens [id] in the pane when there is one, otherwise as a new page.
  /// [build] receives whether the chat is embedded in the pane.
  static void openOrPush(
    BuildContext context, {
    required String id,
    required Widget Function(bool embedded) build,
  }) {
    final scope = _of(context);
    if (scope != null) {
      scope.open(id, build(true));
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => build(false)));
    }
  }

  @override
  bool updateShouldNotify(ChatPaneScope old) => old.selectedId != selectedId;
}

/// The right-hand pane before any chat is chosen.
class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) {
    return ChatCanvas(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ChatStyle.outgoing,
                boxShadow: ChatStyle.floatingShadow,
              ),
              child: const Icon(Icons.forum_rounded,
                  color: Colors.white, size: 44),
            ),
            const SizedBox(height: 20),
            const Text('Your messages',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: ChatStyle.ink)),
            const SizedBox(height: 6),
            const Text('Pick a chat on the left to start talking.',
                style: TextStyle(fontSize: 14, color: ChatStyle.mist)),
          ],
        ),
      ),
    );
  }
}
