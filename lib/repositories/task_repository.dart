import '../models/task.dart';
import '../services/storage_service.dart';

/// Contract defining persistence operations for tasks.
/// Abstracted so that local storage, SQLite, or future MCP/cloud sync
/// can be swapped in without modifying UI or state management layers.
abstract class TaskRepository {
  Future<List<Task>> getAllTasks();
  Future<void> saveAllTasks(List<Task> tasks);
}

/// Concrete implementation using [StorageService] (SharedPreferences).
class LocalTaskRepository implements TaskRepository {
  final StorageService _storageService;

  LocalTaskRepository({StorageService? storageService})
      : _storageService = storageService ?? StorageService();

  @override
  Future<List<Task>> getAllTasks() async {
    final rawList = await _storageService.loadTasks();
    final tasks = rawList.map((map) => Task.fromJson(map)).toList();

    // Default sorting:
    // 1. Uncompleted tasks first
    // 2. Nearest deadline first
    // 3. Higher priority first
    tasks.sort((a, b) {
      if (a.isCompleted != b.isCompleted) {
        return a.isCompleted ? 1 : -1;
      }
      final dateComparison = a.fullDueDateTime.compareTo(b.fullDueDateTime);
      if (dateComparison != 0) {
        return dateComparison;
      }
      return b.priority.sortWeight.compareTo(a.priority.sortWeight);
    });

    return tasks;
  }

  @override
  Future<void> saveAllTasks(List<Task> tasks) async {
    final rawList = tasks.map((task) => task.toJson()).toList();
    await _storageService.saveTasks(rawList);
  }
}
