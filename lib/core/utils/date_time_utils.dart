import 'package:intl/intl.dart';

/// Utilities for human-friendly date and time formatting and comparisons.
class DateTimeUtils {
  DateTimeUtils._();

  static final DateFormat _dayMonthYearFormat = DateFormat('d MMMM yyyy');
  static final DateFormat _shortDateFormat = DateFormat('d MMM yyyy');

  /// Checks if two DateTimes share the same calendar day (ignoring time components).
  static bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Formats a date to "Today", "Tomorrow", "Yesterday", or "18 September 2026".
  static String formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDate = DateTime(date.year, date.month, date.day);

    final difference = targetDate.difference(today).inDays;

    if (difference == 0) {
      return 'Today';
    } else if (difference == 1) {
      return 'Tomorrow';
    } else if (difference == -1) {
      return 'Yesterday';
    } else {
      return _dayMonthYearFormat.format(date);
    }
  }

  /// Formats date into a short string, e.g. "18 Sep 2026".
  static String formatShortDate(DateTime date) {
    return _shortDateFormat.format(date);
  }

  /// Formats hour and minute into 12-hour AM/PM string, e.g. "9:00 PM".
  static String formatTime(int hour, int minute) {
    final now = DateTime.now();
    final dateTime = DateTime(now.year, now.month, now.day, hour, minute);
    return DateFormat('h:mm a').format(dateTime);
  }

  /// Constructs a full [DateTime] combining the date with hour and minute.
  static DateTime combineDateTime(DateTime date, int hour, int minute) {
    return DateTime(date.year, date.month, date.day, hour, minute);
  }

  /// Checks if a given task deadline is in the past.
  static bool isOverdue(DateTime date, int hour, int minute) {
    final scheduled = combineDateTime(date, hour, minute);
    return scheduled.isBefore(DateTime.now());
  }

  /// Human-friendly relative description of the deadline.
  static String getRelativeTimeDescription(DateTime date, int hour, int minute) {
    final target = combineDateTime(date, hour, minute);
    final now = DateTime.now();

    if (target.isBefore(now)) {
      final diff = now.difference(target);
      if (diff.inDays > 0) {
        return '${diff.inDays}d overdue';
      } else if (diff.inHours > 0) {
        return '${diff.inHours}h overdue';
      } else {
        return '${diff.inMinutes}m overdue';
      }
    } else {
      final diff = target.difference(now);
      if (diff.inDays > 0) {
        return 'in ${diff.inDays}d';
      } else if (diff.inHours > 0) {
        return 'in ${diff.inHours}h';
      } else if (diff.inMinutes > 0) {
        return 'in ${diff.inMinutes}m';
      } else {
        return 'Due now';
      }
    }
  }
}
