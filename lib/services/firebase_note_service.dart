import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/note.dart';
import '../models/device_profile.dart';
import '../utils/date_formatter.dart';
import 'firebase_bootstrap.dart';

/// Mirrors the local notebook into Firebase Realtime Database.
///
/// SQLite stays the source of truth (the app has to work offline); this service
/// is a one-way copy that makes every record readable from the Firebase console
/// or a dashboard without the phone:
///
/// ```
/// notes/
///   <note id>/              <- one object per record, overwritten on every save
///     id, title, content, updatedAt, updatedAtMillis,
///     sortOrder, isTracker, syncedAt, syncedAtMillis,
///     deviceId, phoneNumber       <- from the one-time welcome setup
/// ```
///
/// The note id is the primary key of the local `notes` table, so a record maps
/// 1:1 to the row the user sees in the list. [syncNotes] replaces the whole
/// `notes` node in a single write, which also removes records that no longer
/// exist locally.
///
/// Everything here is **fail-soft**: a missing `google-services.json`, a locked
/// database rule or no network logs a `debugPrint` and returns `false`, never an
/// exception — saving a note locally must not depend on the cloud.
class FirebaseNoteService {
  /// Const constructor so the provider can use a `const` default and tests can
  /// subclass this service with a recording fake.
  const FirebaseNoteService();

  /// Root node of the mirrored records.
  static const String notesPath = 'notes';

  /// Upper bound for a write, so an offline device cannot stall the UI (or the
  /// location cycle) behind the network.
  static const Duration pushTimeout = Duration(seconds: 15);

  /// Firebase has to be initialized in the isolate that writes; see
  /// [FirebaseBootstrap].
  static Future<bool> ensureInitialized() =>
      FirebaseBootstrap.ensureInitialized();

  /// Writes (or overwrites) one record at `notes/<id>`. Returns `true` when the
  /// write landed. [profile] adds the one-time setup identity (`deviceId`,
  /// `phoneNumber`) to the record.
  Future<bool> saveNote(
    Note note, {
    DateTime? timestamp,
    DeviceProfile? profile,
  }) async {
    final int? id = note.id;
    if (id == null) {
      // The id is the key of the record; an unsaved note has nothing to map to.
      debugPrint('[Firebase] note without an id is not mirrored');
      return false;
    }
    if (!await ensureInitialized()) {
      return false;
    }

    try {
      await FirebaseDatabase.instance
          .ref('$notesPath/$id')
          .set(buildNotePayload(note, timestamp: timestamp, profile: profile))
          .timeout(pushTimeout);
      debugPrint('[Firebase] note $id pushed');
      return true;
    } catch (error) {
      debugPrint('[Firebase] pushing note $id failed: $error');
      return false;
    }
  }

  /// Removes `notes/<id>` after the row was deleted locally.
  Future<bool> deleteNote(int id) async {
    if (!await ensureInitialized()) {
      return false;
    }

    try {
      await FirebaseDatabase.instance
          .ref('$notesPath/$id')
          .remove()
          .timeout(pushTimeout);
      debugPrint('[Firebase] note $id removed');
      return true;
    } catch (error) {
      debugPrint('[Firebase] removing note $id failed: $error');
      return false;
    }
  }

  /// Replaces the whole `notes` node with [notes] in one write.
  ///
  /// Used after a read (so an existing notebook is uploaded once), after a
  /// reorder (every `sortOrder` changed) and by the manual sync action. A full
  /// `set` is intentional: it prunes records that were deleted locally while
  /// the app was offline instead of leaving ghosts behind.
  Future<bool> syncNotes(
    List<Note> notes, {
    DateTime? timestamp,
    DeviceProfile? profile,
  }) async {
    if (notes.isEmpty) {
      // The tracker note is seeded on every database open, so an empty list
      // means "the local read failed", not "the user deleted everything".
      // Pushing it would wipe the cloud copy of the notebook.
      debugPrint('[Firebase] refusing to replace the cloud copy with nothing');
      return false;
    }
    if (!await ensureInitialized()) {
      return false;
    }

    try {
      await FirebaseDatabase.instance
          .ref(notesPath)
          .set(buildNotesSnapshot(notes, timestamp: timestamp, profile: profile))
          .timeout(pushTimeout);
      debugPrint('[Firebase] ${notes.length} notes pushed');
      return true;
    } catch (error) {
      debugPrint('[Firebase] pushing the notebook failed: $error');
      return false;
    }
  }

  /// Builds the object stored at `notes/<id>`.
  ///
  /// Pure and synchronous (like the payload builder of the location service) so
  /// it can be unit tested without Firebase. [timestamp] defaults to
  /// `DateTime.now()` and is the moment the record was pushed, which is what
  /// makes a stale mirror visible from the dashboard; [profile] adds the
  /// one-time setup identity to the record.
  static Map<String, dynamic> buildNotePayload(
    Note note, {
    DateTime? timestamp,
    DeviceProfile? profile,
  }) {
    final int? id = note.id;
    final DateTime moment = timestamp ?? DateTime.now();
    // `updatedAt` is stored as a `yyyy-MM-dd HH:mm:ss` string so the SQL list
    // stays chronological; the millisecond twin makes sorting easy on the
    // Firebase side. A legacy/hand edited value simply leaves the twin out.
    final DateTime? storedAt = DateFormatter.parseFromStorage(note.updatedAt);

    return <String, dynamic>{
      if (id != null) 'id': id,
      'title': note.title,
      'content': note.content,
      'updatedAt': note.updatedAt,
      if (storedAt != null) 'updatedAtMillis': storedAt.millisecondsSinceEpoch,
      'sortOrder': note.sortOrder,
      'isTracker': note.isFixedNote,
      'syncedAt': DateFormatter.formatForStorage(moment),
      'syncedAtMillis': moment.millisecondsSinceEpoch,
      ...identityFields(profile),
    };
  }

  /// The `deviceId` / `phoneNumber` pair copied into every payload.
  ///
  /// Shared by this service and the location service so both nodes of the
  /// database are attributable to the same device and customer. Empty values
  /// are omitted rather than written as `null`, which keeps a payload without a
  /// profile (first launch, before the welcome screen) byte-identical to what
  /// the app sent before the setup existed.
  static Map<String, dynamic> identityFields(DeviceProfile? profile) {
    if (profile == null) {
      return const <String, dynamic>{};
    }
    return <String, dynamic>{
      if (profile.deviceId.isNotEmpty) 'deviceId': profile.deviceId,
      if (profile.phoneNumber.isNotEmpty) 'phoneNumber': profile.phoneNumber,
    };
  }

  /// Builds the whole `notes` node: a map of `'<id>': payload` for every saved
  /// note. Rows without an id cannot be addressed and are skipped.
  static Map<String, dynamic> buildNotesSnapshot(
    List<Note> notes, {
    DateTime? timestamp,
    DeviceProfile? profile,
  }) {
    final DateTime moment = timestamp ?? DateTime.now();
    return <String, dynamic>{
      for (final Note note in notes)
        if (note.id != null)
          '${note.id}':
              buildNotePayload(note, timestamp: moment, profile: profile),
    };
  }
}
