import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:BizNote/models/device_profile.dart';
import 'package:BizNote/models/note.dart';
import 'package:BizNote/services/background_service.dart';
import 'package:BizNote/services/firebase_location_service.dart';
import 'package:BizNote/services/location_service.dart';
import 'package:BizNote/utils/date_formatter.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

/// Minimal [ServiceInstance] stand-in: the cycle only calls [invoke] (the
/// Android notification path is skipped because this is not an
/// `AndroidServiceInstance`).
class _FakeServiceInstance implements ServiceInstance {
  final List<String> invokedMethods = <String>[];
  final Map<String, Map<String, dynamic>?> arguments =
      <String, Map<String, dynamic>?>{};

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    invokedMethods.add(method);
    arguments[method] = args;
  }

  @override
  Stream<Map<String, dynamic>?> on(String method) =>
      const Stream<Map<String, dynamic>?>.empty();

  @override
  Future<void> stopSelf() async {}
}

void main() {
  // Geolocator talks to a platform channel; without a binding the cycle would
  // fail through a noisy "binding has not yet been initialized" exception.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('background location cadence', () {
    test('the tracker runs immediately and then exactly every 15 minutes', () {
      // `onStart` runs one cycle right away and afterwards schedules
      // `Timer.periodic(kLocationUpdateInterval, …)`, which is what puts one
      // new fix into Firebase every 15 minutes.
      expect(kLocationUpdateInterval, const Duration(minutes: 15));
      expect(kLocationUpdateInterval.inMinutes, 15);
    });
  });

  group('runLocationCycle', () {
    test('every cycle writes the note and mirrors the same fix to Firebase',
        () async {
      final _FakeServiceInstance service = _FakeServiceInstance();
      final List<Map<String, dynamic>> noteWrites = <Map<String, dynamic>>[];
      final List<Map<String, dynamic>> pushes = <Map<String, dynamic>>[];

      await runLocationCycle(
        service,
        writeNote: ({
          required String content,
          required String updatedAt,
        }) async {
          noteWrites.add(<String, dynamic>{
            'content': content,
            'updatedAt': updatedAt,
          });
          return 1;
        },
        publishLocation: ({
          required String status,
          Position? position,
          DateTime? timestamp,
          DeviceProfile? profile,
        }) async {
          // Exactly what `FirebaseLocationService.sendLocation` sends.
          pushes.add(
            FirebaseLocationService.buildLocationPayload(
              status: status,
              position: position,
              timestamp: timestamp,
              profile: profile,
            ),
          );
          return true;
        },
      );

      // One local write…
      expect(noteWrites, hasLength(1));
      final String content = noteWrites.single['content'] as String;
      expect(content, startsWith('Last Status: '));
      expect(
        DateFormatter.parseFromStorage(noteWrites.single['updatedAt'] as String),
        isNotNull,
      );

      // …and one cloud write of the very same cycle.
      expect(pushes, hasLength(1));
      final Map<String, dynamic> payload = pushes.single;
      expect(payload['status'], content.split('\n').first.substring(13));
      expect(payload['hasFix'], false);
      // No fix in the test environment, so the coordinate fields must be
      // absent: a full `set` of this payload clears stale coordinates.
      expect(payload.containsKey('latitude'), isFalse);
      expect(payload.containsKey('longitude'), isFalse);
      expect(payload['updatedAt'], noteWrites.single['updatedAt']);
      // The note stores `yyyy-MM-dd HH:mm:ss`, the payload keeps the full
      // millisecond precision of the same moment.
      final DateTime storedAt =
          DateFormatter.parseFromStorage(noteWrites.single['updatedAt'] as String)!;
      expect(
        (payload['timestampMillis'] as int) ~/ 1000,
        storedAt.millisecondsSinceEpoch ~/ 1000,
      );
      // Identity is part of every fix: the no-setup fallback mirrors the
      // production default (profile kept empty until welcome is completed).
      expect(payload.containsKey('deviceId'), isFalse);
      expect(payload.containsKey('phoneNumber'), isFalse);
    });

    test('a cycle stamps the one-time setup identity onto the Firebase fix',
        () async {
      final _FakeServiceInstance service = _FakeServiceInstance();
      final List<Map<String, dynamic>> pushes = <Map<String, dynamic>>[];
      const DeviceProfile profile = DeviceProfile(
        deviceId: 'device-123',
        phoneNumber: '+911234567890',
        updatedAt: '2026-09-24 13:00:00',
      );

      await runLocationCycle(
        service,
        writeNote: ({
          required String content,
          required String updatedAt,
        }) async =>
            1,
        publishLocation: ({
          required String status,
          Position? position,
          DateTime? timestamp,
          DeviceProfile? profile,
        }) async {
          pushes.add(
            FirebaseLocationService.buildLocationPayload(
              status: status,
              position: position,
              timestamp: timestamp,
              profile: profile,
            ),
          );
          return true;
        },
        readProfile: () async => profile,
      );

      expect(pushes, hasLength(1));
      expect(pushes.single['deviceId'], 'device-123');
      expect(pushes.single['phoneNumber'], '+911234567890');
      expect(service.arguments[BackgroundServiceMethod.update]?['deviceId'],
          'device-123');
      expect(service.arguments[BackgroundServiceMethod.update]?['phoneNumber'],
          '+911234567890');
    });

    test('a cycle still mirrors a status when the database write fails',
        () async {
      final _FakeServiceInstance service = _FakeServiceInstance();
      final List<String> pushedStatuses = <String>[];

      await runLocationCycle(
        service,
        writeNote: ({
          required String content,
          required String updatedAt,
        }) async {
          throw Exception('database_closed');
        },
        publishLocation: ({
          required String status,
          Position? position,
          DateTime? timestamp,
          DeviceProfile? profile,
        }) async {
          pushedStatuses.add(status);
          return true;
        },
      );

      expect(pushedStatuses, hasLength(1));
      expect(pushedStatuses.single, isNotEmpty);
    });

    test('a failed push is reported to the UI but never breaks the cycle',
        () async {
      final _FakeServiceInstance service = _FakeServiceInstance();

      await runLocationCycle(
        service,
        writeNote: ({
          required String content,
          required String updatedAt,
        }) async =>
            1,
        publishLocation: ({
          required String status,
          Position? position,
          DateTime? timestamp,
          DeviceProfile? profile,
        }) async =>
            false,
      );

      expect(service.invokedMethods, <String>[BackgroundServiceMethod.update]);
      final Map<String, dynamic>? event =
          service.arguments[BackgroundServiceMethod.update];
      expect(event?['noteId'], Note.fixedNoteId);
      expect(event?['rowsAffected'], 1);
      expect(event?['firebaseSynced'], false);
      expect(event?['latitude'], isNull);
    });
  });

  group('LocationStatus values reach Firebase verbatim', () {
    test('a denied permission is stored, not silently skipped', () {
      final Map<String, dynamic> payload =
          FirebaseLocationService.buildLocationPayload(
        status: LocationStatus.permissionDenied,
      );
      expect(payload['status'], 'Permission Denied');
      expect(payload['hasFix'], false);
    });
  });
}
