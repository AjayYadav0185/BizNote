import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';

import '../database/database_helper.dart';
import '../models/note.dart';
import '../utils/date_formatter.dart';
import 'location_service.dart';

/// Method names exchanged between the UI isolate and the service isolate.
class BackgroundServiceMethod {
  /// `service -> UI`: the tracked note was written, the UI should re-read it.
  static const String update = 'update';

  /// `UI -> service`: run one location cycle immediately.
  static const String refreshLocation = 'refreshLocation';

  /// `UI -> service`: stop the persistent service.
  static const String stopService = 'stopService';
}

/// How often the tracked note is refreshed (exactly 15 minutes).
const Duration kLocationUpdateInterval = Duration(minutes: 15);

/// Id of the ongoing Android notification.
const int kForegroundNotificationId = 888;

/// Title of the ongoing Android notification.
const String kNotificationTitle = 'BizNote · Live Location';

/// Wires the Dart callbacks into the native service layer.
///
/// Must be called from `main()` **before** `runApp()` so the native side always
/// has the latest entry points. On Android this starts a persistent foreground
/// service (with an ongoing notification, see [kForegroundNotificationId]);
/// on iOS it registers the `BGTaskScheduler` handler.
Future<void> initializeBackgroundService() async {
  final FlutterBackgroundService service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      autoStartOnBoot: true,
      isForegroundMode: true,
      initialNotificationTitle: kNotificationTitle,
      initialNotificationContent: 'Waiting for the first GPS fix…',
      foregroundServiceNotificationId: kForegroundNotificationId,
      foregroundServiceTypes: const <AndroidForegroundType>[
        AndroidForegroundType.location,
      ],
      // `notificationChannelId` is left null on purpose: the plugin then creates
      // its own "FOREGROUND_DEFAULT" channel. Supplying a custom id without
      // creating that channel first (which needs flutter_local_notifications)
      // silently drops the notification on Android 8+.
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

/// Entry point executed **inside the background isolate**.
///
/// Nothing in here may touch the widget tree: it only talks to the native layer
/// (`service`), to `sqflite` and to `geolocator`.
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Bridge between the UI isolate and this isolate.
  service.on(BackgroundServiceMethod.stopService).listen((_) async {
    await service.stopSelf();
  });
  service.on(BackgroundServiceMethod.refreshLocation).listen((_) async {
    await runLocationCycle(service);
  });

  if (service is AndroidServiceInstance) {
    // Promotes the service into the foreground so Android keeps the process
    // alive; this is what makes the timer below reliable.
    await service.setAsForegroundService();
    debugPrint('[BG] Android foreground service started');
  }

  if (Platform.isIOS) {
    _startIosKeepAlive();
  }

  // The first cycle runs immediately so the note is never stale for 15 minutes…
  await runLocationCycle(service);

  // …and afterwards exactly every 15 minutes.
  Timer.periodic(kLocationUpdateInterval, (Timer timer) async {
    await runLocationCycle(service);
  });
}

/// One full cycle: verify permissions, capture a GPS fix, format it, write it
/// into the fixed note through an isolated connection and finally publish the
/// result to the UI isolate.
Future<void> runLocationCycle(ServiceInstance service) async {
  final DateTime now = DateTime.now();

  String status;
  Position? position;

  try {
    if (!await LocationService.isServiceEnabled()) {
      status = LocationStatus.servicesDisabled;
    } else if (!await LocationService.hasForegroundPermission()) {
      // The permission dialog can only be shown by the UI isolate, so the
      // background task records the state and retries on the next tick.
      status = LocationStatus.permissionDenied;
    } else {
      position = await LocationService.capturePosition();
      status =
          position == null ? LocationStatus.unavailable : LocationStatus.active;
    }
  } catch (error) {
    debugPrint('[BG] permission/GPS check failed: $error');
    status = LocationStatus.unavailable;
  }

  final String content = LocationService.buildTrackerContent(
    status: status,
    position: position,
    timestamp: now,
  );
  final String updatedAt = DateFormatter.formatForStorage(now);
  int affectedRows = 0;

  try {
    affectedRows = await DatabaseHelper.updateFixedNoteFromBackground(
      content: content,
      updatedAt: updatedAt,
    );
  } catch (error) {
    debugPrint('[BG] isolated database write failed: $error');
  }

  debugPrint('[BG] cycle done · status=$status · rows=$affectedRows · $updatedAt');

  // Mirror the newest fix into the ongoing Android notification.
  if (service is AndroidServiceInstance) {
    try {
      await service.setForegroundNotificationInfo(
        title: kNotificationTitle,
        content: position == null
            ? '$status · ${DateFormatter.formatTime(now)}'
            : '${position.latitude.toStringAsFixed(4)}, '
                '${position.longitude.toStringAsFixed(4)} · '
                '${DateFormatter.formatTime(now)}',
      );
    } catch (error) {
      debugPrint('[BG] notification refresh failed: $error');
    }
  }

  // Hand the fresh row to the UI isolate so an open app refreshes instantly.
  service.invoke(BackgroundServiceMethod.update, <String, dynamic>{
    'noteId': Note.fixedNoteId,
    'status': status,
    'latitude': position?.latitude,
    'longitude': position?.longitude,
    'updatedAt': updatedAt,
    'rowsAffected': affectedRows,
  });
}

/// Invoked by iOS through `BGAppRefreshTask` / background fetch, at most about
/// once every 15 minutes. Returning `true` keeps iOS scheduling the task.
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await runLocationCycle(service);
  return true;
}

/// iOS suspends background isolates unless a background mode is actively used.
/// A live location stream plus `UIBackgroundModes: location` keeps the process
/// alive, which is what allows the 15 minute timer in [onStart] to fire while
/// the app is not on screen. Android does not need this: its foreground service
/// is already persistent.
StreamSubscription<Position>? _iosKeepAliveSubscription;

void _startIosKeepAlive() {
  if (_iosKeepAliveSubscription != null) {
    return;
  }
  try {
    _iosKeepAliveSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 25,
      ),
    ).listen(
      (Position position) {
        debugPrint('[BG][iOS] keep alive · ${position.latitude}');
      },
      onError: (Object error) {
        debugPrint('[BG][iOS] keep alive stream error: $error');
      },
      cancelOnError: false,
    );
    debugPrint('[BG][iOS] keep alive location stream started');
  } catch (error) {
    debugPrint('[BG][iOS] keep alive stream unavailable: $error');
  }
}
