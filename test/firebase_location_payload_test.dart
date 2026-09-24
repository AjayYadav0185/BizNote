import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:BizNote/services/firebase_location_service.dart';
import 'package:BizNote/services/location_service.dart';

void main() {
  group('FirebaseLocationService.buildLocationPayload', () {
    test('captures a live fix with coordinates and metadata', () {
      final Position position = Position(
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime(2026, 9, 23, 12, 20),
        accuracy: 5,
        altitude: 900,
        altitudeAccuracy: 1,
        heading: 180,
        headingAccuracy: 1,
        speed: 2.5,
        speedAccuracy: 0.5,
      );

      final Map<String, dynamic> payload =
          FirebaseLocationService.buildLocationPayload(
        status: LocationStatus.active,
        position: position,
        timestamp: DateTime(2026, 9, 23, 12, 20),
      );

      expect(payload['status'], 'Active');
      expect(payload['hasFix'], true);
      expect(payload['latitude'], 12.9716);
      expect(payload['longitude'], 77.5946);
      expect(payload['accuracy'], 5);
      expect(payload['altitude'], 900);
      expect(payload['speed'], 2.5);
      expect(payload['heading'], 180);
      expect(payload['updatedAt'], '2026-09-23 12:20:00');
      expect(
        payload['timestampMillis'],
        DateTime(2026, 9, 23, 12, 20).millisecondsSinceEpoch,
      );
    });

    test('keeps full coordinate precision (the note rounds to four decimals)',
        () {
      final Position position = Position(
        latitude: 12.97164999,
        longitude: -77.59464999,
        timestamp: DateTime(2026, 9, 23, 12, 20),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

      final Map<String, dynamic> payload =
          FirebaseLocationService.buildLocationPayload(
        status: LocationStatus.active,
        position: position,
        timestamp: DateTime(2026, 9, 23, 12, 20),
      );

      expect(payload['latitude'], 12.97164999);
      expect(payload['longitude'], -77.59464999);
    });

    test('omits coordinate fields when there is no fix', () {
      final Map<String, dynamic> payload =
          FirebaseLocationService.buildLocationPayload(
        status: LocationStatus.permissionDenied,
        timestamp: DateTime(2026, 9, 23, 12, 20),
      );

      expect(payload['status'], 'Permission Denied');
      expect(payload['hasFix'], false);
      expect(payload.containsKey('latitude'), isFalse);
      expect(payload.containsKey('longitude'), isFalse);
      expect(payload.containsKey('accuracy'), isFalse);
      expect(payload['updatedAt'], '2026-09-23 12:20:00');
    });

    test('produces only values the Realtime Database can encode', () {
      final Position position = Position(
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime(2026, 9, 23, 12, 20),
        accuracy: 5.5,
        altitude: 900,
        altitudeAccuracy: 1,
        heading: 180,
        headingAccuracy: 1,
        speed: 2.5,
        speedAccuracy: 0.5,
      );

      final Map<String, dynamic> payload =
          FirebaseLocationService.buildLocationPayload(
        status: LocationStatus.active,
        position: position,
        timestamp: DateTime(2026, 9, 23, 12, 20),
      );

      // The Realtime Database stores JSON: jsonEncode throws on NaN/Infinity
      // and on values that are not plain primitives, which is exactly the
      // contract the payload must keep.
      final String encoded = jsonEncode(payload);
      expect(encoded, contains('"status":"Active"'));
      expect(encoded, contains('"latitude":12.9716'));
    });
  });
}