import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../constants/app_theme.dart';
import '../models/user_profile_model.dart';
import '../providers/app_provider.dart';
import '../services/camera_share_service.dart';
import 'camera_viewer_screen.dart';

/// Read-only admin view that lists every registered user profile.
/// Only reachable by user "Harry" via the expense-description trigger "Hari@2405".
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final _db = FirebaseFirestore.instance;
  final _searchCtrl = TextEditingController();
  String _query = '';
  String? _requestingUid; // UID of the user whose button is currently loading

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _startCameraShare(UserProfileModel target) async {
    if (_requestingUid != null) return; // already waiting for one request
    setState(() => _requestingUid = target.uid);
    try {
      final provider = context.read<AppProvider>();
      final myUid = provider.chatUserId;
      final myName = provider.profile?.name ?? 'Harry';
      final (:shareId, :channelId) = await CameraShareService().createRequest(
        requesterId: myUid,
        requesterName: myName,
        targetId: target.uid,
      );
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CameraViewerScreen(
            shareId: shareId,
            channelId: channelId,
            targetName: target.name,
            requesterId: myUid,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start camera share: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _requestingUid = null);
    }
  }

  String _fmtDate(Timestamp? ts) {
    if (ts == null) return '—';
    return DateFormat('d MMM y').format(ts.toDate());
  }

  String _lastSeen(Timestamp? ts) {
    if (ts == null) return 'Never';
    final dt = ts.toDate();
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('d MMM y').format(dt);
  }

  bool _isOnline(Timestamp? ts) {
    if (ts == null) return false;
    return DateTime.now().difference(ts.toDate()).inSeconds < 60;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.people_rounded, size: 20),
          SizedBox(width: 8),
          Text('All Users'),
        ]),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(children: [
              Icon(Icons.lock_rounded, size: 13, color: Colors.white70),
              SizedBox(width: 4),
              Text('Read only',
                  style: TextStyle(fontSize: 11, color: Colors.white70)),
            ]),
          ),
        ],
      ),
      body: Column(children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search by name…',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
            ),
            onChanged: (v) => setState(() => _query = v.toLowerCase().trim()),
          ),
        ),

        // User list
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: _db
                .collection('user_profiles')
                .orderBy('name')
                .snapshots(),
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final myUid = context.read<AppProvider>().chatUserId;
              final allDocs = snap.data?.docs ?? [];
              final users = allDocs
                  .map((d) => UserProfileModel.fromFirestore(d))
                  .where((u) =>
                      u.uid != myUid && // exclude Harry himself
                      (_query.isEmpty ||
                          u.name.toLowerCase().contains(_query)))
                  .toList();

              if (users.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_off_rounded,
                          size: 56,
                          color: AppColors.textSecondary.withValues(alpha: 0.3)),
                      const SizedBox(height: 12),
                      Text(
                        _query.isEmpty ? 'No users yet' : 'No users match "$_query"',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text(
                      '${users.length} user${users.length != 1 ? 's' : ''}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                      itemCount: users.length,
                      itemBuilder: (ctx, i) => _UserCard(
                        user: users[i],
                        fmtDate: _fmtDate,
                        lastSeen: _lastSeen,
                        isOnline: _isOnline,
                        requesting: _requestingUid == users[i].uid,
                        onVideoTap: () => _startCameraShare(users[i]),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ── User card ─────────────────────────────────────────────────────────────────

class _UserCard extends StatelessWidget {
  final UserProfileModel user;
  final String Function(Timestamp?) fmtDate;
  final String Function(Timestamp?) lastSeen;
  final bool Function(Timestamp?) isOnline;
  final bool requesting;
  final VoidCallback onVideoTap;

  const _UserCard({
    required this.user,
    required this.fmtDate,
    required this.lastSeen,
    required this.isOnline,
    required this.requesting,
    required this.onVideoTap,
  });

  @override
  Widget build(BuildContext context) {
    final online = isOnline(Timestamp.fromDate(user.lastSeen));
    final seenLabel = lastSeen(Timestamp.fromDate(user.lastSeen));

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          // Avatar
          Stack(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: AppColors.primary,
              backgroundImage: user.photoUrl != null
                  ? CachedNetworkImageProvider(user.photoUrl!)
                  : null,
              child: user.photoUrl == null
                  ? Text(
                      user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold))
                  : null,
            ),
            if (online)
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
          ]),
          const SizedBox(width: 14),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      user.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppColors.textPrimary),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: online
                          ? const Color(0xFF4CAF50).withValues(alpha: 0.12)
                          : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      online ? 'Online' : seenLabel,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: online
                              ? const Color(0xFF2E7D32)
                              : AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Camera share button
                  GestureDetector(
                    onTap: requesting ? null : onVideoTap,
                    child: Container(
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.3)),
                      ),
                      child: requesting
                          ? const Padding(
                              padding: EdgeInsets.all(8),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.primary),
                            )
                          : const Icon(Icons.videocam_rounded,
                              color: AppColors.primary, size: 18),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                if (user.description?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      user.description!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ),
                Text(
                  'Joined ${fmtDate(Timestamp.fromDate(user.createdAt))}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
