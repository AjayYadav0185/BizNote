import 'dart:async';

import 'package:beacon_broadcast/beacon_broadcast.dart';
import 'package:flutter/foundation.dart';

/// The static UUID broadcast by this app as an AirTag-style BLE beacon.
///
/// BLE libraries (AltBeacon on Android, CoreLocation on iOS) require a full
/// 128-bit UUID in the form `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`. The
/// placeholder you gave (`car-notepad-tracker-v1-unique-id`) is not a valid BLE
/// UUID, so replace it with the exact UUID your car stereo subscribes to, e.g.
/// `a1b2c3d4-e5f6-7890-abcd-ef1234567890`.
///
/// If instead you want to advertise an arbitrary manufacturer-data payload
/// (not an AltBeacon frame), set [kBleBeaconLayout] below and pass the vendor
/// ID with [setManufacturerId] before [start].
const String kBleBeaconUuid = '8a3b9c2e-1f4a-4d6e-8b7a-2c3d4e5f6a7b';

/// AltBeacon vendor ID (Radius Networks). Only used on Android.
const int kBleBeaconManufacturerId = 0x001D;

/// Beacon frame layout. Null (the default) uses AltBeacon
/// (`s:0-1=feaa,m:2-2=10,p:3-3:-41,i:4-21v`), which advertises the UUID as
/// manufacturer data. Set a custom layout to advertise arbitrary payload bytes.
const String? kBleBeaconLayout = null;

/// Watchdog interval for re-starting the beacon if Android kills the
/// advertiser (Android 8+ stops background advertisers after about 10 minutes).
const Duration kBeaconWatchdogInterval = Duration(seconds: 30);

/// A persistent, background BLE beacon broadcaster (AirTag-style for the car
/// stereo).
///
/// It runs inside the existing [FlutterBackgroundService] foreground service so
/// it keeps broadcasting with an ongoing (silent) notification while the app is
/// closed, starts on device boot, and is monitored by a watchdog that
/// re-starts the advertiser if Android ever stops it.
class BleBeaconService {
  BleBeaconService({Timer? watchdog}) {
    _watchdog = watchdog ?? Timer.periodic(kBeaconWatchdogInterval, (_) => _restartIfStopped());
    debugPrint('[BLE Beacon] service created');
  }

  Timer? _watchdog;

  BeaconBroadcast? _beacon;
  bool _initialized = false;
  bool _advertising = false;
  bool _userStopped = false;
  int _advertiseAttempts = 0;

  bool get isAdvertising => _advertising;

  /// Start (or restart) the beacon broadcaster.
  ///
  /// No-op if the broadcaster is already running; idempotent. Returns `false`
  /// if the device does not support BLE advertising.
  Future<bool> start() async {
    _userStopped = false;
    if (_initialized && _beacon != null) {
      debugPrint('[BLE Beacon] already running; re-starting...');
      await _startCore();
      return _advertising;
    }
    _initialized = true;
    _advertiseAttempts++;
    await _startCore();
    return _advertising;
  }

  /// Stop the beacon advertiser.
  void stop() {
    _userStopped = true;
    _advertising = false;
    _beacon?.stop();
    _beacon = null;
    debugPrint('[BLE Beacon] advertising stopped (user-initiated)');
  }

  /// Restart the beacon after it was killed or stopped unexpectedly.
  ///
  /// Only works if the caller has not explicitly stopped the service.
  Future<void> _restart() async {
    if (!_initialized || _userStopped) {
      return;
    }
    _advertiseAttempts++;
    await _startCore();
  }

  /// Watchdog: poll the native advertiser and re-start it if it died.
  Future<void> _restartIfStopped() async {
    if (!_initialized || _userStopped) {
      return;
    }
    try {
      final bool currentlyAdvertising = (await _beacon!.isAdvertising()) ?? false;
      if (!currentlyAdvertising) {
        debugPrint('[BLE Beacon] advertising was stopped; re-starting...');
        await _restart();
      }
    } catch (error) {
      debugPrint('[BLE Beacon] watchdog check failed: $error');
    }
  }

  /// Core start routine: validate support, configure, then start advertising.
  Future<void> _startCore() async {
    _beacon = null;
    try {
      _beacon = BeaconBroadcast();
      final BeaconStatus supportStatus = await _beacon!.checkTransmissionSupported();
      if (supportStatus != BeaconStatus.supported) {
        debugPrint('[BLE Beacon] transmission unsupported: $supportStatus');
        _advertising = false;
        return;
      }

      await _configureAndStart();
      _advertising = true;
      debugPrint('[BLE Beacon] advertising started (attempt $_advertiseAttempts)');
    } catch (error) {
      debugPrint('[BLE Beacon] start failed: $error');
      _advertising = false;
    }
  }

  /// Apply the configuration and start advertising.
  Future<void> _configureAndStart() async {
    _beacon!.setUUID(kBleBeaconUuid);
    _beacon!.setMajorId(1);
    _beacon!.setMinorId(1);
    _beacon!.setTransmissionPower(-12);

    if (defaultTargetPlatform == TargetPlatform.android) {
      // AltBeacon uses the Radius Networks vendor ID; setManufacturerId() is
      // Android-only in this plugin.
      _beacon!.setManufacturerId(kBleBeaconManufacturerId);
      // lowPower is the most battery-friendly, yet still reliable, option.
      _beacon!.setAdvertiseMode(AdvertiseMode.lowPower);
    }

    if (kBleBeaconLayout != null) {
      _beacon!.setLayout(kBleBeaconLayout!);
    }

    await _beacon!.start();
  }

  void dispose() {
    _watchdog?.cancel();
    _beacon?.stop();
  }
}
