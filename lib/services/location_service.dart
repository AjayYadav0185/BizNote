import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../utils/date_formatter.dart';

/// Values used by the `Last Status:` line of the tracked note.
class LocationStatus {
  /// A fresh GPS fix was captured.
  static const String active = 'Active';

  /// The user did not grant (or revoked) the location permission.
  static const String permissionDenied = 'Permission Denied';

  /// The device wide location switch (GPS) is turned off.
  static const String servicesDisabled = 'Location Services Disabled';

  /// Permission is fine but no fix could be produced in time.
  static const String unavailable = 'GPS Signal Unavailable';
}

/// Reusable wrapper around `geolocator`.
///
/// Everything in here is safe to call from the background isolate **except**
/// [ensureForegroundPermission] / [ensureBackgroundPermission]: Android needs a
/// live `Activity` to show a permission dialog, so those two are meant to be
/// called from the UI isolate (see `main.dart`). The background loop only ever
/// *verifies* permissions with [checkPermission] and skips the cycle while the
/// user has not granted them yet.
class LocationService {
  LocationService._();

  /// Upper bound for one GPS request so a cycle can never hang forever.
  static const Duration positionTimeout = Duration(seconds: 45);

  /// Accuracy used by the tracker. `high` maps to `PRIORITY_HIGH_ACCURACY` on
  /// Android and `kCLLocationAccuracyNearestTenMeters` on iOS, which is plenty
  /// for a location note and battery friendly at one fix per 15 minutes.
  static const LocationSettings trackerSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    timeLimit: positionTimeout,
  );

  /// Device wide location switch.
  static Future<bool> isServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  /// Current permission, without prompting.
  static Future<LocationPermission> checkPermission() =>
      Geolocator.checkPermission();

  /// True when the app may read the location while it is being used.
  static Future<bool> hasForegroundPermission() async {
    final LocationPermission permission = await checkPermission();
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// True when the app may also read the location in the background.
  static Future<bool> hasBackgroundPermission() async =>
      await checkPermission() == LocationPermission.always;

  /// Requests "while using the app" access. **UI isolate only.**
  ///
  /// Returns `true` when at least `whileInUse` access is available.
  static Future<bool> ensureForegroundPermission() async {
    // Background/location plugins are mobile-only; on desktop/web there is
    // nothing to request, so skip instead of throwing.
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return false;
    }
    if (!await isServiceEnabled()) {
      return false;
    }
    LocationPermission permission = await checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Escalates to "Allow all the time" so the 15 minute loop also runs while
  /// the app is closed. **UI isolate only.**
  ///
  /// Android 11+ refuses to show the "Allow all the time" dialog inline and
  /// forces the user through the app settings screen, so this method deep links
  /// there when the inline request is not enough.
  static Future<bool> ensureBackgroundPermission() async {
    if (await hasBackgroundPermission()) {
      return true;
    }
    final LocationPermission permission = await checkPermission();
    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return hasBackgroundPermission();
    }

    // Android <= 10 shows the "Allow all the time" dialog right here; on iOS
    // this second request surfaces the "Change to Always Allow" upgrade.
    try {
      await Geolocator.requestPermission();
    } catch (error) {
      debugPrint('[Location] background permission request failed: $error');
    }
    if (await hasBackgroundPermission()) {
      return true;
    }

    await Geolocator.openAppSettings();
    return hasBackgroundPermission();
  }

  /// Opens the app settings page (used by the permission dialogs).
  static Future<bool> openAppSettings() => Geolocator.openAppSettings();

  /// Opens the device location settings page.
  static Future<bool> openLocationSettings() =>
      Geolocator.openLocationSettings();

  /// Captures a single GPS fix and **never throws**.
  ///
  /// Falls back to the last known position when a live fix times out, which
  /// keeps the note useful on devices with a weak signal or while indoors.
  static Future<Position?> capturePosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: trackerSettings,
      );
    } catch (error) {
      debugPrint('[Location] getCurrentPosition failed: $error');
    }
    try {
      final Position? lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        return lastKnown;
      }
    } catch (error) {
      debugPrint('[Location] getLastKnownPosition failed: $error');
    }
    return null;
  }

  /// Builds the exact body written into the fixed note, e.g.
  ///
  /// ```
  /// Last Status: Active
  /// Timestamp: 23/09/2026 12:20 PM
  /// Latitude: 12.9716
  /// Longitude: 77.5946
  /// ```
  static String buildTrackerContent({
    required String status,
    Position? position,
    DateTime? timestamp,
  }) {
    final DateTime moment = timestamp ?? DateTime.now();
    final String latitude =
        position == null ? '--' : position.latitude.toStringAsFixed(4);
    final String longitude =
        position == null ? '--' : position.longitude.toStringAsFixed(4);

    return 'Last Status: $status\n'
        'Timestamp: ${DateFormatter.formatTrackerTimestamp(moment)}\n'
        'Latitude: $latitude\n'
        'Longitude: $longitude';
  }
}
