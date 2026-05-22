import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../providers/app_provider.dart';
import '../models/note_model.dart';
import '../constants/app_theme.dart';
import '../utils/snack_util.dart';

class NotesSection extends StatelessWidget {
  const NotesSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final notes = provider.notesForSelectedDate;
    final dateLabel = DateFormat('EEE, d MMM yyyy').format(provider.selectedDate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.sticky_note_2_rounded, color: AppColors.noteIndicator, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Notes — $dateLabel',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _showNoteDialog(context, provider),
                icon: const Icon(Icons.add_circle_rounded, color: AppColors.primary),
                tooltip: 'Add note',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
        if (notes.isEmpty)
          _buildEmpty()
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: notes.length,
              itemBuilder: (ctx, i) => _NoteCard(
                note: notes[i],
                onEdit: () => _showNoteDialog(context, provider, note: notes[i]),
                onDelete: () async {
                  try {
                    await provider.deleteNote(notes[i].id);
                  } catch (_) {
                    if (context.mounted) context.showError('Failed to delete note');
                  }
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty() {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note_alt_outlined, size: 40, color: AppColors.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            Text(
              'No notes for this day',
              style: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.7), fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap + to add a note',
              style: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.5), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  void _showNoteDialog(BuildContext context, AppProvider provider, {NoteModel? note}) {
    final titleCtrl = TextEditingController(text: note?.title ?? '');
    final contentCtrl = TextEditingController(text: note?.content ?? '');
    final isEdit = note != null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isEdit ? 'Edit Note' : 'New Note',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: 'Title', hintText: 'Note title...'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentCtrl,
                decoration: const InputDecoration(labelText: 'Content', hintText: 'Write your note...'),
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        final title = titleCtrl.text.trim();
                        final content = contentCtrl.text.trim();
                        if (title.isEmpty && content.isEmpty) return;
                        try {
                          if (isEdit) {
                            await provider.updateNote(
                              note.copyWith(title: title, content: content),
                            );
                          } else {
                            await provider.addNote(title, content);
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (_) {
                          if (ctx.mounted) {
                            ctx.showError(isEdit ? 'Failed to update note' : 'Failed to save note');
                          }
                        }
                      },
                      child: Text(isEdit ? 'Update' : 'Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final NoteModel note;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _NoteCard({required this.note, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: const Border(
            left: BorderSide(color: AppColors.noteIndicator, width: 4),
          ),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          title: Text(
            note.title.isNotEmpty ? note.title : 'Untitled',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: note.content.isNotEmpty
              ? Text(
                  note.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.primary),
                onPressed: onEdit,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.holiday),
                onPressed: () => _confirmDelete(context),
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Note'),
        content: const Text('Are you sure you want to delete this note?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onDelete();
            },
            child: const Text('Delete', style: TextStyle(color: AppColors.holiday)),
          ),
        ],
      ),
    );
  }
}
