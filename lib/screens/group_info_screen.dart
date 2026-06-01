import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../constants/app_theme.dart';
import '../models/group_model.dart';
import '../models/user_profile_model.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../utils/snack_util.dart';
import 'profile_photo_crop_screen.dart';

class GroupInfoScreen extends StatefulWidget {
  final GroupModel group;
  final String currentUid;

  const GroupInfoScreen({
    super.key,
    required this.group,
    required this.currentUid,
  });

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  final GroupChatService _groupService = GroupChatService();
  final ChatService _chatService = ChatService();

  late GroupModel _group;
  Map<String, UserProfileModel> _profileCache = {};
  bool _loadingProfiles = true;
  bool _uploadingIcon = false;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _loadProfiles();
    // Keep group live
    _groupService.watchGroup(widget.group.id).listen((g) {
      if (mounted && g != null) {
        setState(() => _group = g);
        _loadProfiles();
      }
    });
  }

  Future<void> _loadProfiles() async {
    final profiles = <String, UserProfileModel>{};
    for (final uid in _group.participants) {
      final profile = await _chatService.getUserProfile(uid);
      if (profile != null) profiles[uid] = profile;
    }
    if (mounted) setState(() { _profileCache = profiles; _loadingProfiles = false; });
  }

  bool get _iAmAdmin => _group.isAdmin(widget.currentUid);

  // ── Rename ────────────────────────────────────────────────────────────────

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _group.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Rename group'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != _group.name) {
      await _groupService.updateGroupName(_group.id, newName);
      if (mounted) context.showSuccess('Group renamed');
    }
  }

  // ── Icon ──────────────────────────────────────────────────────────────────

  Future<void> _changeIcon() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 95);
    if (picked == null || !mounted) return;

    final cropped = await ProfilePhotoCropScreen.push(context, File(picked.path));
    if (cropped == null || !mounted) return;

    setState(() => _uploadingIcon = true);
    try {
      await _groupService.uploadGroupIcon(_group.id, cropped);
      if (mounted) context.showSuccess('Group icon updated');
    } catch (_) {
      if (mounted) context.showError('Failed to update icon');
    } finally {
      if (mounted) setState(() => _uploadingIcon = false);
    }
  }

  // ── Add member ────────────────────────────────────────────────────────────

  Future<void> _addMember() async {
    final currentUid = widget.currentUid;
    final allUsers = await _chatService.getAllUsersExcept(currentUid).first;
    final eligible = allUsers.where((u) => !_group.participants.contains(u.uid)).toList();

    if (!mounted) return;
    if (eligible.isEmpty) {
      context.showError('No other users to add');
      return;
    }

    final picked = await showDialog<UserProfileModel>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Add member'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: eligible.length,
            itemBuilder: (ctx, i) {
              final u = eligible[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary,
                  backgroundImage: u.photoUrl != null
                      ? CachedNetworkImageProvider(u.photoUrl!) : null,
                  child: u.photoUrl == null
                      ? Text(u.name[0].toUpperCase(),
                          style: const TextStyle(color: Colors.white)) : null,
                ),
                title: Text(u.name),
                onTap: () => Navigator.pop(ctx, u),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );

    if (picked != null) {
      await _groupService.addMember(_group.id, picked.uid);
      if (mounted) context.showSuccess('${picked.name} added');
    }
  }

  // ── Remove / promote ──────────────────────────────────────────────────────

  Future<void> _showMemberOptions(String uid) async {
    if (uid == widget.currentUid) return; // handled separately via Leave
    final profile = _profileCache[uid];
    final name = profile?.name ?? uid;
    final isAdmin = _group.isAdmin(uid);

    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
                color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(name,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
          if (!isAdmin)
            ListTile(
              leading: const Icon(Icons.star_rounded, color: Colors.amber),
              title: const Text('Make admin'),
              onTap: () => Navigator.pop(ctx, 'admin'),
            ),
          if (isAdmin)
            ListTile(
              leading: const Icon(Icons.star_border_rounded),
              title: const Text('Remove admin'),
              onTap: () => Navigator.pop(ctx, 'unadmin'),
            ),
          ListTile(
            leading: const Icon(Icons.remove_circle_outline_rounded, color: Colors.red),
            title: Text('Remove $name', style: const TextStyle(color: Colors.red)),
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
        ]),
      ),
    );

    if (action == 'admin') {
      await _groupService.makeAdmin(_group.id, uid);
      if (mounted) context.showSuccess('$name is now an admin');
    } else if (action == 'unadmin') {
      await _groupService.removeAdmin(_group.id, uid);
    } else if (action == 'remove') {
      await _groupService.removeMember(_group.id, uid);
      if (mounted) context.showSuccess('$name removed from group');
    }
  }

  // ── Leave ─────────────────────────────────────────────────────────────────

  Future<void> _leaveGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave group?'),
        content: const Text('You will no longer receive messages from this group.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _groupService.leaveGroup(_group.id, widget.currentUid);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Group Info')),
      body: ListView(
        children: [
          // ── Icon + name header ──────────────────────────────────────────
          Container(
            color: AppColors.primary.withValues(alpha: 0.06),
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(children: [
              GestureDetector(
                onTap: _iAmAdmin ? _changeIcon : null,
                child: Stack(alignment: Alignment.center, children: [
                  CircleAvatar(
                    radius: 44,
                    backgroundColor: AppColors.primary.withValues(alpha: 0.2),
                    backgroundImage: _group.iconUrl != null
                        ? CachedNetworkImageProvider(_group.iconUrl!) : null,
                    child: _group.iconUrl == null
                        ? const Icon(Icons.group_rounded, color: AppColors.primary, size: 44)
                        : null,
                  ),
                  if (_uploadingIcon)
                    const CircularProgressIndicator(),
                  if (_iAmAdmin && !_uploadingIcon)
                    Positioned(
                      bottom: 0, right: 0,
                      child: Container(
                        width: 26, height: 26,
                        decoration: const BoxDecoration(
                            color: AppColors.primary, shape: BoxShape.circle),
                        child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 14),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(_group.name,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                if (_iAmAdmin) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _rename,
                    child: const Icon(Icons.edit_rounded, size: 18, color: AppColors.primary),
                  ),
                ],
              ]),
              const SizedBox(height: 4),
              Text('${_group.participants.length} members',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ]),
          ),

          const SizedBox(height: 12),

          // ── Members section ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Text('MEMBERS',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary, letterSpacing: 1)),
              const Spacer(),
              if (_iAmAdmin)
                TextButton.icon(
                  onPressed: _addMember,
                  icon: const Icon(Icons.person_add_rounded, size: 16),
                  label: const Text('Add', style: TextStyle(fontSize: 13)),
                ),
            ]),
          ),

          if (_loadingProfiles)
            const Center(child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ))
          else
            ..._group.participants.map((uid) {
              final profile = _profileCache[uid];
              final name = profile?.name ?? uid;
              final isAdmin = _group.isAdmin(uid);
              final isMe = uid == widget.currentUid;

              return ListTile(
                leading: CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.primary,
                  backgroundImage: profile?.photoUrl != null
                      ? CachedNetworkImageProvider(profile!.photoUrl!) : null,
                  child: profile?.photoUrl == null
                      ? Text(name[0].toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                      : null,
                ),
                title: Row(children: [
                  Text(isMe ? 'You' : name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (isAdmin) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          borderRadius: BorderRadius.circular(8)),
                      child: const Text('Admin',
                          style: TextStyle(fontSize: 10, color: Colors.amber,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ]),
                subtitle: isMe ? null : Text(name,
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                trailing: _iAmAdmin && !isMe
                    ? IconButton(
                        icon: const Icon(Icons.more_vert_rounded, size: 18),
                        onPressed: () => _showMemberOptions(uid),
                      )
                    : null,
                onTap: _iAmAdmin && !isMe ? () => _showMemberOptions(uid) : null,
              );
            }),

          const Divider(height: 32),

          // ── Leave group ─────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.exit_to_app_rounded, color: Colors.red),
            title: const Text('Leave group',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
            onTap: _leaveGroup,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
