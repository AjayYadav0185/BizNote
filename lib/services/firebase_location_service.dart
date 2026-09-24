import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../utils/date_formatter.dart';
import 'firebase_bootstrap.dart';

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
  ///
  /// The attempt itself lives in [FirebaseBootstrap], which the note mirror
  /// uses as well: two independent initializations in the same isolate would
  /// race each other for the default app.
  static Future<bool> ensureInitialized() =>
      FirebaseBootstrap.ensureInitialized();

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