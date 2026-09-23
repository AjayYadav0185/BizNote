import 'package:flutter_test/flutter_test.dart';
import 'package:BizNote/database/database_helper.dart';
import 'package:BizNote/models/note.dart';
import 'package:BizNote/utils/date_formatter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression tests for the "new notes cannot be saved" bug.
///
/// The background location service runs in its own isolate. Its connection used
/// to be opened with sqflite's default `singleInstance: true`, but that registry
/// lives in the **native** plugin and is therefore shared by every Flutter
/// engine of the process: the service received the very same handle as the UI
/// isolate and closed it at the end of each cycle. From that moment on the UI
/// kept using a dead handle and every read/write failed with
/// `database_closed <id>` - saving a note was impossible.
void main() {
  late String databasePath;

  setUpAll(() async {
    // The same factory `DatabaseHelper.ensureInitialized` installs on desktop
    // platforms; the FFI backend also runs without platform channels.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    databasePath = await DatabaseHelper.databaseFilePath();
  });

  setUp(() async {
    await DatabaseHelper.instance.close();
    await databaseFactory.deleteDatabase(databasePath);
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
    await databaseFactory.deleteDatabase(databasePath);
  });

  Note groceries() => Note(
        title: 'Groceries',
        content: 'Milk and eggs',
        updatedAt: DateFormatter.formatForStorage(DateTime.now()),
      );

  test('a background write keeps the UI connection usable', () async {
    expect(
      await DatabaseHelper.instance.insertNote(groceries()),
      greaterThan(0),
    );

    final Database uiConnection = await DatabaseHelper.instance.database;
    expect(uiConnection.isOpen, isTrue);

    // What one background cycle does: open an isolated connection, write the
    // tracked note and close the connection again.
    final int rows = await DatabaseHelper.updateFixedNoteFromBackground(
      content: 'Last Status: Active',
      updatedAt: DateFormatter.formatForStorage(DateTime.now()),
    );
    expect(rows, 1);

    // The private connection is gone, the UI connection must not be.
    expect(uiConnection.isOpen, isTrue);

    final Note? tracker =
        await DatabaseHelper.instance.getNoteById(Note.fixedNoteId);
    expect(tracker?.content, 'Last Status: Active');

    // And the user can still save notes right after a background cycle.
    expect(await DatabaseHelper.instance.getNoteCount(), 2);
    expect(
      await DatabaseHelper.instance.insertNote(groceries()),
      greaterThan(0),
    );
    final List<Note> notes = await DatabaseHelper.instance.getNotes();
    expect(notes.length, 3);
  });

  test('the background connection is a private instance', () async {
    final Database uiConnection = await DatabaseHelper.instance.database;
    final Database backgroundConnection =
        await DatabaseHelper.openIsolatedConnection(singleInstance: false);

    // Same path, different handle: closing one cannot affect the other.
    expect(identical(uiConnection, backgroundConnection), isFalse);

    await backgroundConnection.close();
    expect(uiConnection.isOpen, isTrue);
    expect(await DatabaseHelper.instance.getNoteCount(), 1);
  });

  test('queries recover when the cached connection was closed underneath',
      () async {
    final Database uiConnection = await DatabaseHelper.instance.database;

    // A close the helper never hears about, exactly what a shared native handle
    // used to look like from the UI isolate's point of view.
    await uiConnection.close();

    final List<Note> notes = await DatabaseHelper.instance.getNotes();
    expect(notes, isNotEmpty); // the seeded tracker note

    expect(
      await DatabaseHelper.instance.insertNote(groceries()),
      greaterThan(0),
    );
    expect(await DatabaseHelper.instance.getNoteCount(), notes.length + 1);
  });

  // ---------------------------------------------------------------------------
  // Manual ordering (drag to reorder)
  // ---------------------------------------------------------------------------

  test('a new note lands on top of a hand ordered list', () async {
    final int first = await DatabaseHelper.instance.insertNote(groceries());
    final int second = await DatabaseHelper.instance.insertNote(groceries());

    final List<Note> notes = await DatabaseHelper.instance.getNotes();

    expect(
      notes.map((Note note) => note.id).toList(),
      <int>[second, first, Note.fixedNoteId],
    );
  });

  test('updateNoteOrder rewrites the whole list and survives a reload',
      () async {
    final int first = await DatabaseHelper.instance.insertNote(groceries());
    final int second = await DatabaseHelper.instance.insertNote(groceries());

    await DatabaseHelper.instance.updateNoteOrder(
      <int>[Note.fixedNoteId, second, first],
    );

    final List<Note> notes = await DatabaseHelper.instance.getNotes();
    expect(
      notes.map((Note note) => note.id).toList(),
      <int>[Note.fixedNoteId, second, first],
    );
    // The numbering is dense and starts at 0, so a second reorder - or a plain
    // reload - cannot drift.
    expect(
      notes.map((Note note) => note.sortOrder).toList(),
      <int>[0, 1, 2],
    );
  });

  test('editing a note keeps the position the user dropped it at', () async {
    final int first = await DatabaseHelper.instance.insertNote(groceries());
    final int second = await DatabaseHelper.instance.insertNote(groceries());
    await DatabaseHelper.instance.updateNoteOrder(
      <int>[first, second, Note.fixedNoteId],
    );

    final Note? stored = await DatabaseHelper.instance.getNoteById(first);
    await DatabaseHelper.instance.updateNote(
      stored!.copyWith(title: 'Renamed', content: 'edited'),
    );

    final List<Note> notes = await DatabaseHelper.instance.getNotes();
    expect(
      notes.map((Note note) => note.id).toList(),
      <int>[first, second, Note.fixedNoteId],
    );
    expect(notes.first.title, 'Renamed');
    expect(notes.first.content, 'edited');
  });

  test('a version 1 database is upgraded in place, keeping the list order',
      () async {
    // Recreate the file exactly as the pre-reorder build left it, which is what
    // an install looks like right before this build is dropped on top of it.
    await DatabaseHelper.instance.close();
    await databaseFactory.deleteDatabase(databasePath);

    final Database legacy = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (Database db, int version) async {
          await db.execute('''
            CREATE TABLE notes (
              id INTEGER PRIMARY KEY,
              title TEXT NOT NULL,
              content TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacy.insert('notes', <String, Object?>{
      'id': 2,
      'title': 'Older',
      'content': 'second',
      'updatedAt': '2026-09-01 08:00:00',
    });
    await legacy.insert('notes', <String, Object?>{
      'id': 3,
      'title': 'Newer',
      'content': 'first',
      'updatedAt': '2026-09-20 08:00:00',
    });
    await legacy.close();

    // Opening through the helper runs `_onUpgrade` / `_ensureSchema`.
    final List<Note> notes = await DatabaseHelper.instance.getNotes();

    // The tracker note was missing and is seeded on top, then the two legacy
    // notes in the order the list showed them before the upgrade: newest first.
    expect(
      notes.map((Note note) => note.id).toList(),
      <int>[Note.fixedNoteId, 3, 2],
    );
    expect(notes.map((Note note) => note.title).toList(),
        <String>[Note.fixedNoteTitle, 'Newer', 'Older']);
    expect(await DatabaseHelper.instance.getNoteCount(), 3);
  });
}
