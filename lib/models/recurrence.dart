import 'package:flutter/material.dart';

/// Represents repeating schedule interval of a reminder in "Don't Miss".
enum Recurrence {
  none,
  daily,
  weekly,
  monthly;

  String get label {
    switch (this) {
      case Recurrence.none:
        return 'None';
      case Recurrence.daily:
        return 'Daily';
      case Recurrence.weekly:
        return 'Weekly';
      case Recurrence.monthly:
        return 'Monthly';
    }
  }

  IconData get icon {
    switch (this) {
      case Recurrence.none:
        return Icons.do_not_disturb_on_outlined;
      case Recurrence.daily:
        return Icons.today_rounded;
      case Recurrence.weekly:
        return Icons.calendar_view_week_rounded;
      case Recurrence.monthly:
        return Icons.calendar_month_rounded;
    }
  }

  static Recurrence fromString(String? value) {
    if (value == null) return Recurrence.none;
    switch (value.toLowerCase()) {
      case 'daily':
        return Recurrence.daily;
      case 'weekly':
        return Recurrence.weekly;
      case 'monthly':
        return Recurrence.monthly;
      case 'none':
      default:
        return Recurrence.none;
    }
  }
}
