import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../utils/date_formatter.dart';

/// Pushes every tracker fix to Firebase Realtime Database.
///
/// The app already writes each cycle into the local "Live Location Tracker"
/// note; this service mirrors the same data to the cloud so a dashboard (or
/// the Firebase console) can read it without the phone:
///
/// ```
/// locations/
///   latest/                 <- most recent cycle (overwritten every time)
///     status, hasFix, updatedAt, timestampMillis,
///     latitude, longitude, accuracy, altitude, speed, heading
///   history/                <- append-only trail, one push key per cycle
///     <push key>/ ... same fields ...
/// ```
///
/// Everything in here is **fail-soft**: a missing `google-services.json`, a
/// locked database rule or no network logs a `debugPrint` and returns `false`,
/// never an exception — the local note must not depend on Firebase.
///
/// Setup (one time, see README → "Firebase location sync"):
/// 1. Create the Realtime Database in the Firebase console **first**, so a
///    re-downloaded `google-services.json` contains `project_info/firebase_url`
///    (otherwise the Android SDK guesses the URL, which is wrong for
///    non-us-central1 regions).
/// 2. Put the file at `android/app/google-services.json`.
class FirebaseLocationService {
  FirebaseLocationService._();

  /// RTDB path holding `latest` and the `history` trail.
  static const String locationPath = 'locations';

  /// Upper bound for the two RTDB writes so an offline device cannot stall
  /// the 15 minute cycle (the local note write happens before this point).
  static const Duration pushTimeout = Duration(seconds: 15);

  /// One initialization attempt per isolate — both success *and* failure are
  /// cached, so a missing config file logs once instead of on every cycle.
  static Future<bool>? _initialization;

  /// Initializes Firebase for the **current isolate**.
  ///
  /// Every isolate that talks to Firebase needs its own call: the background
  /// service isolate does this lazily on its first cycle. On Android every
  /// option (app id, api key, project id, database url) is read from the
  /// resources the Google Services plugin generated out of
  /// `google-services.json`, so no explicit [FirebaseOptions] are required.
  static Future<bool> ensureInitialized() => _initialization ??= _initialize();

  static Future<bool> _initialize() async {
    try {
      await Firebase.initializeApp();
      debugPrint(
        '[Firebase] initialized · '
        'databaseURL=${Firebase.app().options.databaseURL ?? "from google-services.json"}',
      );
      return true;
    } catch (error) {
      debugPrint(
        '[Firebase] initialization failed — is google-services.json in '
        'android/app/ and the package name com.biznote.notepad_app? · $error',
      );
      return false;
    }
  }

  /// Writes one cycle to `locations/latest` and appends it to
  /// `locations/history`. Returns `true` only when both writes landed.
  static Future<bool> sendLocation({
    required String status,
    Position? position,
    DateTime? timestamp,
  }) async {
    if (!await ensureInitialized()) {
      return false;
    }

    try {
      final Map<String, dynamic> payload = buildLocationPayload(
        status: status,
        position: position,
        timestamp: timestamp,
      );
      await _writeToDatabase(payload).timeout(pushTimeout);
      debugPrint('[Firebase] location pushed · status=$status');
      return true;
    } catch (error) {
      debugPrint('[Firebase] location push failed: $error');
      return false;
    }
  }

  /// `latest` is a plain `set` (the node always shows the newest fix);
  /// `history` is a `push`, so the trail stays append-only and time ordered.
  static Future<void> _writeToDatabase(Map<String, dynamic> payload) async {
    final DatabaseReference locationRef =
        FirebaseDatabase.instance.ref(locationPath);
    await locationRef.child('latest').set(payload);
    await locationRef.child('history').push().set(payload);
  }

  /// Builds the map stored in both `locations/latest` and one history entry.
  ///
  /// Pure and synchronous (like [LocationService.buildTrackerContent]) so it
  /// can be unit tested without Firebase. Coordinate fields are **omitted**
  /// when there is no fix — a full `set` of this payload therefore clears
  /// stale coordinates instead of leaving the previous ones behind.
  static Map<String, dynamic> buildLocationPayload({
    required String status,
    Position? position,
    DateTime? timestamp,
  }) {
    final DateTime moment = timestamp ?? DateTime.now();
    final Map<String, dynamic> payload = <String, dynamic>{
      'status': status,
      'hasFix': position != null,
      'updatedAt': DateFormatter.formatForStorage(moment),
      'timestampMillis': moment.millisecondsSinceEpoch,
    };

    if (position != null) {
      payload['latitude'] = position.latitude;
      payload['longitude'] = position.longitude;
      payload['accuracy'] = position.accuracy;
      payload['altitude'] = position.altitude;
      payload['speed'] = position.speed;
      payload['heading'] = position.heading;
    }

    return payload;
  }
}