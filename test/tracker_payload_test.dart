import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:notepad_app/services/location_service.dart';

void main() {
  group('LocationService.buildTrackerContent', () {
    test('formats a live fix exactly like the specification', () {
      final Position position = Position(
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime(2026, 9, 23, 12, 20),
        accuracy: 5,
        altitude: 900,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

      final String content = LocationService.buildTrackerContent(
        status: LocationStatus.active,
        position: position,
        timestamp: DateTime(2026, 9, 23, 12, 20),
      );

      expect(
        content,
        'Last Status: Active\n'
        'Timestamp: 23/09/2026 12:20 PM\n'
        'Latitude: 12.9716\n'
        'Longitude: 77.5946',
      );
    });

    test('rounds coordinates to four decimals', () {
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

      final List<String> lines = LocationService.buildTrackerContent(
        status: LocationStatus.active,
        position: position,
      ).split('\n');

      expect(lines[2], 'Latitude: 12.9716');
      expect(lines[3], 'Longitude: -77.5946');
    });

    test('writes placeholders when there is no fix', () {
      final String content = LocationService.buildTrackerContent(
        status: LocationStatus.permissionDenied,
        timestamp: DateTime(2026, 9, 23, 12, 20),
      );

      expect(content, contains('Last Status: Permission Denied'));
      expect(content, contains('Timestamp: 23/09/2026 12:20 PM'));
      expect(content, contains('Latitude: --'));
      expect(content, contains('Longitude: --'));
      expect(content.split('\n').length, 4);
    });
  });
}
