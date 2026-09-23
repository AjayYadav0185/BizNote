import 'package:flutter_test/flutter_test.dart';
import 'package:BizNote/utils/date_formatter.dart';

void main() {
  group('DateFormatter', () {
    test('formatTrackerTimestamp matches the note payload spec', () {
      expect(
        DateFormatter.formatTrackerTimestamp(DateTime(2026, 9, 23, 12, 20)),
        '23/09/2026 12:20 PM',
      );
      expect(
        DateFormatter.formatTrackerTimestamp(DateTime(2026, 9, 23, 0, 5)),
        '23/09/2026 12:05 AM',
      );
    });

    test('storage format round trips', () {
      final DateTime moment = DateTime(2026, 9, 23, 12, 20, 5);
      final String stored = DateFormatter.formatForStorage(moment);

      expect(stored, '2026-09-23 12:20:05');
      expect(DateFormatter.parseFromStorage(stored), moment);
      // Chronological string ordering is what the SQL ORDER BY relies on.
      expect(
        DateFormatter.formatForStorage(DateTime(2026, 9, 23, 9, 0))
            .compareTo(DateFormatter.formatForStorage(DateTime(2026, 9, 23, 12, 0))),
        isNegative,
      );
    });

    test('garbage values are passed through untouched', () {
      expect(DateFormatter.parseFromStorage('not a date'), isNull);
      expect(DateFormatter.formatRelativeFromStorage('not a date'), 'not a date');
      expect(DateFormatter.formatFullFromStorage('not a date'), 'not a date');
    });

    test('relative labels follow the iOS Notes wording', () {
      final String today =
          DateFormatter.formatForStorage(DateTime.now());
      final String yesterday = DateFormatter.formatForStorage(
        DateTime.now().subtract(const Duration(days: 1)),
      );

      expect(DateFormatter.formatRelativeFromStorage(today), 'Today');
      expect(DateFormatter.formatRelativeFromStorage(yesterday), 'Yesterday');
    });

    test('formatDate / formatTime helpers', () {
      final DateTime moment = DateTime(2026, 9, 23, 12, 20);

      expect(DateFormatter.formatDate(moment), '23/09/26');
      expect(DateFormatter.formatTime(moment), '12:20 PM');
      expect(
        DateFormatter.formatFullDateTime(moment),
        'Wednesday, 23 September 2026 at 12:20 PM',
      );
    });
  });
}
