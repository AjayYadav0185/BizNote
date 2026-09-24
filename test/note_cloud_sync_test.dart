import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:BizNote/models/device_profile.dart';
import 'package:BizNote/models/note.dart';
import 'package:BizNote/providers/note_provider.dart';
import 'package:BizNote/screens/home_screen.dart';
import 'package:BizNote/services/firebase_note_service.dart';
import 'package:BizNote/utils/date_formatter.dart';
import 'package:provider/provider.dart';

import 'support/in_memory_database_helper.dart';

/// Records what the provider hands to Firebase instead of talking to the
/// network, so the mirroring rules can be asserted without a real project.
class _RecordingFirebaseService extends FirebaseNoteService {
  _RecordingFirebaseService({this.succeeds = true});

  /// Mirrors a database rule that rejects the write (or an offline device).
  final bool succeeds;

  final List<Note> saved = <Note>[];
  final List<int> removed = <int>[];
  final List<List<Note>> snapshots = <List<Note>>[];

  @override
  Future<bool> saveNote(Note note,
      {DateTime? timestamp, DeviceProfile? profile}) async {
    saved.add(note);
    return succeeds;
  }

  @override
  Future<bool> deleteNote(int id) async {
    removed.add(id);
    return succeeds;
  }

  @override
  Future<bool> syncNotes(List<Note> notes,
      {DateTime? timestamp, DeviceProfile? profile}) async {
    snapshots.add(List<Note>.of(notes));
    return succeeds;
  }
}

/// A database whose list read fails, like a connection that was closed
/// underneath the app. Used to prove that a broken read never wipes the cloud
/// copy of the notebook.
class _UnreadableDatabaseHelper extends InMemoryDatabaseHelper {
  _UnreadableDatabaseHelper({super.seeded});

  @override
  Future<List<Note>> getNotes() async {
    throw Exception('database_closed 1');
  }
}

Note _note({int? id, String title = 'Note', String content = ''}) => Note(
      id: id,
      title: title,
      content: content,
      updatedAt: DateFormatter.formatForStorage(DateTime(2026, 9, 24, 12, 20)),
    );

/// The provider mirrors with fire-and-forget futures; give them a turn before
/// asserting on what reached the cloud.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

NoteProvider _provider(
  InMemoryDatabaseHelper database,
  _RecordingFirebaseService cloud, {
  bool enableFirebaseSync = true,
}) {
  final NoteProvider provider = NoteProvider(
    databaseHelper: database,
    firebaseService: cloud,
    enableBackgroundSync: false,
    enableFirebaseSync: enableFirebaseSync,
  );
  addTearDown(provider.dispose);
  return provider;
}

void main() {
  test('a successful read uploads the whole notebook once', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(
        seeded: <Note>[
          _note(id: 1, title: Note.fixedNoteTitle),
          _note(id: 2, title: 'Groceries'),
        ],
      ),
      cloud,
    );

    await provider.loadNotes();
    await _settle();

    expect(cloud.snapshots, hasLength(1));
    expect(
      cloud.snapshots.single.map((Note note) => note.title),
      unorderedEquals(<String>[Note.fixedNoteTitle, 'Groceries']),
    );
  });

  test('a failed read never replaces the cloud copy with nothing', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      _UnreadableDatabaseHelper(seeded: <Note>[_note(id: 1)]),
      cloud,
    );

    await provider.loadNotes();
    await _settle();

    expect(cloud.snapshots, isEmpty);
  });

  test('saving a new note mirrors the row that was stored', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(InMemoryDatabaseHelper(), cloud);
    await provider.loadNotes();
    cloud.snapshots.clear();

    final Note? stored = await provider.saveNote(
      _note(title: 'Groceries', content: 'Milk and eggs'),
    );
    await _settle();

    expect(stored, isNotNull);
    expect(cloud.saved, hasLength(1));
    final Note pushed = cloud.saved.single;
    expect(pushed.id, stored!.id);
    expect(pushed.title, 'Groceries');
    expect(pushed.content, 'Milk and eggs');
    // The fresh `updatedAt` the provider stamped is what the dashboard shows.
    expect(pushed.updatedAt, stored.updatedAt);
  });

  test('editing a note mirrors the update', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(
        seeded: <Note>[_note(id: 4, title: 'Old title', content: 'old')],
      ),
      cloud,
    );
    await provider.loadNotes();
    cloud.saved.clear();

    await provider.saveNote(_note(id: 4, title: 'New title', content: 'new'));
    await _settle();

    expect(cloud.saved, hasLength(1));
    expect(cloud.saved.single.title, 'New title');
    expect(cloud.saved.single.content, 'new');
  });

  test('creating an empty note mirrors it right away', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(InMemoryDatabaseHelper(), cloud);
    await provider.loadNotes();
    cloud.saved.clear();

    final int id = await provider.createNote();
    await _settle();

    expect(id, greaterThan(0));
    expect(cloud.saved, hasLength(1));
    expect(cloud.saved.single.id, id);
  });

  test('deleting a note removes its cloud record', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(seeded: <Note>[_note(id: 9, title: 'Throwaway')]),
      cloud,
    );
    await provider.loadNotes();

    expect(await provider.deleteNote(9), isTrue);
    await _settle();

    expect(cloud.removed, <int>[9]);
  });

  test('the tracked note is never removed from the cloud', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(
        seeded: <Note>[_note(id: Note.fixedNoteId, title: Note.fixedNoteTitle)],
      ),
      cloud,
    );
    await provider.loadNotes();

    expect(await provider.deleteNote(Note.fixedNoteId), isFalse);
    await _settle();

    expect(cloud.removed, isEmpty);
  });

  test('reordering re-uploads every record with its new sortOrder', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(
        seeded: <Note>[
          _note(id: 10, title: 'First'),
          _note(id: 11, title: 'Second'),
        ],
      ),
      cloud,
    );
    await provider.loadNotes();
    // Let the initial read's own mirror land first, then clear — otherwise the
    // (slower, profile-loading) startup sync and the reorder sync race and the
    // test sees two snapshots instead of the one the reorder produced.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cloud.snapshots.clear();

    await provider.reorderNotes(1, 0);
    // The reorder mirror is fire-and-forget on top of a lazy profile read
    // (first launch mints the device id), so let both futures land before
    // asserting — the test only cares about the mirror triggered by the
    // reorder itself.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(cloud.snapshots, hasLength(1));
    expect(
      cloud.snapshots.single.map((Note note) => note.title).toList(),
      <String>['Second', 'First'],
    );
    expect(
      cloud.snapshots.single.map((Note note) => note.sortOrder).toList(),
      <int>[0, 1],
    );
  });

  test('a rejected cloud write never fails the local save', () async {
    final _RecordingFirebaseService cloud =
        _RecordingFirebaseService(succeeds: false);
    final InMemoryDatabaseHelper database = InMemoryDatabaseHelper();
    final NoteProvider provider = _provider(database, cloud);

    final Note? stored = await provider.saveNote(_note(title: 'Offline note'));
    await _settle();

    expect(stored, isNotNull);
    expect((await database.getNotes()).single.title, 'Offline note');
  });

  test('syncNotesToFirebase reports how many records were pushed', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(
        seeded: <Note>[_note(id: 1), _note(id: 2), _note(id: 3)],
      ),
      cloud,
    );

    expect(await provider.syncNotesToFirebase(), 3);
    expect(cloud.snapshots.last, hasLength(3));
  });

  test('syncNotesToFirebase reports a failure as null', () async {
    final _RecordingFirebaseService cloud =
        _RecordingFirebaseService(succeeds: false);
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(seeded: <Note>[_note(id: 1)]),
      cloud,
    );

    expect(await provider.syncNotesToFirebase(), isNull);
  });

  test('the mirror can be switched off completely', () async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(seeded: <Note>[_note(id: 1)]),
      cloud,
      enableFirebaseSync: false,
    );

    await provider.loadNotes();
    await provider.saveNote(_note(title: 'Local only'));
    await provider.deleteNote(1);
    await _settle();

    expect(cloud.snapshots, isEmpty);
    expect(cloud.saved, isEmpty);
    expect(cloud.removed, isEmpty);
    expect(await provider.syncNotesToFirebase(), isNull);
  });

  testWidgets('the cloud button pushes the notebook and reports the result',
      (WidgetTester tester) async {
    final _RecordingFirebaseService cloud = _RecordingFirebaseService();
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(
        seeded: <Note>[
          _note(id: 1, title: Note.fixedNoteTitle),
          _note(id: 2, title: 'Groceries'),
        ],
      ),
      cloud,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<NoteProvider>.value(
        value: provider,
        child: const CupertinoApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    // The widget test renders the list, which uploads it once already.
    cloud.snapshots.clear();

    await tester.tap(find.byIcon(CupertinoIcons.cloud_upload));
    await tester.pumpAndSettle();

    expect(cloud.snapshots, hasLength(1));
    expect(cloud.snapshots.single, hasLength(2));
    expect(find.textContaining('2 notes saved'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 notes saved'), findsNothing);
  });

  testWidgets('the cloud button reports a rejected upload', (
    WidgetTester tester,
  ) async {
    final _RecordingFirebaseService cloud =
        _RecordingFirebaseService(succeeds: false);
    final NoteProvider provider = _provider(
      InMemoryDatabaseHelper(seeded: <Note>[_note(id: 1)]),
      cloud,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<NoteProvider>.value(
        value: provider,
        child: const CupertinoApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.cloud_upload));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be uploaded'), findsOneWidget);
  });
}
