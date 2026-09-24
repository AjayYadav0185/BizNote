import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart' as web;

import '../models/device_profile.dart';
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

  /// Schema version. **2** added the `sortOrder` column that backs the manual
  /// drag-to-reorder list, **3** added the single row `profile` table that holds
  /// the one-time setup (device id + mobile number). See [_ensureSchema] for the
  /// upgrade path.
  static const int _databaseVersion = 3;
  static const String _tableName = Note.tableName;
  static const String _profileTableName = DeviceProfile.tableName;

  /// Column that stores the position of a note in the reordered list.
  static const String _sortOrderColumn = 'sortOrder';

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
      // The web factory rejects `singleInstance: false` with an `ArgumentError`:
      // all its connections live in one sqlite3 (wasm) instance with a single
      // virtual file system that has no locking between connections, so two
      // handles on the same file could corrupt it. There is only one isolate on
      // the web anyway, which makes the shared instance the correct behaviour.
      singleInstance: kIsWeb ? true : singleInstance,
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
      // On the web a second instance is impossible (the factory hands back the
      // shared one), so closing here would close the connection the UI isolate
      // is using.
      if (!kIsWeb) {
        await db.close();
      }
    }
  }

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    if (kIsWeb) {
      // Only one connection exists on the web (see [openIsolatedConnection]),
      // and the wasm file system manages persistence itself, so the tuning
      // below is neither needed nor always supported there.
      return;
    }
    // The UI isolate and the background service write through two different
    // connections now, so a blocked writer waits for the lock instead of
    // failing the user's save right away.
    await _applyPragma(db, 'PRAGMA busy_timeout = 4000');
    // WAL keeps a background write from blocking the UI (and the other way
    // around). Best effort: hardened Android builds cannot always switch the
    // journal mode at runtime.
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

  /// Creates the `notes` table, the `profile` table and seeds the fixed tracker
  /// note.
  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tableName (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        $_sortOrderColumn INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await _createProfileTable(db);
    await _seedFixedNote(db);
  }

  /// The one-time setup row (device id + mobile number) lives in its own tiny
  /// table so the notes schema and the "who is this device" data stay
  /// independent. A single row is enforced by the fixed primary key the model
  /// writes.
  static Future<void> _createProfileTable(Database db) async {
    await db.execute('''
      CREATE TABLE $_profileTableName (
        id INTEGER PRIMARY KEY,
        deviceId TEXT NOT NULL,
        phoneNumber TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )
    ''');
    debugPrint('[DB] created the "$_profileTableName" table');
  }

  /// Versioned migration hook. [_onOpen] re-runs the very same check on every
  /// open, so an install whose version number was bumped without the column
  /// actually being written still heals itself.
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _ensureSchema(db);
    }
  }

  /// Runs after `onCreate`/`onUpgrade` and on every plain `openDatabase()` call,
  /// which makes it the safest place to guarantee that both the schema and the
  /// fixed note exist.
  static Future<void> _onOpen(Database db) async {
    await _ensureSchema(db);
    await _seedFixedNote(db);
  }

  /// Brings the table in line with the schema this build expects, whatever the
  /// version recorded in the file says.
  ///
  /// Runs on **every** open instead of only inside [_onUpgrade] because the
  /// schema drifted between releases faster than the version number did:
  ///  * very old installs kept the timestamp in a `date` column, and
  ///  * version 2 added `sortOrder` for the manual drag-to-reorder list.
  ///
  /// A single `PRAGMA table_info` is the cheapest way to ask SQLite what is
  /// really on disk; it reads the schema only and never touches user data.
  static Future<void> _ensureSchema(Database db) async {
    try {
      final List<Map<String, Object?>> columns =
          await db.rawQuery('PRAGMA table_info($_tableName)');
      if (columns.isEmpty) {
        // The file exists but the table does not (an interrupted install);
        // recreate it rather than leaving the app without a notebook.
        await _onCreate(db, _databaseVersion);
        return;
      }
      final Set<Object?> columnNames =
          columns.map((Map<String, Object?> column) => column['name']).toSet();

      // Renames the legacy `date` column (pre-tracker schema) to `updatedAt` so
      // existing installs keep their notes instead of crashing on the new
      // column.
      if (columnNames.contains('date') && !columnNames.contains('updatedAt')) {
        await db.execute(
          'ALTER TABLE $_tableName RENAME COLUMN date TO updatedAt',
        );
        debugPrint('[DB] migrated legacy "date" column to "updatedAt"');
      }

      if (!columnNames.contains(_sortOrderColumn)) {
        await _addSortOrderColumn(db);
      }

      // Version 3 added the one-time setup table. Checked on every open (like
      // the column above), so an install whose version number was bumped
      // without the table actually being written still heals itself.
      final List<Map<String, Object?>> profileTable = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '$_profileTableName'",
      );
      if (profileTable.isEmpty) {
        await _createProfileTable(db);
      }
    } catch (error) {
      debugPrint('[DB] schema check skipped: $error');
    }
  }

  /// Adds the version 2 `sortOrder` column and numbers the existing rows so the
  /// list looks exactly like it did before the upgrade: newest first.
  static Future<void> _addSortOrderColumn(Database db) async {
    await db.execute(
      'ALTER TABLE $_tableName '
      'ADD COLUMN $_sortOrderColumn INTEGER NOT NULL DEFAULT 0',
    );

    final List<Map<String, Object?>> rows = await db.query(
      _tableName,
      columns: <String>['id'],
      orderBy: 'updatedAt DESC',
    );
    final Batch batch = db.batch();
    for (int i = 0; i < rows.length; i++) {
      batch.update(
        _tableName,
        <String, dynamic>{_sortOrderColumn: i},
        where: 'id = ?',
        whereArgs: <Object?>[rows[i]['id']],
      );
    }
    await batch.commit(noResult: true);
    debugPrint(
      '[DB] added "$_sortOrderColumn" to $_tableName (${rows.length} rows)',
    );
  }

  /// The `sortOrder` value that puts a note on top of the list: one below the
  /// current minimum, or `0` while the table is still empty.
  ///
  /// Counting downwards (instead of renumbering every row on each insert) keeps
  /// the write of a new note a single statement, and negative values survive
  /// the `NOT NULL`/`DEFAULT 0` column just fine.
  static Future<int> _nextTopSortOrder(Database db) async {
    final List<Map<String, Object?>> result = await db.rawQuery(
      'SELECT MIN($_sortOrderColumn) AS minOrder FROM $_tableName',
    );
    final int? minOrder = result.first['minOrder'] as int?;
    return (minOrder ?? 1) - 1;
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
        // Seeded like any other new note: on top of whatever is already there.
        _sortOrderColumn: await _nextTopSortOrder(db),
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

  /// All notes in the order the user arranged them by hand.
  ///
  /// `sortOrder` leads, so a drag sticks across restarts and a background write
  /// to the tracker note no longer floats that row to the top; `updatedAt DESC`
  /// is the tie breaker, which also reproduces the old "newest first" list for
  /// any rows that still share an order (a fresh, never reordered install, or a
  /// row that was inserted while an older build was running).
  Future<List<Note>> getNotes() async {
    final List<Map<String, Object?>> rows = await _withDatabase(
      (Database db) => db.query(
        _tableName,
        orderBy: '$_sortOrderColumn ASC, updatedAt DESC',
      ),
    );
    return rows.map((Map<String, Object?> row) => Note.fromMap(row)).toList();
  }

  /// The one-time setup row, or `null` before the customer ever entered a
  /// mobile number.
  Future<DeviceProfile?> getProfile() => _withDatabase(_readProfile);

  /// Same read on a private connection, used by the background service isolate
  /// so a cycle can stamp `deviceId` + `phoneNumber` onto every Firebase write.
  static Future<DeviceProfile?> profileFromBackground() =>
      withIsolatedConnection(_readProfile);

  /// Stores (or replaces) the single profile row.
  Future<int> saveProfile(DeviceProfile profile) =>
      _withDatabase((Database db) => _upsertProfile(db, profile));

  static Future<DeviceProfile?> _readProfile(Database db) async {
    final List<Map<String, Object?>> rows = await db.query(
      _profileTableName,
      where: 'id = ?',
      whereArgs: const <Object?>[DeviceProfile.fixedRowId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return DeviceProfile.fromMap(rows.first);
  }

  static Future<int> _upsertProfile(Database db, DeviceProfile profile) {
    return db.insert(
      _profileTableName,
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
        orderBy: '$_sortOrderColumn ASC, updatedAt DESC',
      ),
    );
    return rows.map((Map<String, Object?> row) => Note.fromMap(row)).toList();
  }

  // ---------------------------------------------------------------------------
  // Writes (UI isolate)
  // ---------------------------------------------------------------------------

  /// Inserts [note] and returns the new primary key.
  ///
  /// A brand new note always lands **on top** of the list, like the iPhone
  /// Notes app: its order is computed as one below the smallest value currently
  /// in the table, instead of the `0` default of [Note] (which would otherwise
  /// drop the note into the middle of a hand ordered list).
  Future<int> insertNote(Note note) {
    return _withDatabase((Database db) async {
      final Map<String, dynamic> row = note.toMap();
      row[_sortOrderColumn] = await _nextTopSortOrder(db);
      return db.insert(
        _tableName,
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Writes every user editable field of [note]. Returns the number of affected
  /// rows (`1` on success, `0` when the row no longer exists).
  ///
  /// The manual order is deliberately left alone here: `toMap` does not carry
  /// [Note.sortOrder], so editing a note never moves it in the list. Dragging a
  /// row is the only thing that renumbers it, through [updateNoteOrder].
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

  /// Persists [orderedIds] as the manual list order: the first id becomes
  /// `sortOrder` 0, the second 1, and so on.
  ///
  /// The renumbering runs as one batch so a drop either writes the complete new
  /// order or nothing at all - a half applied order would make the list jump
  /// around on the next read. Ids that are not in [orderedIds] keep their
  /// previous value, which makes a partial list harmless rather than corrupting
  /// the numbering with gaps.
  Future<void> updateNoteOrder(List<int> orderedIds) {
    if (orderedIds.isEmpty) {
      return Future<void>.value();
    }
    return _withDatabase((Database db) async {
      final Batch batch = db.batch();
      for (int i = 0; i < orderedIds.length; i++) {
        batch.update(
          _tableName,
          <String, dynamic>{_sortOrderColumn: i},
          where: 'id = ?',
          whereArgs: <Object?>[orderedIds[i]],
        );
      }
      await batch.commit(noResult: true);
    });
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
