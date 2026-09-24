# BizNote (notepad_app)

An offline, iOS-style notes app built with Flutter. Notes live in a local SQLite
database (`notepad.db`) and are mirrored to Firebase Realtime Database
(`notes/<id>`), so the records can be read from the Firebase console or a
dashboard without the phone. The list can be reordered by dragging a row's
handle, and the order is stored in the database. On Android/iOS a persistent
background service keeps a single "📍 Live Location Tracker" note up to date
every 15 minutes, even while the app is closed.

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
| Mirror every note to Firebase (`notes/<id>`) | yes | yes | yes (needs a web app registration, see below) |
| 15 minute location tracker note | yes | no | no |

`flutter_background_service` and the location permission flow only exist on
Android/iOS; the guard is `isBackgroundTrackingSupported` in
`lib/services/background_service.dart`. On web/desktop the seeded tracker note is
an ordinary, editable note and no permission dialog is shown.

## Firebase location sync (Android)

Every tracker cycle also mirrors its fix to Firebase Realtime Database, so
the position can be read from the Firebase console or a dashboard without
the phone:

```
locations/
  latest/   <- newest cycle, overwritten every time
  history/  <- append-only trail, one push key per cycle
```

Fields: `status`, `hasFix`, `updatedAt` (`yyyy-MM-dd HH:mm:ss`),
`timestampMillis`, `deviceId`, `phoneNumber` and, when a fix exists,
`latitude`, `longitude`, `accuracy`, `altitude`, `speed`, `heading`.
Coordinate fields are omitted when there is no fix, so a `set` clears stale
coordinates instead of leaving the previous ones behind. `deviceId` /
`phoneNumber` come from the one-time welcome setup (see below) and are read
fresh from the local database on every tick, so a corrected number shows up in
the very next entry.

### One-time setup

1. In the Firebase console, add an Android app with the package name
   `com.biznote.notepad_app`.
2. Create the **Realtime Database** *before* downloading (or re-downloading)
   `google-services.json`, so the file contains `project_info/firebase_url`.
   Without it the Android SDK guesses
   `https://<project-id>-default-rtdb.firebaseio.com`, which is wrong for
   databases outside us-central1.
3. Save the file as `android/app/google-services.json`. Gradle applies the
   Google Services plugin (see `android/build.gradle.kts` +
   `android/app/build.gradle.kts`) only while that file exists — until then
   the app still builds, and Firebase is skipped with a
   `[Firebase] initialization failed` log line.
4. Start in **test mode** rules while developing:

   ```json
   {
     "rules": {
       "locations": { ".read": true, ".write": true },
       "notes": { ".read": true, ".write": true }
     }
   }
   ```

   Open rules mean anyone with the database URL can read and write. Add
   Firebase Auth and lock the rules down before shipping.
5. `flutter run` — the log shows `[Firebase] location pushed · status=Active`
   on success, or the exact reason on failure (rules, database URL, network).

Implementation: `lib/services/firebase_location_service.dart`, called once
per cycle from `runLocationCycle` (covers the 15 minute loop, "Update Now"
and the iOS background fetch). It is fail-soft: the local note is written
first and the network wait is capped at 15 seconds. The main manifest now
also declares `INTERNET` (it was debug/profile only, so release APKs could
not have reached Firebase).

iOS: add `GoogleService-Info.plist` to `ios/Runner/` in Xcode (same Firebase
project, iOS bundle id); the same Dart code path is used.

### Verifying the 15 minute sync

- **Firebase console** → *Realtime Database* → *Data*: `locations/latest` is
  overwritten on every tick and `locations/history` gains exactly **one**
  new push key per cycle, so the gap between two `updatedAt` values must be
  about 15 minutes. `notes/1` (the tracker row) is refreshed at the same time.
- **Device log** while the app is installed:

  ```bash
  adb logcat | grep -E "\[BG\]|Firebase"
  ```

  A healthy tick logs three lines in this order:

  ```
  [BG] cycle done · status=Active · rows=1 · 2026-09-24 13:43:59
  [Firebase] location pushed · status=Active
  [Firebase] initialized · databaseURL=https://…asia-southeast1.firebasedatabase.app
  ```

  `status=Permission Denied` / `GPS Signal Unavailable` are still pushed to
  Firebase (they are the documented `status` values), so the trail also shows
  *why* a cycle had no fix.
- **REST smoke test** (no phone needed, exactly the payload a cycle writes):

  ```bash
  DB='https://bizarohq-b92c8-default-rtdb.asia-southeast1.firebasedatabase.app'
  curl -X PUT "$DB/locations/latest.json" -H 'Content-Type: application/json' \
    -d '{"status":"Active","hasFix":true,"updatedAt":"2026-09-24 13:43:59","timestampMillis":1790237639000,"latitude":12.9716,"longitude":77.5946,"accuracy":5.0,"altitude":900.0,"speed":0.0,"heading":0.0}'
  curl "$DB/locations.json"      # read it back
  ```

  `HTTP 401 {"error":"Permission denied"}` means the database rules are still
  locked (see step 4 above) — that is the only thing that can keep the app from
  uploading, and it is logged as `[Firebase] … failed: … permission-denied`.

The cycle itself is covered by `test/background_cycle_test.dart`, which runs one
full `runLocationCycle` against injected writers and asserts that a single tick
persists the note **and** publishes the same fix exactly once
(`writeNote`/`publishLocation` exist for that test; production uses the
database + Firebase implementations).

## Firebase notes sync

Separately from the tracker, every note is mirrored to Firebase Realtime
Database, keyed by the primary key of the local `notes` table:

```
notes/
  <note id>/
    id, title, content, updatedAt, updatedAtMillis,
    sortOrder, isTracker, syncedAt, syncedAtMillis,
    deviceId, phoneNumber
```

- `updatedAt` is the record's timestamp in `yyyy-MM-dd HH:mm:ss`, exactly the
  string the SQLite row holds; `updatedAtMillis` is its millisecond twin and
  `syncedAt`/`syncedAtMillis` describe when the phone pushed the record, which
  is what makes a stale mirror visible from a dashboard.
- `sortOrder` is the position in the hand ordered list and `isTracker` marks the
  note the background location service owns. A row without an id (a note that
  was never saved) cannot be addressed and is skipped.
- `deviceId` / `phoneNumber` come from the one-time welcome setup below, so
  every record says which device and which customer saved it. Saving the number
  re-uploads the whole notebook, so notes written before the setup carry the
  identity too.

### One-time setup (device id + mobile number)

On first launch the app generates a stable per-install `deviceId` (a random
UUID, no hardware identifier) and stores it in the single-row `profile` table.
`HomeScreen` then shows `WelcomeScreen` once and asks the customer for their
mobile number (7–15 digits, country code included); the number is normalized
(`+91 98765 43210` → `+919876543210`) and stored next to the device id. Later
launches skip the screen because `NoteProvider.hasProfile` is already true.
Both fields travel with **every** Firebase write (`notes/<id>`,
`locations/latest`, `locations/history`) and are covered by
`test/background_cycle_test.dart` (the cycle stamps them) and
`test/note_cloud_sync_test.dart`.

| What happens | Cloud write |
| --- | --- |
| App start, first successful read | the whole `notes` node, in one write |
| Saving or creating a note | `notes/<id>` |
| Deleting a note | `notes/<id>` removed |
| Reordering (drag handle) | the whole `notes` node (every `sortOrder` changed) |
| Background location cycle while the app is open | `notes/1` (the tracker row) |
| Cloud button in the bottom bar | the whole `notes` node, then a result dialog |

SQLite stays the source of truth (the app is offline first), so this is a
one-way mirror: there is no pull/restore yet. The writes are fail-soft — a
missing configuration, a locked rule or no network logs a
`[Firebase] ... failed` line and returns `false` instead of throwing, because
the local save is already on disk at that point. Replacing the whole node is
deliberate: it prunes records that were deleted locally while offline. An
**empty** notebook is never pushed, since an empty list means the local read
failed, not that the user deleted everything.

The cloud button next to the compose button in the list triggers the same sync
manually and reports how many records went out; it is the quick way to verify
the rules and the connection from the phone.

Implementation: `lib/services/firebase_note_service.dart` (the payload builders
are pure and covered by `test/firebase_note_payload_test.dart`, the provider
side by `test/note_cloud_sync_test.dart`), hooked into every write path in
`lib/providers/note_provider.dart`.

Firebase is initialized once per isolate in `lib/services/firebase_bootstrap.dart`:
Android/iOS use the native config file, and every other platform (web, desktop,
or an Android build without `google-services.json`) falls back to the project
values spelled out there — including the region specific database URL

```
https://bizarohq-b92c8-default-rtdb.asia-southeast1.firebasedatabase.app
```

On the web that fallback is what makes the mirror work without extra files;
register a Firebase **web app** in the same project (or call
`firebase.initializeApp({...})` inline in `web/index.html`) if you later add
Auth/Analytics, and keep the `notes` rules above open for the origin.

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
  (`ChangeNotifier`), listens for background-service updates and mirrors every
  successful write to Firebase (`syncNotesToFirebase` is the manual entry point).
  `reorderNotes` moves the row in memory first and persists right after.
- `lib/screens/` - iOS-style list (`home_screen`) and editor (`editor_screen`).
  The list is a `SliverReorderableList` (`onReorderItem`) whose rows carry a
  `ValueKey` on the note id.
- `lib/services/` - location access plus the Android/iOS background service, and
  the Firebase mirror: `firebase_bootstrap.dart` (one init per isolate),
  `firebase_note_service.dart` (notes) and `firebase_location_service.dart`
  (tracker fixes).

## Tests

```bash
flutter test
```

