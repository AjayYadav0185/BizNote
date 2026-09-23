import 'package:flutter_test/flutter_test.dart';
import 'package:BizNote/models/note.dart';

void main() {
  group('Note', () {
    test('fromMap/toMap round trip keeps the four SQLite columns', () {
      final Map<String, dynamic> row = <String, dynamic>{
        'id': 7,
        'title': 'Groceries',
        'content': 'Milk\neggs',
        'updatedAt': '2026-09-23 12:20:00',
      };

      final Note note = Note.fromMap(row);

      expect(note.id, 7);
      expect(note.title, 'Groceries');
      expect(note.content, 'Milk\neggs');
      expect(note.updatedAt, '2026-09-23 12:20:00');
      expect(note.toMap(), row);
    });

    test('toMap omits the id while the note was never persisted', () {
      const Note note = Note(title: 'a', content: 'b', updatedAt: 'now');

      expect(note.toMap().containsKey('id'), isFalse);
      expect(note.toMap().keys, containsAll(<String>['title', 'content', 'updatedAt']));
    });

    test('missing columns fall back to empty strings', () {
      final Note note = Note.fromMap(<String, dynamic>{'id': 3});

      expect(note.title, isEmpty);
      expect(note.content, isEmpty);
      expect(note.updatedAt, isEmpty);
    });

    test('the tracked note is recognised by its primary key', () {
      const Note tracked = Note(id: 1, title: '', content: '', updatedAt: '');
      const Note normal = Note(id: 2, title: '', content: '', updatedAt: '');

      expect(tracked.isFixedNote, isTrue);
      expect(normal.isFixedNote, isFalse);
      expect(Note.fixedNoteId, 1);
    });

    test('displayTitle falls back to "New Note"', () {
      expect(
        const Note(title: '   ', content: '', updatedAt: '').displayTitle,
        'New Note',
      );
      expect(
        const Note(title: ' Hello ', content: '', updatedAt: '').displayTitle,
        'Hello',
      );
    });

    test('preview collapses the body into a single line', () {
      const Note note = Note(
        title: 'Tracker',
        content: 'Last Status: Active\n\nTimestamp: 23/09/2026 12:20 PM',
        updatedAt: '',
      );

      expect(
        note.preview,
        'Last Status: Active  Timestamp: 23/09/2026 12:20 PM',
      );
      expect(
        const Note(title: 'T', content: '  \n ', updatedAt: '').preview,
        'No additional text',
      );
    });

    test('copyWith only replaces the given fields', () {
      const Note note = Note(id: 1, title: 'a', content: 'b', updatedAt: 'c');
      final Note copy = note.copyWith(content: 'z');

      expect(copy.id, 1);
      expect(copy.title, 'a');
      expect(copy.content, 'z');
      expect(copy.updatedAt, 'c');
    });

    test('equality is value based', () {
      const Note a = Note(id: 1, title: 't', content: 'c', updatedAt: 'u');
      const Note b = Note(id: 1, title: 't', content: 'c', updatedAt: 'u');
      final Note c = b.copyWith(content: 'changed');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('the seeded placeholder follows the tracker payload shape', () {
      final List<String> lines = Note.fixedNotePlaceholder.split('\n');

      expect(Note.fixedNoteTitle, contains('Live Location Tracker'));
      expect(lines[0], startsWith('Last Status:'));
      expect(lines[1], startsWith('Timestamp:'));
      expect(lines[2], startsWith('Latitude:'));
      expect(lines[3], startsWith('Longitude:'));
    });

    test('sortOrder is read from the row and defaults to 0', () {
      expect(Note.fromMap(<String, dynamic>{'id': 1}).sortOrder, 0);
      expect(
        Note.fromMap(<String, dynamic>{'id': 1, 'sortOrder': -3}).sortOrder,
        -3,
      );
    });

    test('sortOrder stays out of toMap so an edit cannot reorder a note', () {
      const Note note = Note(
        id: 1,
        title: 'a',
        content: 'b',
        updatedAt: 'c',
        sortOrder: 5,
      );

      // The order is list metadata that only insert/reorder write, so the plain
      // "save the text" UPDATE can never shuffle a row the user just dropped.
      expect(note.toMap().containsKey('sortOrder'), isFalse);
    });

    test('copyWith carries the sort order over unless it is replaced', () {
      const Note note = Note(
        id: 1,
        title: 'a',
        content: 'b',
        updatedAt: 'c',
        sortOrder: 4,
      );

      expect(note.copyWith(title: 'z').sortOrder, 4);
      expect(note.copyWith(sortOrder: 9).sortOrder, 9);
    });

    test('equality takes the sort order into account', () {
      const Note a = Note(
        id: 1,
        title: 't',
        content: 'c',
        updatedAt: 'u',
        sortOrder: 0,
      );
      const Note b = Note(
        id: 1,
        title: 't',
        content: 'c',
        updatedAt: 'u',
        sortOrder: 0,
      );
      const Note c = Note(
        id: 1,
        title: 't',
        content: 'c',
        updatedAt: 'u',
        sortOrder: 1,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
