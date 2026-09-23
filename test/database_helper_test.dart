import 'package:flutter_test/flutter_test.dart';
import 'package:notepad_app/database/database_helper.dart';
import 'package:notepad_app/models/note.dart';
import 'package:notepad_app/utils/date_formatter.dart';
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
}
