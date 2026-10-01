import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles low-level persistence using SharedPreferences.
class StorageService {
  static const String _tasksKey = 'dont_miss_saved_tasks_v1';

  /// Loads list of raw task maps from local preferences.
  Future<List<Map<String, dynamic>>> loadTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_tasksKey);

    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> decoded = jsonDecode(jsonString);
      return decoded.map((item) => Map<String, dynamic>.from(item as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Saves list of raw task maps to local preferences.
  Future<void> saveTasks(List<Map<String, dynamic>> rawTasks) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = jsonEncode(rawTasks);
    await prefs.setString(_tasksKey, jsonString);
  }

  /// Clears all stored tasks.
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tasksKey);
  }
}
