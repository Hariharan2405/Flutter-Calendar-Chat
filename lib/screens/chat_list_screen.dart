import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
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

  @override
  void initState() {
    super.initState();
    ChatListTracker.isActive = true;
    _loadProfile();
    // Check Firestore for any call that arrived before we opened this screen
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

      final profile = provider.profile ?? await _chatService.getUserProfile(uid);
      if (!mounted) return;

      setState(() {
        _currentUserName = profile?.name;
        _checkingProfile = false;
      });
      unawaited(_chatService.updateOnReturn(uid));
    } catch (_) {
      // swallow — finally always clears the spinner
    } finally {
      if (mounted && _checkingProfile) {
        setState(() => _checkingProfile = false);
      }
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
          if (_currentUserName != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('You: $_currentUserName',
                      style: const TextStyle(fontSize: 12, color: Colors.white)),
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
                  child: Text(
                    user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white, fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
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
