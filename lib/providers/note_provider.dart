import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../database/database_helper.dart';
import '../models/note.dart';
import '../services/background_service.dart';
import '../utils/date_formatter.dart';

/// Bridges the SQLite `notes` table to the widget tree.
///
/// The background service runs in its own isolate and writes with its own
/// connection, so this notifier pulls the rows back in whenever the service
/// broadcasts an update, whenever the app is resumed, and through a slow
/// safety-net poll for the cases where the event channel is missed.
class NoteProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// [databaseHelper] and [enableBackgroundSync] exist for tests: production
  /// code uses the defaults (the shared singleton + the live service stream).
  NoteProvider({
    DatabaseHelper? databaseHelper,
    bool enableBackgroundSync = true,
  }) : _databaseHelper = databaseHelper ?? DatabaseHelper.instance {
    if (enableBackgroundSync) {
      unawaited(startBackgroundSync());
    }
  }

  /// Safety net poll. Cheap (one indexed `SELECT`) and only alive while the app
  /// is running; the event stream below is the primary refresh trigger.
  static const Duration _safetyNetInterval = Duration(seconds: 30);

  final DatabaseHelper _databaseHelper;
  final FlutterBackgroundService _backgroundService = FlutterBackgroundService();

  List<Note> _allNotes = <Note>[];
  String _searchQuery = '';
  bool _isLoading = false;
  bool _syncStarted = false;
  StreamSubscription<Map<String, dynamic>?>? _serviceSubscription;
  Timer? _safetyNetTimer;

  /// Notes matching the current search query, newest first.
  List<Note> get notes {
    if (_searchQuery.isEmpty) {
      return List<Note>.unmodifiable(_allNotes);
    }
    final String query = _searchQuery.toLowerCase();
    return List<Note>.unmodifiable(
      _allNotes.where(
        (Note note) =>
            note.title.toLowerCase().contains(query) ||
            note.content.toLowerCase().contains(query),
      ),
    );
  }

  /// Every note in the database, ignoring the search query.
  List<Note> get allNotes => List<Note>.unmodifiable(_allNotes);

  /// Total number of notes, used by the bottom action bar.
  int get noteCount => _allNotes.length;

  /// True while the first read is in flight.
  bool get isLoading => _isLoading;

  /// Current search query.
  String get searchQuery => _searchQuery;

  /// True when at least one note exists.
  bool get hasNotes => _allNotes.isNotEmpty;

  /// Starts the database <-> service bridge. Called automatically by the
  /// constructor unless background sync was disabled.
  Future<void> startBackgroundSync() async {
    if (_syncStarted) {
      return;
    }
    _syncStarted = true;

    try {
      WidgetsBinding.instance.addObserver(this);

      // Primary trigger: the service isolate invokes `update` every time it
      // rewrote the tracked note.
      _serviceSubscription = _backgroundService
          .on(BackgroundServiceMethod.update)
          .listen((Map<String, dynamic>? event) {
        debugPrint('[UI] service update received: $event');
        unawaited(refreshFromDatabase());
      });

      _safetyNetTimer = Timer.periodic(_safetyNetInterval, (Timer timer) {
        unawaited(refreshFromDatabase());
      });
    } catch (error) {
      debugPrint('[UI] background sync unavailable: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    // Coming back to the foreground: reconcile with the database and ask for a
    // fresh fix instead of waiting for the next 15 minute tick.
    unawaited(refreshFromDatabase());
    requestImmediateLocationUpdate();
  }

  /// Asks the background isolate to run a location cycle right now.
  void requestImmediateLocationUpdate() {
    try {
      _backgroundService.invoke(BackgroundServiceMethod.refreshLocation);
    } catch (error) {
      debugPrint('[UI] could not reach the background service: $error');
    }
  }

  /// Stops the persistent service (the next app launch starts it again).
  void pauseLocationTracking() {
    try {
      _backgroundService.invoke(BackgroundServiceMethod.stopService);
    } catch (error) {
      debugPrint('[UI] could not stop the background service: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// First read, with a loading flag for the initial build.
  Future<void> loadNotes() async {
    _isLoading = true;
    notifyListeners();
    try {
      _allNotes = await _databaseHelper.getNotes();
    } catch (error) {
      debugPrint('[UI] loading notes failed: $error');
      _allNotes = <Note>[];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Re-reads the table without toggling the loading flag. Safe to call as often
  /// as needed: listeners are only notified when something actually changed.
  Future<void> refreshFromDatabase() async {
    try {
      _applyNotes(await _databaseHelper.getNotes());
    } catch (error) {
      debugPrint('[UI] refreshing notes failed: $error');
    }
  }

  /// A single note straight from the database (used by the editor).
  Future<Note?> getNoteById(int id) => _databaseHelper.getNoteById(id);

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Inserts or updates [note] depending on whether it already has an id.
  ///
  /// Returns the note exactly as it was persisted - including the id SQLite
  /// assigned and the fresh `updatedAt` - or `null` when the write failed.
  /// Callers (the editor) use the returned instance to stay in sync, so a later
  /// save in the same session updates that row instead of inserting a second
  /// copy of it.
  Future<Note?> saveNote(Note note) async {
    final String updatedAt = DateFormatter.formatForStorage(DateTime.now());
    final Note stamped = note.copyWith(updatedAt: updatedAt);

    try {
      if (stamped.id == null) {
        final int id = await _databaseHelper.insertNote(stamped);
        await refreshFromDatabase();
        if (id <= 0) {
          return null;
        }
        return stamped.copyWith(id: id);
      }

      final int rows = await _databaseHelper.updateNote(stamped);
      await refreshFromDatabase();
      return rows > 0 ? stamped : null;
    } catch (error) {
      debugPrint('[UI] saving note failed: $error');
      return null;
    }
  }

  /// Creates an empty note and returns its new id.
  Future<int> createNote({String title = '', String content = ''}) async {
    final int id = await _databaseHelper.insertNote(
      Note(
        title: title,
        content: content,
        updatedAt: DateFormatter.formatForStorage(DateTime.now()),
      ),
    );
    await refreshFromDatabase();
    return id;
  }

  /// Deletes [id]. The tracked note is protected because the background service
  /// keeps writing into it.
  Future<bool> deleteNote(int id) async {
    if (id == Note.fixedNoteId) {
      debugPrint('[UI] the tracked note is owned by the background service');
      return false;
    }
    try {
      final int rows = await _databaseHelper.deleteNote(id);
      await refreshFromDatabase();
      return rows > 0;
    } catch (error) {
      debugPrint('[UI] deleting note $id failed: $error');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  /// Applies the search query used by [notes].
  void setSearchQuery(String query) {
    if (_searchQuery == query) {
      return;
    }
    _searchQuery = query;
    notifyListeners();
  }

  /// Clears the search query.
  void clearSearchQuery() {
    if (_searchQuery.isEmpty) {
      return;
    }
    _searchQuery = '';
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Swaps in [notes] and notifies listeners only when the list really changed,
  /// which keeps the 30 second safety-net poll from rebuilding for nothing.
  void _applyNotes(List<Note> notes) {
    if (listEquals(_allNotes, notes)) {
      return;
    }
    _allNotes = notes;
    notifyListeners();
  }

  @override
  void dispose() {
    _safetyNetTimer?.cancel();
    _safetyNetTimer = null;
    unawaited(_serviceSubscription?.cancel());
    _serviceSubscription = null;
    try {
      if (_syncStarted) {
        WidgetsBinding.instance.removeObserver(this);
      }
    } catch (error) {
      debugPrint('[UI] removeObserver failed: $error');
    }
    super.dispose();
  }
}
