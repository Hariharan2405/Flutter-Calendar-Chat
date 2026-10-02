import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../constants/app_theme.dart';
import '../services/chat_service.dart';
import '../utils/responsive.dart';
import '../utils/snack_util.dart';

/// Everything the user has starred, newest first.
///
/// These are stored as copies under the user's own document tree rather than as
/// flags on the original messages: chat messages are removed after two days by
/// the Firestore TTL policy, and a star that vanished with them would defeat
/// the purpose of starring in the first place.
class StarredMessagesScreen extends StatelessWidget {
  final String uid;

  const StarredMessagesScreen({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    final service = ChatService();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Starred messages')),
      body: ContentWidth(
        maxWidth: 840,
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: service.starredMessages(uid),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data ?? [];
            if (items.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_outline_rounded,
                          size: 48,
                          color:
                              AppColors.textSecondary.withValues(alpha: 0.35)),
                      const SizedBox(height: 14),
                      const Text('Nothing starred yet',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 6),
                      const Text(
                        'Long-press any message and choose Star to keep it here '
                        'after the conversation clears.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
              itemBuilder: (ctx, i) {
                final m = items[i];
                final starredAt = m['starredAt'];
                final imageUrl = m['imageUrl'] as String?;

                return ListTile(
                  leading: imageUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedNetworkImage(
                            imageUrl: imageUrl,
                            memCacheWidth: 132,
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                const Icon(Icons.broken_image_rounded),
                          ),
                        )
                      : CircleAvatar(
                          backgroundColor:
                              Colors.amber.shade700.withValues(alpha: 0.15),
                          child: Icon(Icons.star_rounded,
                              color: Colors.amber.shade700, size: 20),
                        ),
                  title: Text(
                    (m['preview'] as String?) ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    [
                      if ((m['chatLabel'] as String?)?.isNotEmpty ?? false)
                        m['chatLabel'],
                      if (starredAt != null) _fmt(starredAt),
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.star_rounded, color: Colors.amber),
                    tooltip: 'Unstar',
                    onPressed: () async {
                      await service.unstarMessage(uid, m['id'] as String);
                      if (ctx.mounted) ctx.showSuccess('Removed from starred');
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  static String _fmt(dynamic ts) {
    try {
      return DateFormat('d MMM, h:mm a').format(ts.toDate() as DateTime);
    } catch (_) {
      return '';
    }
  }
}
