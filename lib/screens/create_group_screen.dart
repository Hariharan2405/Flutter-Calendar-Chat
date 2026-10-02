import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants/app_theme.dart';
import '../models/user_profile_model.dart';
import '../providers/app_provider.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../utils/snack_util.dart';
import '../utils/responsive.dart';
import 'group_chat_screen.dart';
import '../utils/image_sizing.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final ChatService _chatService = ChatService();
  final GroupChatService _groupService = GroupChatService();
  final TextEditingController _nameCtrl = TextEditingController();
  final Set<String> _selectedUids = {};
  bool _creating = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _toggle(String uid) {
    setState(() {
      if (_selectedUids.contains(uid)) {
        _selectedUids.remove(uid);
      } else {
        _selectedUids.add(uid);
      }
    });
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      context.showError('Please enter a group name');
      return;
    }
    if (_selectedUids.isEmpty) {
      context.showError('Select at least one participant');
      return;
    }
    setState(() => _creating = true);
    try {
      final provider = context.read<AppProvider>();
      final myUid = provider.chatUserId;
      final myName = provider.profile?.name ?? '';
      final groupId = await _groupService.createGroup(
        name: name,
        creatorUid: myUid,
        creatorName: myName,
        participantUids: _selectedUids.toList(),
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => GroupChatScreen(
            groupId: groupId,
            currentUid: myUid,
            initialName: name,
          ),
        ),
      );
    } catch (e) {
      if (mounted) context.showError('Failed to create group');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = context.read<AppProvider>().chatUserId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('New Group'),
        actions: [
          if (_creating)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))),
            ),
        ],
      ),
      // Centred and capped so the form doesn't stretch across a tablet screen.
      body: ContentWidth(
        maxWidth: 720,
        child: Column(
        children: [
          // ── Group name field ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Group name',
                hintText: 'e.g. Family, Work, Friends',
                prefixIcon: const Icon(Icons.group_rounded),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          // ── Selected chips ────────────────────────────────────────────────
          if (_selectedUids.isNotEmpty)
            StreamBuilder<List<UserProfileModel>>(
              stream: _chatService.getAllUsersExcept(currentUid),
              builder: (ctx, snap) {
                final selected = (snap.data ?? [])
                    .where((u) => _selectedUids.contains(u.uid))
                    .toList();
                return SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: selected.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) => Chip(
                      avatar: CircleAvatar(
                        radius: 12,
                        backgroundColor: AppColors.primary,
                        backgroundImage: selected[i].photoUrl != null
                            ? avatarImage(selected[i].photoUrl!, radius: 12)
                            : null,
                        child: selected[i].photoUrl == null
                            ? Text(selected[i].name[0].toUpperCase(),
                                style: const TextStyle(color: Colors.white, fontSize: 10))
                            : null,
                      ),
                      label: Text(selected[i].name, style: const TextStyle(fontSize: 12)),
                      deleteIcon: const Icon(Icons.close, size: 14),
                      onDeleted: () => _toggle(selected[i].uid),
                      backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                      side: BorderSide.none,
                    ),
                  ),
                );
              },
            ),
          const Divider(height: 1),
          // ── User list ─────────────────────────────────────────────────────
          Expanded(
            child: StreamBuilder<List<UserProfileModel>>(
              stream: _chatService.getAllUsersExcept(currentUid),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final users = snap.data ?? [];
                if (users.isEmpty) {
                  return const Center(
                    child: Text('No other users found',
                        style: TextStyle(color: AppColors.textSecondary)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: users.length,
                  itemBuilder: (ctx, i) {
                    final user = users[i];
                    final selected = _selectedUids.contains(user.uid);
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 22,
                        backgroundColor: AppColors.primary,
                        backgroundImage: user.photoUrl != null
                            ? avatarImage(user.photoUrl!, radius: 22)
                            : null,
                        child: user.photoUrl == null
                            ? Text(user.name[0].toUpperCase(),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                            : null,
                      ),
                      title: Text(user.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      trailing: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? AppColors.primary : Colors.transparent,
                          border: Border.all(
                            color: selected ? AppColors.primary : Colors.grey.shade400,
                            width: 2,
                          ),
                        ),
                        child: selected
                            ? const Icon(Icons.check, color: Colors.white, size: 16)
                            : null,
                      ),
                      onTap: () => _toggle(user.uid),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      ),
      floatingActionButton: _nameCtrl.text.isNotEmpty && _selectedUids.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _creating ? null : _create,
              icon: const Icon(Icons.arrow_forward_rounded),
              label: Text('Create (${_selectedUids.length + 1})'),
            )
          : null,
    );
  }
}
