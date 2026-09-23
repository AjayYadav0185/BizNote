import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:BizNote/database/database_helper.dart';
import 'package:BizNote/models/note.dart';
import 'package:BizNote/providers/note_provider.dart';
import 'package:BizNote/screens/home_screen.dart';
import 'package:BizNote/utils/date_formatter.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

/// In-memory stand-in for the SQLite layer so the widget tests never touch a
/// platform channel. Implements the same contract the UI relies on.
class _InMemoryDatabaseHelper implements DatabaseHelper {
  _InMemoryDatabaseHelper({List<Note> seeded = const <Note>[]})
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
class _FailingReadDatabaseHelper extends _InMemoryDatabaseHelper {
  _FailingReadDatabaseHelper({super.seeded});

  @override
  Future<Note?> getNoteById(int id) async {
    throw Exception('database_closed 1');
  }
}

/// The row the real app seeds through `DatabaseHelper._seedFixedNote`.
Note _trackedNote({String status = 'Active'}) => Note(
      id: Note.fixedNoteId,
      title: Note.fixedNoteTitle,
      content: 'Last Status: $status\n'
          'Timestamp: 23/09/2026 12:20 PM\n'
          'Latitude: 12.9716\n'
          'Longitude: 77.5946',
      updatedAt: DateFormatter.formatForStorage(DateTime.now()),
    );

Widget _app(NoteProvider provider) {
  return ChangeNotifierProvider<NoteProvider>.value(
    value: provider,
    child: const CupertinoApp(home: HomeScreen()),
  );
}

void main() {
  testWidgets('home screen renders the seeded tracker note and the count',
      (WidgetTester tester) async {
    final NoteProvider provider = NoteProvider(
      databaseHelper: _InMemoryDatabaseHelper(seeded: <Note>[_trackedNote()]),
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    expect(find.text('Notes'), findsOneWidget);
    expect(find.text(Note.fixedNoteTitle), findsOneWidget);
    expect(find.textContaining('Last Status: Active'), findsOneWidget);
    expect(find.text('1 Note'), findsOneWidget);
  });

  testWidgets('home screen shows the empty state', (WidgetTester tester) async {
    final NoteProvider provider = NoteProvider(
      databaseHelper: _InMemoryDatabaseHelper(),
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    expect(find.text('No Notes'), findsOneWidget);
    expect(find.text('0 Notes'), findsOneWidget);
  });

  testWidgets('an update coming from the background service refreshes the list',
      (WidgetTester tester) async {
    final _InMemoryDatabaseHelper database = _InMemoryDatabaseHelper(
      seeded: <Note>[_trackedNote(status: 'Waiting for first location update')],
    );
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    expect(find.textContaining('Waiting for first location update'),
        findsOneWidget);

    // The background isolate writes with its own connection and then notifies
    // the provider, which is what `refreshFromDatabase` simulates here.
    await database.updateFixedNoteContent(
      content: _trackedNote(status: 'Active').content,
      updatedAt: DateFormatter.formatForStorage(DateTime.now()),
    );
    await provider.refreshFromDatabase();
    await tester.pumpAndSettle();

    expect(find.textContaining('Last Status: Active'), findsOneWidget);
  });

  testWidgets('composing a note persists it and refreshes the counter',
      (WidgetTester tester) async {
    final _InMemoryDatabaseHelper database = _InMemoryDatabaseHelper(
      seeded: <Note>[_trackedNote()],
    );
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.square_pencil));
    await tester.pumpAndSettle();

    // Editor: the title field is focused first, "Done" commits.
    expect(find.text('Done'), findsOneWidget);
    await tester.enterText(
      find.byType(CupertinoTextField).first,
      'Shopping list',
    );
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Shopping list'), findsOneWidget);
    expect(find.text('2 Notes'), findsOneWidget);
    expect(await database.getNoteCount(), 2);
  });

  testWidgets('editing an existing note writes the new body back',
      (WidgetTester tester) async {
    final _InMemoryDatabaseHelper database = _InMemoryDatabaseHelper(
      seeded: <Note>[_trackedNote()],
    );
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    await tester.tap(find.text(Note.fixedNoteTitle));
    await tester.pumpAndSettle();

    // The tracked note keeps its title, only the body changes here.
    await tester.enterText(
      find.byType(CupertinoTextField).last,
      'Manual override',
    );
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final Note? saved = await database.getNoteById(Note.fixedNoteId);
    expect(saved?.content, 'Manual override');
    expect(saved?.title, Note.fixedNoteTitle);
  });

  testWidgets('search filters the list', (WidgetTester tester) async {
    final NoteProvider provider = NoteProvider(
      databaseHelper: _InMemoryDatabaseHelper(
        seeded: <Note>[
          _trackedNote(),
          const Note(
            id: 2,
            title: 'Groceries',
            content: 'Milk and eggs',
            updatedAt: '2026-09-22 09:00:00',
          ),
        ],
      ),
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    expect(find.text('2 Notes'), findsOneWidget);

    await tester.enterText(find.byType(CupertinoSearchTextField), 'grocer');
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text(Note.fixedNoteTitle), findsNothing);
  });

  testWidgets('a failing note read shows a retry instead of an endless spinner',
      (WidgetTester tester) async {
    final NoteProvider provider = NoteProvider(
      databaseHelper:
          _FailingReadDatabaseHelper(seeded: <Note>[_trackedNote()]),
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    await tester.tap(find.text(Note.fixedNoteTitle));
    await tester.pumpAndSettle();

    // A dead connection must never leave the editor on its loading indicator:
    // that is exactly what made editing a note impossible.
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('This note could not be opened.'), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // Drag to reorder
  // ---------------------------------------------------------------------------

  List<Note> orderedNotes() => <Note>[
        const Note(
          id: 5,
          title: 'First',
          content: 'first body',
          updatedAt: '2026-09-23 10:00:00',
          sortOrder: 0,
        ),
        const Note(
          id: 6,
          title: 'Second',
          content: 'second body',
          updatedAt: '2026-09-23 09:00:00',
          sortOrder: 1,
        ),
      ];

  test('reorderNotes moves the row and persists the new order', () async {
    final _InMemoryDatabaseHelper database =
        _InMemoryDatabaseHelper(seeded: orderedNotes());
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await provider.loadNotes();
    expect(
      provider.notes.map((Note note) => note.title).toList(),
      <String>['First', 'Second'],
    );

    // Drag the last row to the top, which is what `onReorderItem` reports.
    await provider.reorderNotes(1, 0);

    expect(
      provider.notes.map((Note note) => note.title).toList(),
      <String>['Second', 'First'],
    );
    // The renumbering also kept the in-memory copy in step with the database,
    // so the next refresh does not flip the list back.
    expect(
      provider.notes.map((Note note) => note.sortOrder).toList(),
      <int>[0, 1],
    );
    expect(
      (await database.getNotes()).map((Note note) => note.title).toList(),
      <String>['Second', 'First'],
    );
  });

  testWidgets('the drag handle reorders the list', (WidgetTester tester) async {
    final _InMemoryDatabaseHelper database =
        _InMemoryDatabaseHelper(seeded: orderedNotes());
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(find.text('First')).dy,
      lessThan(tester.getCenter(find.text('Second')).dy),
    );

    // Grab the handle of the first row and drop it below the second one. The
    // handle is the only part of a row that starts a drag, so the long press
    // context menu keeps working.
    final Finder handle = find.byIcon(CupertinoIcons.line_horizontal_3).first;
    expect(handle, findsOneWidget);

    final TestGesture drag = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(find.text('Second')).dy,
      lessThan(tester.getCenter(find.text('First')).dy),
    );
    expect(
      (await database.getNotes()).map((Note note) => note.title).toList(),
      <String>['Second', 'First'],
    );
  });

  testWidgets('searching hides the drag handles', (WidgetTester tester) async {
    final NoteProvider provider = NoteProvider(
      databaseHelper: _InMemoryDatabaseHelper(seeded: orderedNotes()),
      enableBackgroundSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.line_horizontal_3), findsNWidgets(2));

    await tester.enterText(find.byType(CupertinoSearchTextField), 'first');
    await tester.pumpAndSettle();

    // Reordering a filtered subset has no meaningful result, so the rows fall
    // back to the plain, non-draggable list.
    expect(find.text('First'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.line_horizontal_3), findsNothing);
  });
}
