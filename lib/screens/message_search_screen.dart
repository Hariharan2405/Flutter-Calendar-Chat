import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../constants/app_theme.dart';
import '../models/message_model.dart';
import '../services/chat_service.dart';
import '../utils/responsive.dart';

/// Text search within a single conversation.
///
/// Results come back from a one-off fetch rather than a live stream — a search
/// is a snapshot of a question you asked, and having rows appear or reorder
/// underneath you mid-read is worse than being a few seconds stale.
class MessageSearchScreen extends StatefulWidget {
  /// Runs the actual query. Injected so this screen serves 1:1 and group chats
  /// without knowing the difference between them.
  final Future<List<MessageModel>> Function(String query) onSearch;
  final String title;

  /// Called with the chosen message id when a result is tapped, so the caller
  /// can scroll to it. Null disables tapping.
  final void Function(MessageModel msg)? onOpen;

  const MessageSearchScreen({
    super.key,
    required this.onSearch,
    required this.title,
    this.onOpen,
  });

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<MessageModel> _results = [];
  bool _searching = false;
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    final q = _ctrl.text.trim();
    if (q.isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(q));
  }

  Future<void> _run(String query) async {
    setState(() => _searching = true);
    try {
      final res = await widget.onSearch(query);
      if (mounted) {
        setState(() {
          _results = res;
          _hasSearched = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: 'Search in ${widget.title}',
            hintStyle: const TextStyle(color: Colors.white70, fontSize: 15),
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: _ctrl.clear,
            ),
        ],
      ),
      body: ContentWidth(
        maxWidth: 840,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_hasSearched) {
      return _hint(
        Icons.search_rounded,
        'Search this conversation',
        // Being upfront beats a user concluding search is broken.
        'Only the last two days of messages are kept, so older ones cannot be found.',
      );
    }
    if (_results.isEmpty) {
      return _hint(Icons.search_off_rounded, 'No matches',
          'Try a different word or phrase.');
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
      itemBuilder: (ctx, i) {
        final m = _results[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: AppColors.primary.withValues(alpha: 0.12),
            child: Icon(_iconFor(m), color: AppColors.primary, size: 18),
          ),
          title: Text(
            ChatService.messagePreview(m),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Text(
            DateFormat('d MMM, h:mm a').format(m.timestamp),
            style: const TextStyle(fontSize: 11),
          ),
          onTap: widget.onOpen == null
              ? null
              : () {
                  Navigator.pop(context);
                  widget.onOpen!(m);
                },
        );
      },
    );
  }

  IconData _iconFor(MessageModel m) {
    switch (m.type) {
      case MessageType.image:
      case MessageType.gif:
        return Icons.image_rounded;
      case MessageType.video:
        return Icons.videocam_rounded;
      case MessageType.voice:
        return Icons.mic_rounded;
      case MessageType.audioFile:
        return Icons.audiotrack_rounded;
      case MessageType.document:
        return Icons.description_rounded;
      default:
        return Icons.chat_bubble_outline_rounded;
    }
  }

  Widget _hint(IconData icon, String title, String body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 46,
                color: AppColors.textSecondary.withValues(alpha: 0.35)),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
