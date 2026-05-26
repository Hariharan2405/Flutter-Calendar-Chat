import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../constants/app_theme.dart';
import '../models/status_model.dart';
import '../models/user_profile_model.dart';
import '../providers/app_provider.dart';
import '../services/chat_service.dart';
import '../services/status_service.dart';
import 'status_create_screen.dart';
import 'status_viewer_screen.dart';

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  final StatusService _statusService = StatusService();
  final ChatService _chatService = ChatService();

  @override
  Widget build(BuildContext context) {
    final uid = context.read<AppProvider>().chatUserId;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Status')),
      body: StreamBuilder<List<StatusModel>>(
        stream: _statusService.allActiveStatuses(),
        builder: (ctx, statusSnap) {
          if (statusSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final allStatuses = statusSnap.data ?? [];

          return StreamBuilder<List<UserProfileModel>>(
            stream: _chatService.getAllUsersStream(),
            builder: (ctx, userSnap) {
              final users = userSnap.data ?? [];
              final groups = StatusService.groupByUser(
                statuses: allStatuses,
                users: users,
                currentUid: uid,
              );

              final ownGroup = groups.where((g) => g.uid == uid).firstOrNull;
              final otherGroups = groups.where((g) => g.uid != uid).toList();
              final unviewedGroups =
                  otherGroups.where((g) => !g.allViewedBy(uid)).toList();
              final viewedGroups =
                  otherGroups.where((g) => g.allViewedBy(uid)).toList();

              // Build the combined list including own status and all others
              // so we can pass the right initialGroupIndex to StatusViewerScreen
              final allOtherGroups = [...unviewedGroups, ...viewedGroups];

              return CustomScrollView(
                slivers: [
                  // My Status
                  SliverToBoxAdapter(
                    child: _MyStatusTile(
                      uid: uid,
                      ownGroup: ownGroup,
                      onViewOwn: ownGroup == null
                          ? null
                          : () => _openViewer(context, [ownGroup], 0, uid),
                      onAdd: () => _openCreate(context, uid),
                    ),
                  ),

                  // Recent updates
                  if (unviewedGroups.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                        child: _SectionHeader(label: 'Recent updates')),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (ctx, i) => _StatusTile(
                          group: unviewedGroups[i],
                          currentUid: uid,
                          viewed: false,
                          onTap: () => _openViewer(
                              context, allOtherGroups, i, uid),
                        ),
                        childCount: unviewedGroups.length,
                      ),
                    ),
                  ],

                  // Viewed updates
                  if (viewedGroups.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                        child: _SectionHeader(label: 'Viewed updates')),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (ctx, i) => _StatusTile(
                          group: viewedGroups[i],
                          currentUid: uid,
                          viewed: true,
                          onTap: () => _openViewer(context, allOtherGroups,
                              unviewedGroups.length + i, uid),
                        ),
                        childCount: viewedGroups.length,
                      ),
                    ),
                  ],

                  if (unviewedGroups.isEmpty && viewedGroups.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyOthers(),
                    ),

                  const SliverToBoxAdapter(child: SizedBox(height: 80)),
                ],
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () =>
            _openCreate(context, context.read<AppProvider>().chatUserId),
        child: const Icon(Icons.camera_alt_rounded),
      ),
    );
  }

  void _openCreate(BuildContext context, String uid) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => StatusCreateScreen(uid: uid)));
  }

  void _openViewer(BuildContext context, List<UserStatuses> groups,
      int index, String uid) {
    if (groups.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatusViewerScreen(
          groups: groups,
          initialGroupIndex: index,
          currentUid: uid,
        ),
      ),
    );
  }
}

// ── My Status tile ─────────────────────────────────────────────────────────────

class _MyStatusTile extends StatelessWidget {
  final String uid;
  final UserStatuses? ownGroup;
  final VoidCallback? onViewOwn;
  final VoidCallback onAdd;

  const _MyStatusTile({
    required this.uid,
    required this.ownGroup,
    required this.onViewOwn,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final hasStatus = ownGroup != null;
    final latest = ownGroup?.statuses.last;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: GestureDetector(
            onTap: hasStatus ? onViewOwn : onAdd,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _StatusRing(
                  hasStatus: hasStatus,
                  viewed: true, // own status ring is always "viewed" style
                  child: _AvatarPlaceholder(uid: uid, radius: 26),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: GestureDetector(
                    onTap: onAdd,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.add, size: 13,
                          color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
          title: const Text('My status',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  fontSize: 15)),
          subtitle: Text(
            hasStatus
                ? 'Tap to view · ${_timeAgo(latest!.createdAt)}'
                : 'Tap to add a status update',
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 12),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.add_a_photo_rounded,
                color: AppColors.primary),
            tooltip: 'Add status',
            onPressed: onAdd,
          ),
          onTap: hasStatus ? onViewOwn : onAdd,
        ),
      ),
    );
  }
}

// ── Other user tile ────────────────────────────────────────────────────────────

class _StatusTile extends StatelessWidget {
  final UserStatuses group;
  final String currentUid;
  final bool viewed;
  final VoidCallback onTap;

  const _StatusTile({
    required this.group,
    required this.currentUid,
    required this.viewed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final latest = group.statuses.last;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Card(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: GestureDetector(
            onTap: onTap,
            child: _StatusRing(
              hasStatus: true,
              viewed: viewed,
              child: group.photoUrl != null
                  ? CircleAvatar(
                      radius: 26,
                      backgroundImage:
                          CachedNetworkImageProvider(group.photoUrl!),
                    )
                  : _AvatarPlaceholder(uid: group.uid, name: group.name,
                      radius: 26),
            ),
          ),
          title: Text(
            group.name,
            style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                fontSize: 15),
          ),
          subtitle: Text(
            _timeAgo(latest.createdAt),
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 12),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

// ── Status ring decoration ─────────────────────────────────────────────────────

class _StatusRing extends StatelessWidget {
  final bool hasStatus;
  final bool viewed;
  final Widget child;

  const _StatusRing({
    required this.hasStatus,
    required this.viewed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasStatus) return child;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: viewed
            ? null
            : const LinearGradient(
                colors: [Color(0xFF833AB4), Color(0xFFFD1D1D),
                    Color(0xFFF77737)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        color: viewed ? Colors.grey.shade400 : null,
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

// ── Avatar placeholder ─────────────────────────────────────────────────────────

class _AvatarPlaceholder extends StatelessWidget {
  final String uid;
  final String? name;
  final double radius;

  const _AvatarPlaceholder(
      {required this.uid, this.name, required this.radius});

  @override
  Widget build(BuildContext context) {
    final letter = (name?.isNotEmpty == true)
        ? name![0].toUpperCase()
        : uid.isNotEmpty
            ? uid[0].toUpperCase()
            : '?';
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.primary,
      child: Text(letter,
          style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: radius * 0.7)),
    );
  }
}

// ── Section header ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

// ── Empty state ────────────────────────────────────────────────────────────────

class _EmptyOthers extends StatelessWidget {
  const _EmptyOthers();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_stories_rounded,
                size: 64,
                color: AppColors.textSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            const Text(
              'No status updates yet',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              'When your contacts post a status, it will appear here.',
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

// ── Helpers ────────────────────────────────────────────────────────────────────

String _timeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return 'Today, ${DateFormat('h:mm a').format(dt)}';
  return DateFormat('d MMM, h:mm a').format(dt);
}
