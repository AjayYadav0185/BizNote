# BizNote (notepad_app)

An offline, iOS-style notes app built with Flutter. Notes live in a local SQLite
database (`notepad.db`). The list can be reordered by dragging a row's handle,
and the order is stored in the database. On Android/iOS a persistent background
service keeps a single "📍 Live Location Tracker" note up to date every 15
minutes, even while the app is closed.

## Running

```bash
flutter pub get
flutter run                # Android / iOS / desktop
flutter run -d chrome      # web - see the setup step below
```

## Web setup (required)

The web build keeps its database in IndexedDB through a sqlite3 (wasm) instance
that runs in a shared worker. Two files must exist in `web/`:

```bash
dart run sqflite_common_ffi_web:setup
```

This creates:

- `web/sqflite_sw.js` - the compiled shared worker
- `web/sqlite3.wasm` - the SQLite wasm binary

Both are committed to this repository, so a fresh clone runs on the web without
extra steps. After upgrading `sqflite_common_ffi_web`, regenerate them with
`--force`; if `sqlite3.wasm` ever has to match a specific `sqlite3` Dart release,
pass `--sqlite3-wasm-url <release url>` to the same command.

Without those files `openDatabase` fails with `SqfliteFfiWebException()` and the
note list stays empty ("loading notes failed").

## Platform support

| Capability | Android / iOS | Desktop | Web |
| --- | --- | --- | --- |
| Create, edit, delete, search notes | yes | yes | yes (IndexedDB) |
| Drag a note to reorder the list | yes | yes | yes (IndexedDB) |
| 15 minute location tracker note | yes | no | no |

`flutter_background_service` and the location permission flow only exist on
Android/iOS; the guard is `isBackgroundTrackingSupported` in
`lib/services/background_service.dart`. On web/desktop the seeded tracker note is
an ordinary, editable note and no permission dialog is shown.

## Note order

Rows are reordered by dragging the handle on the right edge of a row (long press
still opens the context menu). The order lives in the `sortOrder` column, so it
survives restarts, and:

- the list is read `ORDER BY sortOrder, updatedAt DESC` - `updatedAt` is only the
  tie breaker, which is why a background location update no longer floats the
  tracker note to the top of a hand ordered list;
- a brand new note is placed on top (`MIN(sortOrder) - 1`), like iOS Notes;
- editing a note never moves it: `Note.toMap()` deliberately leaves `sortOrder`
  out, so the "save the text" UPDATE cannot renumber a row;
- reordering is disabled while a search is active - the drag indices address the
  unfiltered list, and reordering a filtered subset has no predictable result.

The column arrived with schema version 2 (`DatabaseHelper._ensureSchema`). The
upgrade adds it to an existing `notepad.db` and numbers the rows so the list
looks exactly as it did before: newest first.

## Architecture

- `lib/database/database_helper.dart` - SQLite access. The UI isolate caches one
  connection; every other isolate opens its own private one
  (`singleInstance: false`), because sqflite's single-instance registry is
  process wide and closing a shared handle would kill the UI connection.
  Queries heal a connection that was closed underneath the app. Reordering is
  persisted by `updateNoteOrder` as one batched renumbering, so a drop either
  writes the whole order or nothing at all.
- `lib/providers/note_provider.dart` - bridges the table to the widget tree
  (`ChangeNotifier`) and listens for background-service updates. `reorderNotes`
  moves the row in memory first and persists right after.
- `lib/screens/` - iOS-style list (`home_screen`) and editor (`editor_screen`).
  The list is a `SliverReorderableList` (`onReorderItem`) whose rows carry a
  `ValueKey` on the note id.
- `lib/services/` - location access plus the Android/iOS background service.

## Tests

```bash
flutter test
```

