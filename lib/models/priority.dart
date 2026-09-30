import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

/// Represents the urgency/priority level of a task.
enum Priority {
  low,
  medium,
  high;

  String get label {
    switch (this) {
      case Priority.low:
        return 'Low';
      case Priority.medium:
        return 'Medium';
      case Priority.high:
        return 'High';
    }
  }

  Color get color {
    switch (this) {
      case Priority.low:
        return AppColors.priorityLow;
      case Priority.medium:
        return AppColors.priorityMedium;
      case Priority.high:
        return AppColors.priorityHigh;
    }
  }

  Color get backgroundColor {
    switch (this) {
      case Priority.low:
        return AppColors.priorityLowBg;
      case Priority.medium:
        return AppColors.priorityMediumBg;
      case Priority.high:
        return AppColors.priorityHighBg;
    }
  }

  IconData get icon {
    switch (this) {
      case Priority.low:
        return Icons.keyboard_arrow_down_rounded;
      case Priority.medium:
        return Icons.remove_rounded;
      case Priority.high:
        return Icons.keyboard_double_arrow_up_rounded;
    }
  }

  int get sortWeight {
    switch (this) {
      case Priority.high:
        return 3;
      case Priority.medium:
        return 2;
      case Priority.low:
        return 1;
    }
  }

  static Priority fromString(String? value) {
    if (value == null) return Priority.medium;
    switch (value.toLowerCase()) {
      case 'low':
        return Priority.low;
      case 'high':
        return Priority.high;
      case 'medium':
      default:
        return Priority.medium;
    }
  }
}
