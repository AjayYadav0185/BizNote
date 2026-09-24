import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:BizNote/models/note.dart';
import 'package:BizNote/services/firebase_note_service.dart';

/// The `notes/<id>` object is what a dashboard (or the Firebase console) reads,
/// so its shape is a contract: it must stay JSON only and keep the millisecond
/// timestamps that make sorting cheap.
void main() {
  group('FirebaseNoteService.buildNotePayload', () {
    test('captures the stored record plus when it was pushed', () {
      const Note note = Note(
        id: 7,
        title: 'Groceries',
        content: 'Milk and eggs',
        updatedAt: '2026-09-24 12:20:00',
        sortOrder: 3,
      );

      final Map<String, dynamic> payload = FirebaseNoteService.buildNotePayload(
        note,
        timestamp: DateTime(2026, 9, 24, 12, 25),
      );

      expect(payload['id'], 7);
      expect(payload['title'], 'Groceries');
      expect(payload['content'], 'Milk and eggs');
      expect(payload['updatedAt'], '2026-09-24 12:20:00');
      expect(
        payload['updatedAtMillis'],
        DateTime(2026, 9, 24, 12, 20).millisecondsSinceEpoch,
      );
      expect(payload['sortOrder'], 3);
      expect(payload['isTracker'], false);
      expect(payload['syncedAt'], '2026-09-24 12:25:00');
      expect(
        payload['syncedAtMillis'],
        DateTime(2026, 9, 24, 12, 25).millisecondsSinceEpoch,
      );
    });

    test('flags the note the background service owns', () {
      final Map<String, dynamic> payload = FirebaseNoteService.buildNotePayload(
        const Note(
          id: Note.fixedNoteId,
          title: Note.fixedNoteTitle,
          content: 'Last Status: Active',
          updatedAt: '2026-09-24 12:20:00',
        ),
        timestamp: DateTime(2026, 9, 24, 12, 25),
      );

      expect(payload['isTracker'], true);
      expect(payload['id'], Note.fixedNoteId);
    });

    test('leaves the millisecond twin out when updatedAt is not parseable', () {
      final Map<String, dynamic> payload = FirebaseNoteService.buildNotePayload(
        const Note(id: 2, title: '', content: '', updatedAt: '--'),
      );

      expect(payload['updatedAt'], '--');
      expect(payload.containsKey('updatedAtMillis'), isFalse);
    });

    test('omits the id of a note that was never saved', () {
      final Map<String, dynamic> payload = FirebaseNoteService.buildNotePayload(
        const Note(title: 'Draft', content: '', updatedAt: '--'),
      );

      expect(payload.containsKey('id'), isFalse);
      expect(payload['title'], 'Draft');
    });

    test('produces only values the Realtime Database can encode', () {
      final Map<String, dynamic> payload = FirebaseNoteService.buildNotePayload(
        const Note(
          id: 12,
          title: 'A "quoted" title',
          content: 'Line one\nLine two',
          updatedAt: '2026-09-24 12:20:00',
          sortOrder: -1,
        ),
        timestamp: DateTime(2026, 9, 24, 12, 25),
      );

      // The Realtime Database stores JSON: jsonEncode throws on values that are
      // not plain primitives, which is exactly the contract the payload keeps.
      final String encoded = jsonEncode(payload);
      expect(encoded, contains('"id":12'));
      expect(encoded, contains('"isTracker":false'));
      expect(encoded, contains('"sortOrder":-1'));
    });
  });

  group('FirebaseNoteService.buildNotesSnapshot', () {
    test('keys every record by its note id', () {
      final Map<String, dynamic> snapshot =
          FirebaseNoteService.buildNotesSnapshot(
        <Note>[
          const Note(
            id: 1,
            title: 'First',
            content: 'a',
            updatedAt: '2026-09-24 12:20:00',
            sortOrder: 0,
          ),
          const Note(
            id: 42,
            title: 'Second',
            content: 'b',
            updatedAt: '2026-09-24 11:20:00',
            sortOrder: 1,
          ),
        ],
        timestamp: DateTime(2026, 9, 24, 12, 25),
      );

      expect(snapshot.keys.toList(), <String>['1', '42']);
      expect((snapshot['42'] as Map<String, dynamic>)['title'], 'Second');
    });

    test('stamps every record with the same sync time', () {
      final Map<String, dynamic> snapshot =
          FirebaseNoteService.buildNotesSnapshot(
        <Note>[
          const Note(id: 1, title: 'a', content: '', updatedAt: '--'),
          const Note(id: 2, title: 'b', content: '', updatedAt: '--'),
        ],
        timestamp: DateTime(2026, 9, 24, 12, 25),
      );

      expect(
        (snapshot['1'] as Map<String, dynamic>)['syncedAtMillis'],
        (snapshot['2'] as Map<String, dynamic>)['syncedAtMillis'],
      );
    });

    test('skips rows without an id: they cannot be addressed', () {
      final Map<String, dynamic> snapshot =
          FirebaseNoteService.buildNotesSnapshot(
        <Note>[
          const Note(title: 'draft', content: '', updatedAt: '--'),
          const Note(id: 3, title: 'saved', content: '', updatedAt: '--'),
        ],
      );

      expect(snapshot.keys.toList(), <String>['3']);
    });

    test('an empty notebook serialises to an empty object', () {
      // The service itself refuses to push this (see `syncNotes`): an empty
      // list means the local read failed, and pushing it would wipe the cloud
      // copy. The builder stays honest about its input.
      expect(
        FirebaseNoteService.buildNotesSnapshot(const <Note>[]),
        isEmpty,
      );
    });
  });
}
