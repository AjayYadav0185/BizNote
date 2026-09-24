import 'dart:math';

/// Generates the stable, per-install device id used by the Firebase payloads.
///
/// A random v4 UUID is deliberate: it needs no extra plugin, works on every
/// platform the app builds for (Android, iOS, web, desktop) and carries no
/// hardware identifier, so nothing about the phone itself leaves the device —
/// the id is only a handle that groups a device's records in Firebase.
class DeviceId {
  DeviceId._();

  static final Random _random = Random.secure();

  /// A random RFC 4122 version 4 UUID, e.g.
  /// `0f8fad5b-d9cb-469f-a165-70867728950e`.
  static String generate() {
    final List<int> bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    // Version 4 (random) and the RFC 4122 variant bits.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final String hex = bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
