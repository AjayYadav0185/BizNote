import 'package:intl/intl.dart';

class DateFormatter {
  /// Formats a DateTime to a string in the format "dd/MM/yy"
  static String formatDate(DateTime date) {
    return DateFormat('dd/MM/yy').format(date);
  }

  /// Formats a DateTime for display relative to today
  /// e.g., "Today", "Yesterday", "Monday", or "23/09/26"
  static String formatRelativeDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    
    final difference = today.difference(dateDay).inDays;

    if (difference == 0) {
      return 'Today';
    } else if (difference == 1) {
      return 'Yesterday';
    } else if (difference < 7) {
      // Return the day name (e.g., "Monday")
      return DateFormat('EEEE').format(date);
    } else {
      // Return the full date (e.g., "23/09/26")
      return formatDate(date);
    }
  }

  /// Formats a DateTime for the note's internal storage
  /// Uses a consistent format: "yyyy-MM-dd HH:mm:ss"
  static String formatForStorage(DateTime date) {
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(date);
  }

  /// Parses a stored date string back to DateTime
  static DateTime? parseFromStorage(String dateString) {
    try {
      return DateFormat('yyyy-MM-dd HH:mm:ss').parse(dateString);
    } catch (e) {
      return null;
    }
  }

  /// Get a short time string (e.g., "2:30 PM")
  static String formatTime(DateTime date) {
    return DateFormat('h:mm a').format(date);
  }

  /// Get a full date and time string (e.g., "Monday, 23 September 2026 at 2:30 PM")
  static String formatFullDateTime(DateTime date) {
    return DateFormat('EEEE, d MMMM yyyy \'at\' h:mm a').format(date);
  }

  /// Formats the timestamp that is embedded in the tracked note body.
  ///
  /// Example: `23/09/2026 12:20 PM`
  static String formatTrackerTimestamp(DateTime date) {
    return DateFormat('dd/MM/yyyy h:mm a').format(date);
  }

  /// Converts a value written by [formatForStorage] into the label used by the
  /// Notes list ("Today", "Yesterday", "Monday", "23/09/26").
  static String formatRelativeFromStorage(String storedValue) {
    final DateTime? parsed = parseFromStorage(storedValue);
    return parsed == null ? storedValue : formatRelativeDate(parsed);
  }

  /// Converts a value written by [formatForStorage] into the long form label
  /// used by the editor footer,
  /// e.g. "Monday, 23 September 2026 at 12:20 PM".
  static String formatFullFromStorage(String storedValue) {
    final DateTime? parsed = parseFromStorage(storedValue);
    return parsed == null ? storedValue : formatFullDateTime(parsed);
  }
}
