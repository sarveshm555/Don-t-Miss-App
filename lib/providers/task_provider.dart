import 'package:flutter/foundation.dart';
import '../models/priority.dart';
import '../models/task.dart';
import '../repositories/task_repository.dart';
import '../services/notification_service.dart';

enum TaskFilter {
  all,
  pending,
  today,
  overdue,
  highPriority,
  completed,
}

/// Central state manager for task CRUD operations, filters, search, and notification synchronization.
class TaskProvider extends ChangeNotifier {
  final TaskRepository _repository;
  final NotificationService _notificationService;
  final DateTime Function() _clock;

  List<Task> _tasks = [];
  bool _isLoading = true;
  String _searchQuery = '';
  TaskFilter _selectedFilter = TaskFilter.all;

  TaskProvider({
    TaskRepository? repository,
    NotificationService? notificationService,
    DateTime Function()? clock,
  })  : _repository = repository ?? LocalTaskRepository(),
        _notificationService = notificationService ?? NotificationService.instance,
        _clock = clock ?? DateTime.now {
    loadTasks();
  }

  // Getters
  List<Task> get allTasks => List.unmodifiable(_tasks);
  bool get isLoading => _isLoading;
  String get searchQuery => _searchQuery;
  TaskFilter get selectedFilter => _selectedFilter;

  int get totalCount => _tasks.length;
  int get pendingCount => _tasks.where((t) => !t.isCompleted).length;
  int get completedCount => _tasks.where((t) => t.isCompleted).length;
  int get highPriorityCount =>
      _tasks.where((t) => !t.isCompleted && t.priority == Priority.high).length;
  int get todayCount =>
      _tasks.where((t) => t.isDueOnDay(_clock())).length;
  int get overdueCount =>
      _tasks.where((t) => t.isOverdueAt(_clock())).length;

  /// Returns tasks filtered by both the selected category and search query.
  List<Task> get filteredTasks {
    final now = _clock();
    return _tasks.where((task) {
      // 1. Filter by status / priority / time
      switch (_selectedFilter) {
        case TaskFilter.all:
          break;
        case TaskFilter.pending:
          if (task.isCompleted) return false;
          break;
        case TaskFilter.today:
          if (!task.isDueOnDay(now)) return false;
          break;
        case TaskFilter.overdue:
          if (!task.isOverdueAt(now)) return false;
          break;
        case TaskFilter.highPriority:
          if (task.isCompleted || task.priority != Priority.high) return false;
          break;
        case TaskFilter.completed:
          if (!task.isCompleted) return false;
          break;
      }

      // 2. Filter by search query
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final matchesTitle = task.title.toLowerCase().contains(query);
        final matchesDescription = task.description.toLowerCase().contains(query);
        if (!matchesTitle && !matchesDescription) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  /// Sets active filter chip.
  void setFilter(TaskFilter filter) {
    _selectedFilter = filter;
    notifyListeners();
  }

  /// Sets search query.
  void setSearchQuery(String query) {
    _searchQuery = query.trim();
    notifyListeners();
  }

  /// Clears active search query.
  void clearSearch() {
    _searchQuery = '';
    notifyListeners();
  }

  /// Loads tasks from local repository into memory.
  Future<void> loadTasks() async {
    _isLoading = true;
    notifyListeners();

    try {
      _tasks = await _repository.getAllTasks();
    } catch (_) {
      _tasks = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Adds a new task and schedules notification if enabled.
  Future<void> addTask(Task task) async {
    _tasks.add(task);
    _sortTasks();
    notifyListeners();

    await _repository.saveAllTasks(_tasks);

    if (task.isNotificationEnabled && !task.isCompleted) {
      await _notificationService.scheduleTaskNotification(task);
    }
  }

  /// Updates an existing task and reschedules notification.
  Future<void> updateTask(Task updatedTask) async {
    final index = _tasks.indexWhere((t) => t.id == updatedTask.id);
    if (index == -1) return;

    final oldTask = _tasks[index];
    _tasks[index] = updatedTask;
    _sortTasks();
    notifyListeners();

    await _repository.saveAllTasks(_tasks);

    // Cancel old notification
    await _notificationService.cancelTaskNotification(oldTask.notificationId);

    // Schedule new notification if enabled and uncompleted
    if (updatedTask.isNotificationEnabled && !updatedTask.isCompleted) {
      await _notificationService.scheduleTaskNotification(updatedTask);
    }
  }

  /// Deletes a task by ID and cancels its scheduled notification.
  Future<void> deleteTask(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final removedTask = _tasks.removeAt(index);
    notifyListeners();

    await _repository.saveAllTasks(_tasks);
    await _notificationService.cancelTaskNotification(removedTask.notificationId);
  }

  /// Toggles completion status of a task.
  Future<void> toggleTaskStatus(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];
    final newCompletedState = !task.isCompleted;
    final updatedTask = task.copyWith(isCompleted: newCompletedState);

    _tasks[index] = updatedTask;
    _sortTasks();
    notifyListeners();

    await _repository.saveAllTasks(_tasks);

    if (newCompletedState) {
      // Completed -> cancel scheduled notification
      await _notificationService.cancelTaskNotification(task.notificationId);
    } else if (updatedTask.isNotificationEnabled) {
      // Uncompleted -> reschedule if not overdue
      await _notificationService.scheduleTaskNotification(updatedTask);
    }
  }

  void _sortTasks() {
    _tasks.sort((a, b) {
      if (a.isCompleted != b.isCompleted) {
        return a.isCompleted ? 1 : -1;
      }
      final dateComp = a.fullDueDateTime.compareTo(b.fullDueDateTime);
      if (dateComp != 0) return dateComp;
      return b.priority.sortWeight.compareTo(a.priority.sortWeight);
    });
  }
}
