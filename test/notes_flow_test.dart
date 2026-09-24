import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:BizNote/models/note.dart';
import 'package:BizNote/providers/note_provider.dart';
import 'package:BizNote/screens/home_screen.dart';
import 'package:BizNote/utils/date_formatter.dart';
import 'package:provider/provider.dart';

import 'support/in_memory_database_helper.dart';

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
      databaseHelper: InMemoryDatabaseHelper(seeded: <Note>[_trackedNote()]),
      enableBackgroundSync: false,
      enableFirebaseSync: false,
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
      databaseHelper: InMemoryDatabaseHelper(),
      enableBackgroundSync: false,
      enableFirebaseSync: false,
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    expect(find.text('No Notes'), findsOneWidget);
    expect(find.text('0 Notes'), findsOneWidget);
  });

  testWidgets('an update coming from the background service refreshes the list',
      (WidgetTester tester) async {
    final InMemoryDatabaseHelper database = InMemoryDatabaseHelper(
      seeded: <Note>[_trackedNote(status: 'Waiting for first location update')],
    );
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
      enableFirebaseSync: false,
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
    final InMemoryDatabaseHelper database = InMemoryDatabaseHelper(
      seeded: <Note>[_trackedNote()],
    );
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
      enableFirebaseSync: false,
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
    final InMemoryDatabaseHelper database = InMemoryDatabaseHelper(
      seeded: <Note>[_trackedNote()],
    );
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
      enableFirebaseSync: false,
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
      databaseHelper: InMemoryDatabaseHelper(
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
      enableFirebaseSync: false,
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
          FailingReadDatabaseHelper(seeded: <Note>[_trackedNote()]),
      enableBackgroundSync: false,
      enableFirebaseSync: false,
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
    final InMemoryDatabaseHelper database =
        InMemoryDatabaseHelper(seeded: orderedNotes());
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
      enableFirebaseSync: false,
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
    final InMemoryDatabaseHelper database =
        InMemoryDatabaseHelper(seeded: orderedNotes());
    final NoteProvider provider = NoteProvider(
      databaseHelper: database,
      enableBackgroundSync: false,
      enableFirebaseSync: false,
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
      databaseHelper: InMemoryDatabaseHelper(seeded: orderedNotes()),
      enableBackgroundSync: false,
      enableFirebaseSync: false,
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
