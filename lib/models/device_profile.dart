import '../utils/date_formatter.dart';

/// One-time setup record: which device this is and which mobile number it
/// belongs to.
///
/// It lives in the local `profile` table as a **single** row ([fixedRowId]), so
/// it survives restarts and can also be read from the background service
/// isolate (which opens its own connection). Both fields are attached to every
/// Firebase payload — `notes/<id>` and `locations/latest` / `locations/history`
/// — which is what makes a stored record attributable to a customer.
class DeviceProfile {
  /// Physical SQLite table name.
  static const String tableName = 'profile';

  /// The table holds exactly one row; this is its primary key.
  static const int fixedRowId = 1;

  /// Accepted length of the phone number in digits (country code included).
  /// 7 is the shortest plausible local number, 15 is the E.164 maximum.
  static const int minPhoneDigits = 7;
  static const int maxPhoneDigits = 15;

  /// Stable per-install id, generated once on the first launch.
  final String deviceId;

  /// Mobile number as entered (a leading `+` is preserved, separators are not).
  final String phoneNumber;

  /// Last write timestamp (`yyyy-MM-dd HH:mm:ss`), the same format the note rows
  /// use for `updatedAt`.
  final String updatedAt;

  const DeviceProfile({
    required this.deviceId,
    required this.phoneNumber,
    required this.updatedAt,
  });

  /// True while the one-time setup is still missing a usable number.
  bool get needsPhoneNumber => !isValidPhoneNumber(phoneNumber);

  /// Digits only, e.g. `+91 98765 43210` -> `+919876543210`.
  ///
  /// Spaces, dashes, dots and parentheses are dropped (people type them, no
  /// client wants them) while a leading `+` is kept so the country code stays
  /// readable in Firebase.
  static String normalizePhoneNumber(String value) {
    final String trimmed = value.trim();
    final String digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      return '';
    }
    return trimmed.startsWith('+') ? '+$digits' : digits;
  }

  /// True when [value] looks like a phone number: [minPhoneDigits] to
  /// [maxPhoneDigits] digits once the separators are gone.
  static bool isValidPhoneNumber(String value) {
    final int digits = normalizePhoneNumber(value).replaceAll('+', '').length;
    return digits >= minPhoneDigits && digits <= maxPhoneDigits;
  }

  /// Builds a profile from a SQLite row.
  factory DeviceProfile.fromMap(Map<String, dynamic> map) {
    return DeviceProfile(
      deviceId: (map['deviceId'] as String?) ?? '',
      phoneNumber: (map['phoneNumber'] as String?) ?? '',
      updatedAt: (map['updatedAt'] as String?) ?? '',
    );
  }

  /// SQLite friendly representation (id included so the upsert replaces the
  /// single row instead of piling up new ones).
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': fixedRowId,
      'deviceId': deviceId,
      'phoneNumber': phoneNumber,
      'updatedAt': updatedAt,
    };
  }

  /// Copy with the given fields replaced.
  DeviceProfile copyWith({
    String? deviceId,
    String? phoneNumber,
    String? updatedAt,
  }) {
    return DeviceProfile(
      deviceId: deviceId ?? this.deviceId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Same profile with a freshly normalized number and a new timestamp.
  DeviceProfile withPhoneNumber(String value, {DateTime? timestamp}) {
    return copyWith(
      phoneNumber: normalizePhoneNumber(value),
      updatedAt: DateFormatter.formatForStorage(timestamp ?? DateTime.now()),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceProfile &&
        other.deviceId == deviceId &&
        other.phoneNumber == phoneNumber &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(deviceId, phoneNumber, updatedAt);

  @override
  String toString() =>
      'DeviceProfile(deviceId: $deviceId, phoneNumber: $phoneNumber)';
}
