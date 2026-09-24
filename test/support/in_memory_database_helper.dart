import 'package:BizNote/database/database_helper.dart';
import 'package:BizNote/models/note.dart';
import 'package:sqflite/sqflite.dart';

/// In-memory stand-in for the SQLite layer so widget/unit tests never touch a
/// platform channel. Implements the same contract the UI relies on.
///
/// Shared by `notes_flow_test.dart` (widget flows) and `note_cloud_sync_test.dart`
/// (what the provider mirrors to Firebase).
class InMemoryDatabaseHelper implements DatabaseHelper {
  InMemoryDatabaseHelper({List<Note> seeded = const <Note>[]})
      : _notes = List<Note>.of(seeded);

  final List<Note> _notes;
  int _nextId = 100;

  @override
  Future<Database> get database =>
      throw UnsupportedError('Widget tests do not use sqflite');

  @override
  Future<List<Note>> getNotes() async {
    // Mirrors `DatabaseHelper.getNotes`: manual order first, newest second.
    final List<Note> sorted = List<Note>.of(_notes)
      ..sort((Note a, Note b) {
        final int byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : b.updatedAt.compareTo(a.updatedAt);
      });
    return sorted;
  }

  @override
  Future<Note?> getNoteById(int id) async {
    for (final Note note in _notes) {
      if (note.id == id) {
        return note;
      }
    }
    return null;
  }

  @override
  Future<int> getNoteCount() async => _notes.length;

  @override
  Future<List<Note>> searchNotes(String query) async {
    final List<Note> all = await getNotes();
    return all
        .where((Note note) =>
            note.title.contains(query) || note.content.contains(query))
        .toList();
  }

  @override
  Future<int> insertNote(Note note) async {
    final int id = note.id ?? _nextId++;
    // Mirrors `DatabaseHelper.insertNote`: a new note goes on top.
    final int top = _notes.isEmpty
        ? 0
        : _notes
                .map((Note existing) => existing.sortOrder)
                .reduce((int a, int b) => a < b ? a : b) -
            1;
    _notes
      ..removeWhere((Note existing) => existing.id == id)
      ..add(note.copyWith(id: id, sortOrder: top));
    return id;
  }

  @override
  Future<void> updateNoteOrder(List<int> orderedIds) async {
    for (int i = 0; i < orderedIds.length; i++) {
      final int index =
          _notes.indexWhere((Note note) => note.id == orderedIds[i]);
      if (index != -1) {
        _notes[index] = _notes[index].copyWith(sortOrder: i);
      }
    }
  }

  @override
  Future<int> updateNote(Note note) async {
    final int index =
        _notes.indexWhere((Note existing) => existing.id == note.id);
    if (index == -1) {
      return 0;
    }
    _notes[index] = note;
    return 1;
  }

  @override
  Future<int> deleteNote(int id) async {
    final int before = _notes.length;
    _notes.removeWhere((Note note) => note.id == id);
    return before - _notes.length;
  }

  @override
  Future<int> deleteAllNotes() async {
    final int removed = _notes.length;
    _notes.clear();
    return removed;
  }

  @override
  Future<int> updateFixedNoteContent({
    required String content,
    required String updatedAt,
  }) async {
    final int index =
        _notes.indexWhere((Note note) => note.id == Note.fixedNoteId);
    if (index == -1) {
      return 0;
    }
    // Mirrors the production UPDATE: content and updatedAt only.
    _notes[index] = _notes[index].copyWith(
      content: content,
      updatedAt: updatedAt,
    );
    return 1;
  }

  @override
  Future<bool> databaseExists() async => true;

  @override
  Future<void> close() async {}
}

/// Fails every single note read, like the dead database connection that used to
/// leave the editor stuck on its spinner (`database_closed`).
class FailingReadDatabaseHelper extends InMemoryDatabaseHelper {
  FailingReadDatabaseHelper({super.seeded});

  @override
  Future<Note?> getNoteById(int id) async {
    throw Exception('database_closed 1');
  }
}
