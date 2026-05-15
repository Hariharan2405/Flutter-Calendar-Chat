import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import '../models/note_model.dart';

class NotesService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final _uuid = const Uuid();

  CollectionReference<Map<String, dynamic>> _collection(String userId) {
    return _db.collection('users').doc(userId).collection('notes');
  }

  Stream<List<NoteModel>> notesForDate(String userId, String dateKey) {
    return _collection(userId)
        .where('dateKey', isEqualTo: dateKey)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(NoteModel.fromFirestore).toList());
  }

  Stream<List<NoteModel>> allNotes(String userId) {
    return _collection(userId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(NoteModel.fromFirestore).toList());
  }

  Future<NoteModel> addNote({
    required String userId,
    required DateTime date,
    required String title,
    required String content,
  }) async {
    final now = DateTime.now();
    final id = _uuid.v4();
    final note = NoteModel(
      id: id,
      userId: userId,
      dateKey: NoteModel.dateToKey(date),
      title: title,
      content: content,
      createdAt: now,
      updatedAt: now,
    );
    await _collection(userId).doc(id).set(note.toFirestore());
    return note;
  }

  Future<void> updateNote(String userId, NoteModel note) async {
    final updated = note.copyWith(updatedAt: DateTime.now());
    await _collection(userId).doc(note.id).update({
      'title': updated.title,
      'content': updated.content,
      'updatedAt': Timestamp.fromDate(updated.updatedAt),
    });
  }

  Future<void> deleteNote(String userId, String noteId) async {
    await _collection(userId).doc(noteId).delete();
  }

  Future<Set<String>> getDatesWithNotes(String userId) async {
    final snap = await _collection(userId).get();
    return snap.docs.map((d) => d.data()['dateKey'] as String).toSet();
  }
}
