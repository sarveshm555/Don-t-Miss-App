import 'package:flutter/material.dart';

/// App-wide color constants designed for modern Material 3 aesthetics.
class AppColors {
  AppColors._();

  // Primary Brand Colors
  static const Color primary = Color(0xFF4F46E5); // Indigo
  static const Color primaryLight = Color(0xFF818CF8);
  static const Color primaryDark = Color(0xFF3730A3);
  static const Color secondary = Color(0xFF7C3AED); // Violet

  // Priority Colors
  static const Color priorityLow = Color(0xFF10B981); // Emerald Green
  static const Color priorityLowBg = Color(0xFFECFDF5);
  static const Color priorityMedium = Color(0xFFF59E0B); // Amber
  static const Color priorityMediumBg = Color(0xFFFFFBEB);
  static const Color priorityHigh = Color(0xFFEF4444); // Crimson Red
  static const Color priorityHighBg = Color(0xFFFEF2F2);

  // Neutral Colors (Light Theme)
  static const Color backgroundLight = Color(0xFFF8FAFC);
  static const Color surfaceLight = Colors.white;
  static const Color textPrimaryLight = Color(0xFF0F172A);
  static const Color textSecondaryLight = Color(0xFF64748B);
  static const Color borderLight = Color(0xFFE2E8F0);

  // Neutral Colors (Dark Theme)
  static const Color backgroundDark = Color(0xFF0F172A);
  static const Color surfaceDark = Color(0xFF1E293B);
  static const Color textPrimaryDark = Color(0xFFF8FAFC);
  static const Color textSecondaryDark = Color(0xFF94A3B8);
  static const Color borderDark = Color(0xFF334155);

  // Status Colors
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF3B82F6);
}
