import 'package:flutter/foundation.dart';

import '../models/note.dart';
import '../database/database_helper.dart';
import '../utils/date_formatter.dart';

class NoteProvider with ChangeNotifier {
  final DatabaseHelper _databaseHelper = DatabaseHelper.instance;

  /// List of all notes
  List<Note> _notes = [];

  /// The currently selected note (for editing)
  Note? _selectedNote;

  /// Whether the provider is currently loading data
  bool _isLoading = false;

  /// Search query for filtering notes
  String _searchQuery = '';

  /// List of currently filtered notes (after search)
  List<Note> get filteredNotes => _notes;

  /// All notes
  List<Note> get notes => _notes;

  /// Currently selected note
  Note? get selectedNote => _selectedNote;

  /// Loading state
  bool get isLoading => _isLoading;

  /// Search query
  String get searchQuery => _searchQuery;

  /// Total count of notes
  int get noteCount => _notes.length;

  /// Initialize and load all notes from database
  Future<void> loadNotes() async {
    _isLoading = true;
    notifyListeners();

    try {
      _notes = await _databaseHelper.getNotes();
      _filterNotes();
    } catch (e) {
      debugPrint('Error loading notes: $e');
      _notes = [];
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Refresh notes from database
  Future<void> refreshNotes() async {
    await loadNotes();
  }

  /// Filter notes based on search query
  void _filterNotes() {
    if (_searchQuery.isEmpty) {
      // No filtering needed, all notes are shown
      return;
    }

    _notes = _notes
        .where((note) =>
            note.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            note.content.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  /// Set the search query and filter notes
  void setSearchQuery(String query) {
    _searchQuery = query;
    _filterNotes();
    notifyListeners();
  }

  /// Clear the search query
  void clearSearchQuery() {
    _searchQuery = '';
    _filterNotes();
    notifyListeners();
  }

  /// Set the currently selected note
  void setSelectedNote(Note? note) {
    _selectedNote = note;
    notifyListeners();
  }

  /// Insert a new note into the database
  Future<int> insertNote(String title, String content) async {
    final now = DateTime.now();
    final date = DateFormatter.formatDate(now);

    final note = Note(
      title: title,
      content: content,
      date: date,
    );

    final id = await _databaseHelper.insertNote(note);
    
    // Reload notes to reflect the new note
    await loadNotes();
    
    return id;
  }

  /// Update an existing note in the database
  Future<bool> updateNote(Note note) async {
    try {
      final updatedNote = note.copyWith(
        date: DateFormatter.formatDate(DateTime.now()),
      );

      final rowsAffected = await _databaseHelper.updateNote(updatedNote);
      
      if (rowsAffected > 0) {
        // Update the local list
        final index = _notes.indexWhere((n) => n.id == note.id);
        if (index != -1) {
          _notes[index] = updatedNote;
        }
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error updating note: $e');
      return false;
    }
  }

  /// Delete a note from the database
  Future<bool> deleteNote(int id) async {
    try {
      final rowsAffected = await _databaseHelper.deleteNote(id);
      
      if (rowsAffected > 0) {
        // Remove from local list
        _notes.removeWhere((note) => note.id == id);
        if (_selectedNote?.id == id) {
          _selectedNote = null;
        }
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error deleting note: $e');
      return false;
    }
  }

  /// Delete multiple notes
  Future<int> deleteNotes(List<int> ids) async {
    int deletedCount = 0;
    for (final id in ids) {
      if (await deleteNote(id)) {
        deletedCount++;
      }
    }
    return deletedCount;
  }

  /// Clear all notes (use with caution)
  Future<int> clearAllNotes() async {
    final count = await _databaseHelper.getNoteCount();
    await _databaseHelper.deleteAllNotes();
    _notes = [];
    _selectedNote = null;
    notifyListeners();
    return count;
  }

  /// Select a note for editing by its ID
  Future<Note?> selectNoteById(int id) async {
    final note = await _databaseHelper.getNoteById(id);
    if (note != null) {
      _selectedNote = note;
      notifyListeners();
    }
    return note;
  }

  /// Clear the selected note
  void clearSelectedNote() {
    _selectedNote = null;
    notifyListeners();
  }

  /// Check if a note with the given ID exists
  bool noteExists(int id) {
    return _notes.any((note) => note.id == id);
  }
}
