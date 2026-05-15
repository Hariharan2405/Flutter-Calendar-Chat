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
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final provider = context.read<AppProvider>();
      final uid = provider.userId;
      if (uid == null) return; // auth not ready yet, should not happen

      final profile = provider.profile ?? await _chatService.getUserProfile(uid);
      if (!mounted) return;

      if (profile == null || profile.description == null) {
        await _showDescriptionDialog(uid);
      } else {
        setState(() {
          _currentUserName = profile.description!;
          _checkingProfile = false;
        });
        unawaited(_chatService.updateOnReturn(uid));
      }
    } catch (_) {
      // swallow — the finally block always clears the spinner
    } finally {
      if (mounted && _checkingProfile) {
        setState(() => _checkingProfile = false);
      }
    }
  }

  Future<void> _showDescriptionDialog(String uid) async {
    final ctrl = TextEditingController();
    String? error;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.waving_hand_rounded, color: AppColors.accent, size: 28),
                    SizedBox(width: 10),
                    Text(
                      'Chat Display Name',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'What should others see when you chat? This is set once.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'E.g. Harry',
                    prefixIcon: Icon(Icons.chat_bubble_rounded),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () async {
                    final desc = ctrl.text.trim();
                    if (desc.isEmpty) {
                      setLocal(() => error = 'Please enter a description.');
                      return;
                    }
                    try {
                      await _chatService.setDescription(uid, desc);
                    } catch (e) {
                      setLocal(() => error = 'Failed to save. Please try again.');
                      return;
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      setState(() {
                        _currentUserName = desc;
                        _checkingProfile = false;
                      });
                    }
                  },
                  child: const Text('Start Chatting', style: TextStyle(fontSize: 15)),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (mounted && _checkingProfile) {
      setState(() => _checkingProfile = false);
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
                    (user.description ?? user.name).isNotEmpty
                        ? (user.description ?? user.name)[0].toUpperCase()
                        : '?',
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
              user.description ?? user.name,
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
