import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants/app_theme.dart';
import '../models/user_profile_model.dart';
import 'read_only_chat_screen.dart';

class AdminChatScreen extends StatefulWidget {
  final String excludeUid;
  const AdminChatScreen({super.key, required this.excludeUid});

  @override
  State<AdminChatScreen> createState() => _AdminChatScreenState();
}

class _AdminChatScreenState extends State<AdminChatScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  Map<String, UserProfileModel> _profiles = {};
  bool _loadingProfiles = true;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final snap = await _db.collection('user_profiles').get();
    final map = <String, UserProfileModel>{};
    for (final doc in snap.docs) {
      map[doc.id] = UserProfileModel.fromFirestore(doc);
    }
    if (mounted) setState(() { _profiles = map; _loadingProfiles = false; });
  }

  String _fmt(Timestamp? ts) {
    if (ts == null) return '';
    final dt = ts.toDate();
    final now = DateTime.now();
    return (dt.day == now.day && dt.month == now.month && dt.year == now.year)
        ? DateFormat('HH:mm').format(dt)
        : DateFormat('d MMM').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          children: const [
            Icon(Icons.admin_panel_settings_rounded, size: 20),
            SizedBox(width: 8),
            Text('All Chats'),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_rounded, size: 13, color: Colors.white70),
                SizedBox(width: 4),
                Text('Read only', style: TextStyle(fontSize: 11, color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
      body: _loadingProfiles
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<QuerySnapshot>(
              stream: _db.collection('chats').snapshots(),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = (snap.data?.docs ?? [])
                    .where((d) {
                      final data = d.data() as Map<String, dynamic>;
                      if (data['lastMessageTime'] == null) return false;
                      final parts = (data['participants'] as List?)?.cast<String>() ?? [];
                      return !parts.contains(widget.excludeUid);
                    })
                    .toList()
                  ..sort((a, b) {
                    final ta = (a.data() as Map)['lastMessageTime'] as Timestamp?;
                    final tb = (b.data() as Map)['lastMessageTime'] as Timestamp?;
                    if (ta == null && tb == null) return 0;
                    if (ta == null) return 1;
                    if (tb == null) return -1;
                    return tb.compareTo(ta);
                  });

                if (docs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline_rounded,
                            size: 56,
                            color: AppColors.textSecondary.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        const Text('No chats yet',
                            style: TextStyle(color: AppColors.textSecondary)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  itemBuilder: (ctx, i) {
                    final data = docs[i].data() as Map<String, dynamic>;
                    final parts = (data['participants'] as List?)?.cast<String>() ?? [];
                    if (parts.length < 2) return const SizedBox.shrink();

                    final p1 = _profiles[parts[0]];
                    final p2 = _profiles[parts[1]];
                    final name1 = p1?.name ?? parts[0];
                    final name2 = p2?.name ?? parts[1];
                    final lastMsg = data['lastMessage'] as String? ?? '';
                    final timeStr = _fmt(data['lastMessageTime'] as Timestamp?);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        leading: SizedBox(
                          width: 52,
                          height: 48,
                          child: Stack(
                            children: [
                              Positioned(
                                left: 0,
                                child: CircleAvatar(
                                  radius: 20,
                                  backgroundColor: AppColors.primary,
                                  backgroundImage: p1?.photoUrl != null
                                      ? CachedNetworkImageProvider(p1!.photoUrl!)
                                      : null,
                                  child: p1?.photoUrl == null
                                      ? Text(name1[0].toUpperCase(),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold))
                                      : null,
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: CircleAvatar(
                                  radius: 16,
                                  backgroundColor: AppColors.accent,
                                  backgroundImage: p2?.photoUrl != null
                                      ? CachedNetworkImageProvider(p2!.photoUrl!)
                                      : null,
                                  child: p2?.photoUrl == null
                                      ? Text(name2[0].toUpperCase(),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold))
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                        title: Text(
                          '$name1  ↔  $name2',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary),
                        ),
                        subtitle: lastMsg.isNotEmpty
                            ? Text(lastMsg,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textSecondary))
                            : null,
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(timeStr,
                                style: const TextStyle(
                                    fontSize: 11, color: AppColors.textSecondary)),
                          ],
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReadOnlyChatScreen(
                              uid1: parts[0],
                              uid2: parts[1],
                              name1: name1,
                              name2: name2,
                              photo1: p1?.photoUrl,
                              photo2: p2?.photoUrl,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
