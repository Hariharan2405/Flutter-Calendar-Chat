import 'package:cloud_firestore/cloud_firestore.dart';

class GroupModel {
  final String id;
  final String name;
  final String? iconUrl;
  final String createdBy;
  final List<String> participants;
  final List<String> admins;
  final String lastMessage;
  final String lastSenderId;
  final String lastSenderName;
  final DateTime? lastMessageTime;
  final DateTime createdAt;
  final Map<String, int> unreadCounts;
  final Map<String, DateTime?> deliveredAt; // uid → lastDeliveredAt
  final Map<String, DateTime?> readAt;      // uid → lastReadAt
  final int?    backgroundColor;            // shared ARGB color value
  final String? backgroundImageUrl;         // shared wallpaper URL (Storage)
  final String? pinnedMessageId;
  final String? pinnedText;
  /// UIDs named with @ in the most recent message. A mention reaches you even
  /// when the group is muted.
  final List<String> lastMentions;
  /// uid → the moment they were last seen typing. Read through
  /// [TypingState.isActive], which treats stale stamps as "not typing".
  final Map<String, DateTime> typingAt;
  /// uid → display name captured alongside the typing stamp, so the indicator
  /// can name the person without a second lookup.
  final Map<String, String> typingNames;

  const GroupModel({
    required this.id,
    required this.name,
    this.iconUrl,
    required this.createdBy,
    required this.participants,
    required this.admins,
    this.lastMessage = '',
    this.lastSenderId = '',
    this.lastSenderName = '',
    this.lastMessageTime,
    required this.createdAt,
    this.unreadCounts = const {},
    this.deliveredAt = const {},
    this.readAt = const {},
    this.backgroundColor,
    this.backgroundImageUrl,
    this.pinnedMessageId,
    this.pinnedText,
    this.lastMentions = const [],
    this.typingAt = const {},
    this.typingNames = const {},
  });

  int unreadFor(String uid) => unreadCounts[uid] ?? 0;
  bool isAdmin(String uid) => admins.contains(uid);

  /// Returns true if any OTHER member has delivered at or past [msgTime].
  bool isDeliveredTo(String senderUid, DateTime msgTime) {
    return deliveredAt.entries.any((e) =>
        e.key != senderUid && e.value != null && !msgTime.isAfter(e.value!));
  }

  /// Returns true if any OTHER member has read at or past [msgTime].
  bool isReadBy(String senderUid, DateTime msgTime) {
    return readAt.entries.any((e) =>
        e.key != senderUid && e.value != null && !msgTime.isAfter(e.value!));
  }

  factory GroupModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final unread = <String, int>{};
    final delivered = <String, DateTime?>{};
    final read = <String, DateTime?>{};
    final typing = <String, DateTime>{};
    final typingNames = <String, String>{};
    for (final key in data.keys) {
      if (key.startsWith('unread_')) {
        unread[key.substring(7)] = (data[key] as num?)?.toInt() ?? 0;
      } else if (key.startsWith('lastDeliveredAt_')) {
        delivered[key.substring(16)] = (data[key] as Timestamp?)?.toDate();
      } else if (key.startsWith('lastReadAt_')) {
        read[key.substring(11)] = (data[key] as Timestamp?)?.toDate();
      } else if (key.startsWith('typingName_')) {
        final v = data[key] as String?;
        if (v != null) typingNames[key.substring(11)] = v;
      } else if (key.startsWith('typing_')) {
        final v = (data[key] as Timestamp?)?.toDate();
        if (v != null) typing[key.substring(7)] = v;
      }
    }
    return GroupModel(
      id: doc.id,
      name: data['name'] as String? ?? '',
      iconUrl: data['iconUrl'] as String?,
      createdBy: data['createdBy'] as String? ?? '',
      participants: List<String>.from(data['participants'] as List? ?? []),
      admins: List<String>.from(data['admins'] as List? ?? []),
      lastMessage: data['lastMessage'] as String? ?? '',
      lastSenderId: data['lastSenderId'] as String? ?? '',
      lastSenderName: data['lastSenderName'] as String? ?? '',
      lastMessageTime: (data['lastMessageTime'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      unreadCounts: unread,
      deliveredAt: delivered,
      readAt: read,
      backgroundColor:     data['backgroundColor']     as int?,
      backgroundImageUrl:  data['backgroundImageUrl']  as String?,
      pinnedMessageId:     data['pinnedMessageId']     as String?,
      pinnedText:          data['pinnedText']          as String?,
      lastMentions: List<String>.from(data['lastMentions'] as List? ?? []),
      typingAt: typing,
      typingNames: typingNames,
    );
  }
}
