import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../services/chat_service.dart';
import '../models/user_profile_model.dart';
import '../constants/app_theme.dart';
import 'chat_detail_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final ChatService _chatService = ChatService();
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
      final uid = provider.userId;
      if (uid == null) return;

      final profile = await _chatService.getUserProfile(uid);
      if (!mounted) return;

      setState(() {
        _currentUserName = profile?.name;
        _currentUserPhotoUrl = profile?.photoUrl;
        _checkingProfile = false;
      });
      unawaited(_chatService.updateOnReturn(uid));
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
    }
  }

  Future<void> _pickProfilePhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null || !mounted) return;
    final uid = context.read<AppProvider>().userId!;
    setState(() => _uploadingPhoto = true);
    try {
      final url = await _chatService.uploadProfilePhoto(uid, File(file.path));
      await _chatService.updatePhotoUrl(uid, url);
      if (mounted) setState(() => _currentUserPhotoUrl = url);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to upload photo')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.read<AppProvider>().userId!;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
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
          : StreamBuilder<List<UserProfileModel>>(
              stream: _chatService.getAllUsersExcept(uid),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final users = snap.data ?? [];
                if (users.isEmpty) return _buildEmpty();
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: users.length,
                  itemBuilder: (ctx, i) => _UserTile(
                    user: users[i],
                    currentUid: uid,
                    chatService: _chatService,
                  ),
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

class _UserTile extends StatelessWidget {
  final UserProfileModel user;
  final String currentUid;
  final ChatService chatService;

  const _UserTile({
    required this.user,
    required this.currentUid,
    required this.chatService,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>?>(
      stream: chatService.chatData(currentUid, user.uid),
      builder: (ctx, snap) {
        final data = snap.data;
        final lastMsg = data?['lastMessage'] as String? ?? '';
        final lastTime = data?['lastMessageTime'];
        final unread = (data?['unread_$currentUid'] as int?) ?? 0;

        String timeStr = '';
        if (lastTime != null) {
          final dt = lastTime.toDate() as DateTime;
          final now = DateTime.now();
          timeStr = (dt.year == now.year && dt.month == now.month && dt.day == now.day)
              ? DateFormat('HH:mm').format(dt)
              : DateFormat('d MMM').format(dt);
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: Stack(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AppColors.primary,
                  backgroundImage: user.photoUrl != null
                      ? CachedNetworkImageProvider(user.photoUrl!)
                      : null,
                  child: user.photoUrl == null
                      ? Text(
                          user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                          style: const TextStyle(color: Colors.white,
                              fontSize: 18, fontWeight: FontWeight.bold),
                        )
                      : null,
                ),
                if (unread > 0)
                  Positioned(
                    right: 0, top: 0,
                    child: Container(
                      width: 18, height: 18,
                      decoration: const BoxDecoration(
                          color: AppColors.holiday, shape: BoxShape.circle),
                      child: Center(
                        child: Text('$unread',
                            style: const TextStyle(color: Colors.white,
                                fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
              ],
            ),
            title: Text(
              user.name,
              style: TextStyle(
                  fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600,
                  color: AppColors.textPrimary),
            ),
            subtitle: lastMsg.isNotEmpty
                ? Text(lastMsg,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: unread > 0
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal))
                : const Text('Tap to start chatting',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary,
                        fontStyle: FontStyle.italic)),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (timeStr.isNotEmpty)
                  Text(timeStr,
                      style: TextStyle(
                          fontSize: 11,
                          color: unread > 0 ? AppColors.holiday : AppColors.textSecondary,
                          fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal)),
                const SizedBox(height: 4),
                const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary, size: 18),
              ],
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatDetailScreen(
                  currentUid: currentUid,
                  otherUser: user,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
