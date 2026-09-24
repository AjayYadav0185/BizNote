import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../database/database_helper.dart';
import '../models/device_profile.dart';
import '../models/note.dart';
import '../services/background_service.dart';
import '../services/firebase_note_service.dart';
import '../utils/date_formatter.dart';
import '../utils/device_id.dart';

/// Bridges the SQLite `notes` table to the widget tree.
///
/// The background service runs in its own isolate and writes with its own
/// connection, so this notifier pulls the rows back in whenever the service
/// broadcasts an update, whenever the app is resumed, and through a slow
/// safety-net poll for the cases where the event channel is missed.
///
/// Every successful write is additionally mirrored into Firebase Realtime
/// Database through [FirebaseNoteService] (`notes/<id>`). SQLite remains the
/// source of truth and the mirror is fail-soft: an offline device or a locked
/// database rule only logs, the local save is already on disk at that point.
class NoteProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// [databaseHelper], [firebaseService] and the two flags exist for tests:
  /// production code uses the defaults (the shared singleton, the real cloud
  /// mirror and the live background service stream).
  NoteProvider({
    DatabaseHelper? databaseHelper,
    FirebaseNoteService? firebaseService,
    bool enableBackgroundSync = true,
    bool enableFirebaseSync = true,
  })  : _databaseHelper = databaseHelper ?? DatabaseHelper.instance,
        _firebaseService = firebaseService ?? const FirebaseNoteService(),
        _enableFirebaseSync = enableFirebaseSync {
    if (enableBackgroundSync) {
      unawaited(startBackgroundSync());
    }
  }

  /// Safety net poll. Cheap (one indexed `SELECT`) and only alive while the app
  /// is running; the event stream below is the primary refresh trigger.
  static const Duration _safetyNetInterval = Duration(seconds: 30);

  final DatabaseHelper _databaseHelper;
  final FirebaseNoteService _firebaseService;
  final bool _enableFirebaseSync;
  final FlutterBackgroundService _backgroundService = FlutterBackgroundService();

  List<Note> _allNotes = <Note>[];
  String _searchQuery = '';
  bool _isLoading = false;
  bool _syncStarted = false;
  DeviceProfile? _profile;
  bool _profileLoaded = false;
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

  /// The one-time setup record (device id + mobile number), or `null` while it
  /// is still being read from disk.
  DeviceProfile? get profile => _profile;

  /// True once [loadProfile] finished, so the UI can tell "no profile yet" apart
  /// from "not loaded yet".
  bool get isProfileLoaded => _profileLoaded;

  /// True when the welcome screen can be skipped: a usable mobile number is
  /// stored and travels with every Firebase write.
  bool get hasProfile => _profile?.needsPhoneNumber == false;

  // ---------------------------------------------------------------------------
  // Device profile (one-time setup)
  // ---------------------------------------------------------------------------

  /// Reads the stored profile and generates the device id on the very first
  /// launch.
  ///
  /// The id is written to disk immediately (even before a number is entered) so
  /// the app never comes back with a *different* identity after a restart.
  Future<void> loadProfile() async {
    try {
      final DeviceProfile? stored = await _databaseHelper.getProfile();
      if (stored != null) {
        _profile = stored;
      } else {
        // First launch: mint the device id and persist it right away — even
        // before a number is entered — so the identity can never change after a
        // restart. The welcome screen only adds the phone number to it.
        final DeviceProfile created = DeviceProfile(
          deviceId: DeviceId.generate(),
          phoneNumber: '',
          updatedAt: DateFormatter.formatForStorage(DateTime.now()),
        );
        await _databaseHelper.saveProfile(created);
        _profile = created;
        debugPrint('[UI] generated device id ${created.deviceId}');
      }
    } catch (error) {
      debugPrint('[UI] loading the device profile failed: $error');
    } finally {
      _profileLoaded = true;
      notifyListeners();
    }
  }

  /// One-time setup: stores the customer's mobile number next to the device id.
  ///
  /// Returns `true` when the number was stored. Existing notes are re-uploaded
  /// right after, so the records that were saved before the setup carry the
  /// identity too.
  Future<bool> savePhoneNumber(String phoneNumber) async {
    if (!DeviceProfile.isValidPhoneNumber(phoneNumber)) {
      debugPrint('[UI] refusing to store an implausible phone number');
      return false;
    }

    final DeviceProfile current = _profile ??
        DeviceProfile(
          deviceId: DeviceId.generate(),
          phoneNumber: '',
          updatedAt: DateFormatter.formatForStorage(DateTime.now()),
        );
    final DeviceProfile updated = current.withPhoneNumber(phoneNumber);

    try {
      await _databaseHelper.saveProfile(updated);
    } catch (error) {
      debugPrint('[UI] storing the mobile number failed: $error');
      return false;
    }

    _profile = updated;
    _profileLoaded = true;
    notifyListeners();
    debugPrint('[UI] mobile number saved for device ${updated.deviceId}');

    // The identity changed, so the cloud copy of the notebook has to catch up.
    unawaited(_mirrorAllNotes());
    return true;
  }

  /// Starts the database <-> service bridge. Called automatically by the
  /// constructor unless background sync was disabled; a no-op on platforms that
  /// cannot host the service (web/desktop, see
  /// [isBackgroundTrackingSupported]).
  Future<void> startBackgroundSync() async {
    if (_syncStarted || !isBackgroundTrackingSupported) {
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
        // The cycle rewrote the tracked note, so its cloud record is stale.
        unawaited(_mirrorTrackedNote());
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
    // fresh fix instead of waiting for the next 15 minute tick. The tracker
    // note may have been rewritten while the app was in the background, so its
    // cloud record is refreshed too.
    unawaited(refreshFromDatabase());
    unawaited(_mirrorTrackedNote());
    requestImmediateLocationUpdate();
  }

  /// Asks the background isolate to run a location cycle right now.
  ///
  /// Does nothing where there is no service to talk to (web/desktop).
  void requestImmediateLocationUpdate() {
    if (!isBackgroundTrackingSupported) {
      return;
    }
    try {
      _backgroundService.invoke(BackgroundServiceMethod.refreshLocation);
    } catch (error) {
      debugPrint('[UI] could not reach the background service: $error');
    }
  }

  /// Stops the persistent service (the next app launch starts it again).
  ///
  /// Does nothing where there is no service to talk to (web/desktop).
  void pauseLocationTracking() {
    if (!isBackgroundTrackingSupported) {
      return;
    }
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
  ///
  /// A successful read also uploads the whole notebook once
  /// ([syncNotesToFirebase]), which is what takes records that were written
  /// while the cloud was unreachable into Firebase. A failed read does **not**
  /// sync: an empty list is a broken connection, not an empty notebook.
  Future<void> loadNotes() async {
    _isLoading = true;
    notifyListeners();
    try {
      _allNotes = await _databaseHelper.getNotes();
      unawaited(_mirrorAllNotes());
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
  ///
  /// The stored record is mirrored to Firebase right after the local commit
  /// (fire and forget: the user never waits for the network).
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
        // Hand back the row as it was actually stored: it carries the id SQLite
        // assigned *and* the `sortOrder` the list put it at, so a later save in
        // the same session keeps the note exactly where the user sees it.
        final Note stored = _noteInMemory(id) ?? stamped.copyWith(id: id);
        unawaited(_mirrorNote(stored));
        return stored;
      }

      final int rows = await _databaseHelper.updateNote(stamped);
      await refreshFromDatabase();
      if (rows <= 0) {
        return null;
      }
      unawaited(_mirrorNote(stamped));
      return stamped;
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
    final Note? created = _noteInMemory(id);
    if (created != null) {
      unawaited(_mirrorNote(created));
    }
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
      if (rows > 0) {
        unawaited(_forgetNote(id));
      }
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
  // Ordering
  // ---------------------------------------------------------------------------

  /// Moves the note at [oldIndex] to [newIndex] in the manually ordered list.
  ///
  /// The indices are the ones `SliverReorderableList` reports through
  /// `onReorderItem`, i.e. [newIndex] is already the final slot of the note
  /// *after* it has been lifted out of the list, so no `- 1` correction is
  /// needed here.
  ///
  /// The visible list is updated first, so the row lands where the finger let
  /// go without waiting for a disk write, and the new numbering is persisted
  /// right after. A failed write is only logged: the optimistic order stays on
  /// screen until the next read pulls the stored one back in.
  Future<void> reorderNotes(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _allNotes.length) {
      return;
    }
    if (newIndex < 0 || newIndex >= _allNotes.length) {
      return;
    }
    if (oldIndex == newIndex) {
      return;
    }

    final List<Note> reordered = List<Note>.of(_allNotes);
    final Note moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);

    // Renumber locally as well: the next `refreshFromDatabase` compares the rows
    // field by field, so the list would otherwise "change back" for one frame
    // once the same values come in from SQLite.
    _allNotes = <Note>[
      for (int i = 0; i < reordered.length; i++)
        reordered[i].copyWith(sortOrder: i),
    ];
    notifyListeners();

    try {
      await _databaseHelper.updateNoteOrder(
        <int>[
          for (final Note note in _allNotes)
            if (note.id != null) note.id!,
        ],
      );
      // Every row was renumbered, so the cloud copy of each record changed.
      unawaited(_mirrorAllNotes());
    } catch (error) {
      debugPrint('[UI] persisting the new note order failed: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Firebase mirror
  // ---------------------------------------------------------------------------

  /// Uploads the whole notebook to Firebase Realtime Database (`notes/<id>`) and
  /// returns the number of records that were sent, or `null` when the sync
  /// failed (no configuration, no network, locked database rules).
  ///
  /// This is what the cloud button in the list calls. The automatic mirror after
  /// a read/save/delete uses the same service but ignores the result, because a
  /// failed cloud write must never surface as a failed save.
  Future<int?> syncNotesToFirebase() async {
    if (!_enableFirebaseSync) {
      debugPrint('[UI] the Firebase mirror is disabled');
      return null;
    }
    // Re-read first so the upload contains what is really on disk, including
    // rows the background isolate wrote since the last refresh.
    await refreshFromDatabase();
    final List<Note> notes = _allNotes;
    if (notes.isEmpty) {
      return null;
    }
    final bool pushed = await _firebaseService.syncNotes(
      notes,
      profile: await _currentProfile(),
    );
    if (!pushed) {
      return null;
    }
    return notes
        .where((Note note) => note.id != null)
        .length;
  }

  /// Pushes one record (`notes/<id>`) without blocking the caller.
  Future<void> _mirrorNote(Note note) async {
    if (!_enableFirebaseSync) {
      return;
    }
    try {
      await _firebaseService.saveNote(note, profile: await _currentProfile());
    } catch (error) {
      debugPrint('[UI] Firebase mirror of note ${note.id} failed: $error');
    }
  }

  /// Removes the cloud record of a deleted note.
  Future<void> _forgetNote(int id) async {
    if (!_enableFirebaseSync) {
      return;
    }
    try {
      await _firebaseService.deleteNote(id);
    } catch (error) {
      debugPrint('[UI] Firebase mirror could not remove note $id: $error');
    }
  }

  /// Replaces `notes` with the current notebook in one write.
  Future<void> _mirrorAllNotes() async {
    if (!_enableFirebaseSync || _allNotes.isEmpty) {
      return;
    }
    try {
      await _firebaseService.syncNotes(
        _allNotes,
        profile: await _currentProfile(),
      );
    } catch (error) {
      debugPrint('[UI] Firebase mirror of the notebook failed: $error');
    }
  }

  /// Mirrors just the tracked note, whose body the background service rewrites
  /// on every cycle.
  Future<void> _mirrorTrackedNote() async {
    if (!_enableFirebaseSync) {
      return;
    }
    try {
      final Note? tracked =
          await _databaseHelper.getNoteById(Note.fixedNoteId);
      if (tracked != null) {
        await _firebaseService.saveNote(
          tracked,
          profile: await _currentProfile(),
        );
      }
    } catch (error) {
      debugPrint('[UI] Firebase mirror of the tracked note failed: $error');
    }
  }

  /// The device id + mobile number that every Firebase write carries.
  ///
  /// Loaded lazily so a mirror triggered before the welcome screen (or by a
  /// test) still stamps the device id the app generated on first launch.
  Future<DeviceProfile?> _currentProfile() async {
    if (_profile == null) {
      await loadProfile();
    }
    return _profile;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// The cached row with [id], as it was last read from the database.
  Note? _noteInMemory(int id) {
    for (final Note note in _allNotes) {
      if (note.id == id) {
        return note;
      }
    }
    return null;
  }

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
