import 'package:flutter/foundation.dart';
import '../models/priority.dart';
import '../models/task.dart';
import '../repositories/task_repository.dart';
import '../services/notification_service.dart';
import '../services/reminder_sync_service.dart';
import 'auth_provider.dart';

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
  final ReminderSyncService? _syncService;

  List<Task> _tasks = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  String _searchQuery = '';
  TaskFilter _selectedFilter = TaskFilter.all;
  String? Function()? _authTokenProvider;
  Future<String?> Function()? _tokenRefresher;
  VoidCallback? _onSessionExpired;
  String? _boundUserId;
  bool _wasAuthenticated = false;
  bool _hasSyncedForBoundUser = false;

  TaskProvider({
    TaskRepository? repository,
    NotificationService? notificationService,
    DateTime Function()? clock,
    ReminderSyncService? syncService,
    String? Function()? authTokenProvider,
    Future<String?> Function()? tokenRefresher,
    VoidCallback? onSessionExpired,
  })  : _repository = repository ?? LocalTaskRepository(),
        _notificationService = notificationService ?? NotificationService.instance,
        _clock = clock ?? DateTime.now,
        _authTokenProvider = authTokenProvider,
        _tokenRefresher = tokenRefresher,
        _onSessionExpired = onSessionExpired,
        _syncService = syncService {
    _effectiveSyncService = _syncService;
    loadTasks();
  }

  ReminderSyncService? _effectiveSyncService;

  ReminderSyncService? get _activeSyncService {
    if (_effectiveSyncService != null) return _effectiveSyncService;
    if (_syncService != null) return _syncService;
    _effectiveSyncService = ReminderSyncService(
      tokenRefresher: () async => await _tokenRefresher?.call(),
      onSessionExpired: () => _onSessionExpired?.call(),
    );
    return _effectiveSyncService;
  }

  // Getters
  List<Task> get allTasks => List.unmodifiable(_tasks);
  bool get isLoading => _isLoading;
  bool get isSyncing => _isSyncing;
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

  /// Returns only active/incomplete tasks.
  List<Task> get activeTasks =>
      _tasks.where((t) => !t.isCompleted).toList();

  /// Returns completed tasks sorted by completed date descending (newest first).
  List<Task> get historyTasks {
    final list = _tasks.where((t) => t.isCompleted).toList();
    list.sort((a, b) {
      final aTime = a.completedAt ?? a.updatedAt ?? a.createdAt;
      final bTime = b.completedAt ?? b.updatedAt ?? b.createdAt;
      return bTime.compareTo(aTime);
    });
    return list;
  }

  /// Returns tasks filtered by both the selected category and search query.
  List<Task> get filteredTasks {
    final now = _clock();
    return _tasks.where((task) {
      // 1. Filter by status / priority / time
      switch (_selectedFilter) {
        case TaskFilter.all:
          if (task.isCompleted) return false;
          break;
        case TaskFilter.pending:
          if (task.isCompleted) return false;
          break;
        case TaskFilter.today:
          if (task.isCompleted || !task.isDueOnDay(now)) return false;
          break;
        case TaskFilter.overdue:
          if (task.isCompleted || !task.isOverdueAt(now)) return false;
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

  /// Binds an [AuthProvider] to enable automatic JWT cloud synchronization
  /// and strictly isolate reminder caches across account sign-out / switches.
  void bindAuth(AuthProvider auth) {
    _authTokenProvider = () => auth.token;
    _tokenRefresher = auth.refreshSession;
    _onSessionExpired = auth.handleSessionExpired;

    if (auth.isLoading) {
      return;
    }

    final currentUserId = auth.currentUser?.id;
    final loggedOut = _wasAuthenticated && !auth.isAuthenticated;
    final switchedUser = _boundUserId != null &&
        currentUserId != null &&
        currentUserId.isNotEmpty &&
        currentUserId != _boundUserId;

    if (loggedOut || switchedUser) {
      _hasSyncedForBoundUser = false;
      _resetLocalAccountData();
    }

    _wasAuthenticated = auth.isAuthenticated;
    _boundUserId = currentUserId;

    if (auth.isAuthenticated && auth.token != null && !_hasSyncedForBoundUser) {
      _hasSyncedForBoundUser = true;
      syncWithCloud();
    }
  }

  Future<void> _resetLocalAccountData() async {
    _tasks = [];
    _searchQuery = '';
    _selectedFilter = TaskFilter.all;
    notifyListeners();
    try {
      await _repository.saveAllTasks([]);
    } catch (_) {}
    try {
      await _activeSyncService?.clearAllDeletedIds();
    } catch (_) {}
    try {
      await _notificationService.cancelAllNotifications();
    } catch (_) {}
  }

  /// Configures an explicit auth token provider function.
  void setAuthTokenProvider(String? Function()? provider) {
    _authTokenProvider = provider;
  }

  /// Reconciles device local notifications to match the merged task list after sync.
  Future<void> _reconcileNotifications(
    List<Task> previousTasks,
    List<Task> mergedTasks,
  ) async {
    final mergedMap = {for (final t in mergedTasks) t.id: t};
    for (final oldTask in previousTasks) {
      if (!mergedMap.containsKey(oldTask.id)) {
        try {
          await _notificationService.cancelTaskNotification(oldTask.notificationId);
        } catch (_) {}
      }
    }
    for (final task in mergedTasks) {
      try {
        if (task.isCompleted || !task.isNotificationEnabled) {
          await _notificationService.cancelTaskNotification(task.notificationId);
        } else {
          await _notificationService.scheduleTaskNotification(task);
        }
      } catch (_) {}
    }
  }

  /// Synchronizes local tasks with cloud backend using the authenticated JWT session.
  Future<SyncResult?> syncWithCloud() async {
    final token = _authTokenProvider?.call();
    final syncService = _activeSyncService;
    if (token == null || token.isEmpty || syncService == null) return null;

    _isSyncing = true;
    notifyListeners();

    try {
      final previousTasks = List<Task>.from(_tasks);
      final result = await syncService.sync(_tasks, token);
      if (result.success) {
        _tasks = result.mergedTasks;
        _sortTasks();
        await _repository.saveAllTasks(_tasks);
        await _reconcileNotifications(previousTasks, _tasks);
      }
      return result;
    } catch (_) {
      return null;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  /// Loads tasks from local repository into memory and initiates background cloud sync.
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

    await syncWithCloud();
  }

  /// Adds a new task locally and attempts cloud create.
  Future<void> addTask(Task task) async {
    _tasks.add(task);
    _sortTasks();
    notifyListeners();

    await _repository.saveAllTasks(_tasks);

    if (task.isNotificationEnabled && !task.isCompleted) {
      await _notificationService.scheduleTaskNotification(task);
    }

    final token = _authTokenProvider?.call();
    final syncService = _activeSyncService;
    if (token != null && token.isNotEmpty && syncService != null) {
      try {
        await syncService.createCloudReminder(task, token);
      } catch (_) {
        // Safe offline-first: Keep local reminder on cloud failure
      }
    }
  }

  /// Adds multiple tasks in batch locally, persists to repository, and schedules notifications.
  Future<void> addTasksBatch(List<Task> tasks) async {
    if (tasks.isEmpty) return;
    for (final task in tasks) {
      _tasks.removeWhere((t) => t.id == task.id);
      _tasks.add(task);
    }
    _sortTasks();
    notifyListeners();

    await _repository.saveAllTasks(_tasks);

    for (final task in tasks) {
      if (task.isNotificationEnabled && !task.isCompleted) {
        try {
          await _notificationService.scheduleTaskNotification(task);
        } catch (e) {
          debugPrint('Failed to schedule local notification for "${task.title}": $e');
        }
      }
    }
  }

  /// Updates an existing task locally and attempts cloud update.
  Future<void> updateTask(Task updatedTask) async {
    final index = _tasks.indexWhere((t) => t.id == updatedTask.id);
    if (index == -1) return;

    final oldTask = _tasks[index];
    final taskWithTimestamp = updatedTask.copyWith(
      updatedAt: DateTime.now(),
    );
    _tasks[index] = taskWithTimestamp;
    _sortTasks();
    notifyListeners();

    await _repository.saveAllTasks(_tasks);

    // Cancel old notification
    await _notificationService.cancelTaskNotification(oldTask.notificationId);

    // Schedule new notification if enabled and uncompleted
    if (taskWithTimestamp.isNotificationEnabled && !taskWithTimestamp.isCompleted) {
      await _notificationService.scheduleTaskNotification(taskWithTimestamp);
    }

    final token = _authTokenProvider?.call();
    final syncService = _activeSyncService;
    if (token != null && token.isNotEmpty && syncService != null) {
      try {
        await syncService.updateCloudReminder(taskWithTimestamp, token);
      } catch (_) {
        // Safe offline-first: Keep local reminder on cloud failure
      }
    }
  }

  /// Deletes a task by ID locally and attempts cloud delete.
  Future<void> deleteTask(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final removedTask = _tasks.removeAt(index);
    notifyListeners();

    await _repository.saveAllTasks(_tasks);
    await _notificationService.cancelTaskNotification(removedTask.notificationId);

    final syncService = _activeSyncService;
    // Record local deletion tombstone for safe offline propagation
    await syncService?.recordLocalDeletion(taskId);

    final token = _authTokenProvider?.call();
    if (token != null && token.isNotEmpty && syncService != null) {
      try {
        final ok = await syncService.deleteCloudReminder(taskId, token);
        if (ok) {
          await syncService.clearLocalDeletion(taskId);
        }
      } catch (_) {
        // Safe offline-first: tombstone preserved for subsequent sync
      }
    }
  }

  /// Toggles completion status of a task and syncs update.
  Future<void> toggleTaskStatus(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];
    final now = _clock();
    final newCompletedState = !task.isCompleted;
    final updatedTask = task.copyWith(
      isCompleted: newCompletedState,
      completedAt: newCompletedState ? (task.completedAt ?? now) : null,
      clearCompletedAt: !newCompletedState,
      updatedAt: now,
    );

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

    final token = _authTokenProvider?.call();
    final syncService = _activeSyncService;
    if (token != null && token.isNotEmpty && syncService != null) {
      try {
        await syncService.updateCloudReminder(updatedTask, token);
      } catch (_) {
        // Safe offline-first: Keep local status on cloud failure
      }
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
