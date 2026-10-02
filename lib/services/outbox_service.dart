import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/message_model.dart';
import 'chat_service.dart';
import 'group_chat_service.dart';

/// A send that has not reached the server yet.
class OutboxEntry {
  final String id;
  final MessageType type;
  /// Null for a group send.
  final String? receiverUid;
  /// Null for a 1:1 send.
  final String? groupId;
  final String senderUid;
  final String senderName;
  final List<String> participants;
  final String? text;
  final String? localPath;
  final String? fileName;
  final int? fileSizeBytes;
  final int? durationSeconds;
  int attempts;

  OutboxEntry({
    required this.id,
    required this.type,
    required this.senderUid,
    this.receiverUid,
    this.groupId,
    this.senderName = '',
    this.participants = const [],
    this.text,
    this.localPath,
    this.fileName,
    this.fileSizeBytes,
    this.durationSeconds,
    this.attempts = 0,
  });

  bool get isGroup => groupId != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'senderUid': senderUid,
        'receiverUid': receiverUid,
        'groupId': groupId,
        'senderName': senderName,
        'participants': participants,
        'text': text,
        'localPath': localPath,
        'fileName': fileName,
        'fileSizeBytes': fileSizeBytes,
        'durationSeconds': durationSeconds,
        'attempts': attempts,
      };

  static OutboxEntry fromJson(Map<String, dynamic> j) => OutboxEntry(
        id: j['id'] as String,
        type: MessageType.values.firstWhere(
          (t) => t.name == j['type'],
          orElse: () => MessageType.text,
        ),
        senderUid: j['senderUid'] as String,
        receiverUid: j['receiverUid'] as String?,
        groupId: j['groupId'] as String?,
        senderName: (j['senderName'] as String?) ?? '',
        participants: (j['participants'] as List?)?.cast<String>() ?? const [],
        text: j['text'] as String?,
        localPath: j['localPath'] as String?,
        fileName: j['fileName'] as String?,
        fileSizeBytes: j['fileSizeBytes'] as int?,
        durationSeconds: j['durationSeconds'] as int?,
        attempts: (j['attempts'] as int?) ?? 0,
      );
}

/// Persists sends that failed and retries them when connectivity returns.
///
/// Firestore's own offline cache already queues plain document writes, but it
/// cannot help with anything that uploads to Storage first — an image, voice
/// note, or document send simply fails offline and, before this, was lost the
/// moment the screen was disposed. This keeps those on disk instead.
class OutboxService {
  OutboxService._();
  static final OutboxService instance = OutboxService._();

  static const _key = 'outbox_queue_v1';
  static const _maxAttempts = 5;

  final _chat = ChatService();
  final _groups = GroupChatService();
  bool _draining = false;

  /// Emits whenever the queue length changes, so a screen can show a badge.
  final _countCtrl = StreamController<int>.broadcast();
  Stream<int> get pendingCount => _countCtrl.stream;

  /// Retries the queue. Called at launch and whenever the app returns to the
  /// foreground — deliberately not on a connectivity listener, which would mean
  /// another dependency for a trigger that adds little: the realistic recovery
  /// is the user picking the phone back up, which is a resume.
  Future<void> start() => drain();

  Future<List<OutboxEntry>> _load(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => OutboxEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(SharedPreferences prefs, List<OutboxEntry> list) async {
    await prefs.setString(
        _key, jsonEncode(list.map((e) => e.toJson()).toList()));
    _countCtrl.add(list.length);
  }

  Future<void> enqueue(OutboxEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _load(prefs);
    list.add(entry);
    await _save(prefs, list);
  }

  Future<int> count() async {
    final prefs = await SharedPreferences.getInstance();
    return (await _load(prefs)).length;
  }

  /// Attempts every queued send in order. Entries that fail stay queued until
  /// [_maxAttempts]; past that they are dropped, because a send that has failed
  /// five times is not going to start working and an outbox that never empties
  /// is worse than one that admits defeat.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      var list = await _load(prefs);
      if (list.isEmpty) return;

      final survivors = <OutboxEntry>[];
      for (final entry in list) {
        try {
          await _send(entry);
        } catch (_) {
          entry.attempts++;
          if (entry.attempts < _maxAttempts) survivors.add(entry);
        }
      }
      await _save(prefs, survivors);
    } finally {
      _draining = false;
    }
  }

  Future<void> _send(OutboxEntry e) async {
    // A media entry whose local file has since been cleaned up can never
    // succeed — treat it as sent so it leaves the queue.
    final file = e.localPath == null ? null : File(e.localPath!);
    if (file != null && !file.existsSync()) return;

    if (e.isGroup) {
      switch (e.type) {
        case MessageType.text:
          await _groups.sendTextMessage(
            groupId: e.groupId!,
            senderId: e.senderUid,
            senderName: e.senderName,
            participants: e.participants,
            text: e.text ?? '',
          );
        case MessageType.image:
          await _groups.sendImageMessage(
            groupId: e.groupId!,
            senderId: e.senderUid,
            senderName: e.senderName,
            participants: e.participants,
            imageFile: file!,
            text: e.text,
          );
        case MessageType.video:
          await _groups.sendVideoMessage(
            groupId: e.groupId!,
            senderId: e.senderUid,
            senderName: e.senderName,
            participants: e.participants,
            videoFile: file!,
            text: e.text,
          );
        case MessageType.voice:
          await _groups.sendVoiceMessage(
            groupId: e.groupId!,
            senderId: e.senderUid,
            senderName: e.senderName,
            participants: e.participants,
            audioFile: file!,
            durationSeconds: e.durationSeconds ?? 0,
          );
        case MessageType.audioFile:
          await _groups.sendAudioFileMessage(
            groupId: e.groupId!,
            senderId: e.senderUid,
            senderName: e.senderName,
            participants: e.participants,
            audioFile: file!,
            fileName: e.fileName ?? 'audio',
            fileSizeBytes: e.fileSizeBytes ?? 0,
            durationSeconds: e.durationSeconds ?? 0,
          );
        case MessageType.document:
          await _groups.sendDocumentMessage(
            groupId: e.groupId!,
            senderId: e.senderUid,
            senderName: e.senderName,
            participants: e.participants,
            file: file!,
            fileName: e.fileName ?? 'file',
            fileSizeBytes: e.fileSizeBytes ?? 0,
          );
        default:
          break;
      }
      return;
    }

    switch (e.type) {
      case MessageType.text:
        await _chat.sendTextMessage(
          senderUid: e.senderUid,
          receiverUid: e.receiverUid!,
          text: e.text ?? '',
        );
      case MessageType.image:
        await _chat.sendImageMessage(
          senderUid: e.senderUid,
          receiverUid: e.receiverUid!,
          imageFile: file!,
          text: e.text,
        );
      case MessageType.video:
        await _chat.sendVideoMessage(
          senderUid: e.senderUid,
          receiverUid: e.receiverUid!,
          videoFile: file!,
          text: e.text,
        );
      case MessageType.voice:
        await _chat.sendVoiceMessage(
          senderUid: e.senderUid,
          receiverUid: e.receiverUid!,
          audioFile: file!,
          durationSeconds: e.durationSeconds ?? 0,
        );
      case MessageType.audioFile:
        await _chat.sendAudioFileMessage(
          senderUid: e.senderUid,
          receiverUid: e.receiverUid!,
          audioFile: file!,
          fileName: e.fileName ?? 'audio',
          fileSizeBytes: e.fileSizeBytes ?? 0,
          durationSeconds: e.durationSeconds ?? 0,
        );
      case MessageType.document:
        await _chat.sendDocumentMessage(
          senderUid: e.senderUid,
          receiverUid: e.receiverUid!,
          file: file!,
          fileName: e.fileName ?? 'file',
          fileSizeBytes: e.fileSizeBytes ?? 0,
        );
      default:
        break;
    }
  }
}
