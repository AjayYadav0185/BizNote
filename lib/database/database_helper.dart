import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart' as web;

import '../models/note.dart';
import '../utils/date_formatter.dart';

/// Offline SQLite storage for [Note]s (`notepad.db`).
///
/// The file is touched by two isolates:
///  * the UI isolate, which reuses the cached [instance] connection, and
///  * the background service isolate, which opens its own short lived
///    connection through [updateFixedNoteFromBackground].
///
/// Static fields are **not** shared between isolates, so the background task
/// must never reuse the UI connection: [withIsolatedConnection] gives it a
/// private connection that is opened and closed around a single write.
class DatabaseHelper {
  static const String _databaseName = 'notepad.db';
  static const int _databaseVersion = 1;
  static const String _tableName = Note.tableName;

  static Database? _database;
  static bool _factoryInitialized = false;

  /// Must be called once from `main()` before any database access.
  ///
  /// Plain `sqflite` only works on Android/iOS (method channels). On
  /// macOS/Windows/Linux we switch the global `databaseFactory` to
  /// `sqflite_common_ffi`, and on web to `sqflite_ffi_web`. Without this,
  /// every `openDatabase`/`getDatabasesPath` call throws
  /// `MissingPluginException`, which is exactly why "save does nothing and
  /// the list stays empty" when the app is run on desktop/Chrome.
  static Future<void> ensureInitialized() async {
    if (_factoryInitialized) {
      return;
    }
    _factoryInitialized = true;
    if (kIsWeb) {
      databaseFactory = web.databaseFactoryFfiWeb;
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.windows:
        case TargetPlatform.linux:
        case TargetPlatform.macOS:
          ffi.sqfliteFfiInit();
          databaseFactory = ffi.databaseFactoryFfi;
          break;
        case TargetPlatform.android:
        case TargetPlatform.iOS:
        case TargetPlatform.fuchsia:
          break;
      }
    }
    // Android/iOS keep the default method-channel factory.
  }

  /// Private constructor: use [instance] (UI isolate) or the static helpers
  /// (background isolate).
  DatabaseHelper._();

  /// Singleton used by the presentation layer.
  static final DatabaseHelper instance = DatabaseHelper._();

  /// Cached connection of the current isolate.
  ///
  /// A handle that is not open any more is dropped and reopened instead of
  /// being handed out again: a stale handle makes every later query fail with
  /// `database_closed`. Use [_withDatabase] for the actual queries, because a
  /// close that happened on the **native** side is invisible to [Database.isOpen]
  /// and only shows up as an error.
  Future<Database> get database async {
    final Database? cached = _database;
    if (cached != null && cached.isOpen) {
      return cached;
    }
    return _database = await openIsolatedConnection();
  }

  /// Runs [action] on the cached connection and heals that connection once when
  /// it turns out to be closed.
  ///
  /// Two isolates inside the same process can end up with one native database
  /// handle (`sqflite`'s "single instance" registry is process wide), so a close
  /// that happened "somewhere else" surfaces as a `database_closed` error
  /// rather than as a Dart side closed flag. Dropping the cached handle and
  /// reopening it is what keeps saving notes working after such an event.
  Future<T> _withDatabase<T>(Future<T> Function(Database db) action) async {
    Database db = await database;
    try {
      return await action(db);
    } catch (error) {
      if (error is! DatabaseException || !error.isDatabaseClosedError()) {
        rethrow;
      }
      debugPrint('[DB] cached connection was closed; reopening it');
      _database = null;
      db = await database;
      return await action(db);
    }
  }

  /// Absolute path of the database file, e.g.
  /// `/data/data/com.biznote.notepad_app/databases/notepad.db`.
  static Future<String> databaseFilePath() async =>
      join(await getDatabasesPath(), _databaseName);

  /// Opens a brand new, **uncached** connection with the full schema hooks
  /// attached, so even the very first background write creates the table and
  /// seeds the fixed note when the UI never ran before.
  ///
  /// [singleInstance] maps straight onto sqflite's `singleInstance` flag.
  /// The UI isolate uses the default (`true`: one handle shared by every call
  /// of this isolate); **every other isolate must pass `false`**, because
  /// sqflite's "single instance" registry lives in the native plugin and is
  /// therefore shared by all Flutter engines in the same process. A background
  /// connection opened with the default receives the very same handle as the UI
  /// isolate, and closing it at the end of a background cycle tears the UI
  /// connection down as well: every later save then fails with
  /// `database_closed <id>`.
  static Future<Database> openIsolatedConnection({
    bool singleInstance = true,
  }) async {
    return openDatabase(
      await databaseFilePath(),
      version: _databaseVersion,
      singleInstance: singleInstance,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: _onOpen,
    );
  }

  /// Runs [action] on a dedicated connection and always closes it, even when
  /// [action] throws.
  ///
  /// The connection is opened with `singleInstance: false` on purpose: closing
  /// it must never close the handle the UI isolate caches (see
  /// [openIsolatedConnection]).
  static Future<T> withIsolatedConnection<T>(
    Future<T> Function(Database db) action,
  ) async {
    final Database db = await openIsolatedConnection(singleInstance: false);
    try {
      return await action(db);
    } finally {
      await db.close();
    }
  }

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    // The UI isolate and the background service write through two different
    // connections now, so a blocked writer waits for the lock instead of
    // failing the user's save right away.
    await _applyPragma(db, 'PRAGMA busy_timeout = 4000');
    // WAL keeps a background write from blocking the UI (and the other way
    // around). Best effort: some platforms (the web VFS, hardened Android
    // builds) cannot switch the journal mode at runtime.
    await _applyPragma(db, 'PRAGMA journal_mode = WAL');
  }

  /// Runs one `PRAGMA` through [Database.rawQuery], which - unlike `execute` -
  /// works on Android for statements that return a row (like `journal_mode`).
  /// Failures are logged only: a pragma is a tuning knob, never a reason to
  /// leave the app without a database.
  static Future<void> _applyPragma(Database db, String pragma) async {
    try {
      await db.rawQuery(pragma);
    } catch (error) {
      debugPrint('[DB] "$pragma" skipped: $error');
    }
  }

  /// Creates the `notes` table and seeds the fixed tracker note.
  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tableName (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )
    ''');
    await _seedFixedNote(db);
  }

  /// Migration hook. The fixed note is re-verified in [_onOpen] afterwards.
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // No migrations yet: version 1 is the first schema that ships with the
    // background location tracker.
  }

  /// Runs after `onCreate`/`onUpgrade` and on every plain `openDatabase()` call,
  /// which makes it the safest place to guarantee the fixed note exists.
  static Future<void> _onOpen(Database db) async {
    await _migrateLegacyTimestampColumn(db);
    await _seedFixedNote(db);
  }

  /// Renames the legacy `date` column (pre-tracker schema) to `updatedAt` so
  /// existing installs keep their notes instead of crashing on the new column.
  static Future<void> _migrateLegacyTimestampColumn(Database db) async {
    try {
      final List<Map<String, Object?>> columns =
          await db.rawQuery('PRAGMA table_info($_tableName)');
      if (columns.isEmpty) {
        await _onCreate(db, _databaseVersion);
        return;
      }
      final Set<Object?> columnNames =
          columns.map((Map<String, Object?> column) => column['name']).toSet();
      if (columnNames.contains('date') && !columnNames.contains('updatedAt')) {
        await db.execute(
          'ALTER TABLE $_tableName RENAME COLUMN date TO updatedAt',
        );
        debugPrint('[DB] migrated legacy "date" column to "updatedAt"');
      }
    } catch (error) {
      debugPrint('[DB] legacy column migration skipped: $error');
    }
  }

  /// Seeds the fixed note (`id = 1`) exactly once: the insert is skipped when a
  /// note with [Note.fixedNoteId] already exists.
  static Future<void> _seedFixedNote(Database db) async {
    final List<Map<String, Object?>> existing = await db.query(
      _tableName,
      columns: const <String>['id'],
      where: 'id = ?',
      whereArgs: const <Object?>[Note.fixedNoteId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return;
    }

    await db.insert(
      _tableName,
      <String, dynamic>{
        'id': Note.fixedNoteId,
        'title': Note.fixedNoteTitle,
        'content': Note.fixedNotePlaceholder,
        'updatedAt': DateFormatter.formatForStorage(DateTime.now()),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    debugPrint('[DB] seeded the fixed note (id = ${Note.fixedNoteId})');
  }

  /// Returns the fixed note, creating it first when it was deleted by hand or
  /// when the row is missing for any other reason.
  static Future<void> ensureFixedNoteExists() => withIsolatedConnection(
        (Database db) => _seedFixedNote(db),
      );

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// All notes, most recently edited first. The tracker note therefore floats to
  /// the top of the list right after every background update.
  Future<List<Note>> getNotes() async {
    final List<Map<String, Object?>> rows = await _withDatabase(
      (Database db) => db.query(_tableName, orderBy: 'updatedAt DESC'),
    );
    return rows.map((Map<String, Object?> row) => Note.fromMap(row)).toList();
  }

  /// A single note, or `null` when it does not exist anymore.
  Future<Note?> getNoteById(int id) async {
    final List<Map<String, Object?>> rows = await _withDatabase(
      (Database db) => db.query(
        _tableName,
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      ),
    );
    if (rows.isEmpty) {
      return null;
    }
    return Note.fromMap(rows.first);
  }

  /// Number of rows in the `notes` table.
  Future<int> getNoteCount() async {
    final List<Map<String, Object?>> result = await _withDatabase(
      (Database db) => db.rawQuery('SELECT COUNT(*) AS count FROM $_tableName'),
    );
    return (result.first['count'] as int?) ?? 0;
  }

  /// Case insensitive search across the title and the body.
  Future<List<Note>> searchNotes(String query) async {
    final List<Map<String, Object?>> rows = await _withDatabase(
      (Database db) => db.query(
        _tableName,
        where: 'title LIKE ? OR content LIKE ?',
        whereArgs: <Object?>['%$query%', '%$query%'],
        orderBy: 'updatedAt DESC',
      ),
    );
    return rows.map((Map<String, Object?> row) => Note.fromMap(row)).toList();
  }

  // ---------------------------------------------------------------------------
  // Writes (UI isolate)
  // ---------------------------------------------------------------------------

  /// Inserts [note] and returns the new primary key.
  Future<int> insertNote(Note note) {
    return _withDatabase(
      (Database db) => db.insert(
        _tableName,
        note.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      ),
    );
  }

  /// Writes every user editable field of [note]. Returns the number of affected
  /// rows (`1` on success, `0` when the row no longer exists).
  Future<int> updateNote(Note note) {
    final int? id = note.id;
    if (id == null) {
      throw ArgumentError('Cannot update a note without an id: $note');
    }
    return _withDatabase(
      (Database db) => db.update(
        _tableName,
        note.toMap(),
        where: 'id = ?',
        whereArgs: <Object?>[id],
      ),
    );
  }

  /// Deletes [id]. Returns the number of affected rows.
  Future<int> deleteNote(int id) {
    return _withDatabase(
      (Database db) => db.delete(
        _tableName,
        where: 'id = ?',
        whereArgs: <Object?>[id],
      ),
    );
  }

  /// Empties the notebook but always keeps the tracked note, so the background
  /// service never ends up writing into a deleted row.
  Future<int> deleteAllNotes() {
    return _withDatabase(
      (Database db) => db.delete(
        _tableName,
        where: 'id != ?',
        whereArgs: <Object?>[Note.fixedNoteId],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Writes (background isolate)
  // ---------------------------------------------------------------------------

  /// Overwrites **only** `content` and `updatedAt` of the fixed note.
  ///
  /// This is the query executed by the 15 minute background loop: the title and
  /// the primary key are never touched, and an existing `updatedAt` is replaced
  /// with [updatedAt].
  static Future<int> _updateFixedNote(
    Database db, {
    required String content,
    required String updatedAt,
    int noteId = Note.fixedNoteId,
  }) {
    return db.update(
      _tableName,
      <String, dynamic>{'content': content, 'updatedAt': updatedAt},
      where: 'id = ?',
      whereArgs: <Object?>[noteId],
    );
  }

  /// Same as [_updateFixedNote] but on the connection of the calling isolate
  /// (used by the UI isolate, e.g. for a manual refresh).
  Future<int> updateFixedNoteContent({
    required String content,
    required String updatedAt,
  }) {
    return _withDatabase(
      (Database db) =>
          _updateFixedNote(db, content: content, updatedAt: updatedAt),
    );
  }

  /// Background entry point: opens a private connection, writes the tracker note
  /// and closes the connection again.
  ///
  /// The isolated connection is intentional. The background service runs in its
  /// own isolate, so it cannot (and must not) reuse the cached connection of the
  /// UI isolate; a short lived connection also guarantees that SQLite flushes
  /// the write to disk before the isolate is allowed to be suspended.
  static Future<int> updateFixedNoteFromBackground({
    required String content,
    required String updatedAt,
  }) {
    return withIsolatedConnection(
      (Database db) => _updateFixedNote(db, content: content, updatedAt: updatedAt),
    );
  }

  /// Closes the cached connection of the current isolate.
  Future<void> close() async {
    final Database? db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  /// True when the database file already exists on disk.
  /// On web there is no file system handle, so report whether the cached
  /// connection has been opened instead. Kept for diagnostics/tests.
  Future<bool> databaseExists() async {
    if (kIsWeb) {
      return _database != null;
    }
    try {
      final String path = await databaseFilePath();
      return await databaseFactory.databaseExists(path);
    } catch (_) {
      return _database != null;
    }
  }
}
