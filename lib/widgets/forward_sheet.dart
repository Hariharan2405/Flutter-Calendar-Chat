import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../models/group_model.dart';
import '../models/user_profile_model.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../utils/image_sizing.dart';

/// Where a forwarded message is going: either a person or a group.
class ForwardTarget {
  final UserProfileModel? user;
  final GroupModel? group;

  const ForwardTarget.person(this.user) : group = null;
  const ForwardTarget.toGroup(this.group) : user = null;

  bool get isGroup => group != null;
  String get label => group?.name ?? user?.name ?? '';
}

/// Picker for forwarding. Returns the chosen target, or null if dismissed.
///
/// Single-select on purpose: multi-select forwarding invites accidental
/// broadcast, and the sheet can simply be reopened to send somewhere else.
Future<ForwardTarget?> showForwardSheet(
  BuildContext context, {
  required String currentUid,
}) {
  return showModalBottomSheet<ForwardTarget>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _ForwardSheet(currentUid: currentUid),
  );
}

class _ForwardSheet extends StatefulWidget {
  final String currentUid;
  const _ForwardSheet({required this.currentUid});

  @override
  State<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<_ForwardSheet> {
  final _chatService = ChatService();
  final _groupService = GroupChatService();
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(
        () => setState(() => _query = _searchCtrl.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Column(
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
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Forward to',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search people and groups',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: AppColors.background,
                contentPadding: const EdgeInsets.symmetric(vertical: 2),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<GroupModel>>(
              stream: _groupService.getAllGroupsFor(widget.currentUid),
              builder: (ctx, groupSnap) {
                final groups = (groupSnap.data ?? [])
                    .where((g) =>
                        _query.isEmpty || g.name.toLowerCase().contains(_query))
                    .toList();

                return StreamBuilder<List<UserProfileModel>>(
                  stream: _chatService.getAllUsersExcept(widget.currentUid),
                  builder: (ctx, userSnap) {
                    if (userSnap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final users = (userSnap.data ?? [])
                        .where((u) =>
                            _query.isEmpty ||
                            u.name.toLowerCase().contains(_query))
                        .toList();

                    if (groups.isEmpty && users.isEmpty) {
                      return const Center(
                        child: Text('No matches',
                            style: TextStyle(color: AppColors.textSecondary)),
                      );
                    }

                    return ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        if (groups.isNotEmpty) ...[
                          const _SectionLabel('GROUPS'),
                          ...groups.map((g) => ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: AppColors.primary,
                                  backgroundImage: g.iconUrl != null
                                      ? avatarImage(g.iconUrl!, radius: 20)
                                      : null,
                                  child: g.iconUrl == null
                                      ? const Icon(Icons.group_rounded,
                                          color: Colors.white, size: 20)
                                      : null,
                                ),
                                title: Text(g.name),
                                subtitle: Text(
                                    '${g.participants.length} members',
                                    style: const TextStyle(fontSize: 12)),
                                onTap: () => Navigator.pop(
                                    context, ForwardTarget.toGroup(g)),
                              )),
                        ],
                        if (users.isNotEmpty) ...[
                          const _SectionLabel('PEOPLE'),
                          ...users.map((u) => ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: AppColors.primary,
                                  backgroundImage: u.photoUrl != null
                                      ? avatarImage(u.photoUrl!, radius: 20)
                                      : null,
                                  child: u.photoUrl == null
                                      ? Text(
                                          u.name.isNotEmpty
                                              ? u.name[0].toUpperCase()
                                              : '?',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold),
                                        )
                                      : null,
                                ),
                                title: Text(u.name),
                                onTap: () => Navigator.pop(
                                    context, ForwardTarget.person(u)),
                              )),
                        ],
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: 1,
          ),
        ),
      );
}
