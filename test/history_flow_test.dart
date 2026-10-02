import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/models/user_profile.dart';
import 'package:dont_miss/providers/auth_provider.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/screens/history_screen.dart';
import 'package:dont_miss/screens/home_screen.dart';
import 'package:dont_miss/screens/profile_screen.dart';
import 'package:dont_miss/services/agent_http_transport.dart';
import 'package:dont_miss/services/auth_service.dart';
import 'package:dont_miss/services/notification_service.dart';
import 'package:dont_miss/services/reminder_sync_service.dart';

class InMemoryTaskRepository implements TaskRepository {
  List<Task> tasks;
  InMemoryTaskRepository([List<Task>? initial]) : tasks = initial ?? [];

  @override
  Future<List<Task>> getAllTasks() async => List.from(tasks);

  @override
  Future<void> saveAllTasks(List<Task> newTasks) async {
    tasks = List.from(newTasks);
  }
}

class FakeNotificationService implements NotificationService {
  final List<int> cancelledNotificationIds = [];
  final List<Task> scheduledTasks = [];

  @override
  Future<void> init() async {}

  @override
  Future<bool?> requestPermissions() async => true;

  @override
  Future<void> scheduleTaskNotification(Task task) async {
    scheduledTasks.add(task);
  }

  @override
  Future<void> cancelTaskNotification(int notificationId) async {
    cancelledNotificationIds.add(notificationId);
  }

  @override
  Future<void> cancelAllNotifications() async {}
}

class FakeAuthService implements AuthService {
  UserProfile? user;
  FakeAuthService([this.user]);

  @override
  Future<UserProfile?> getCurrentUser() async => user;

  @override
  Future<bool> isAuthenticated() async => user != null;

  @override
  Future<UserProfile> signIn({required String phoneNumber, required String password}) async => user!;

  @override
  Future<UserProfile> signUp({required String name, required String phoneNumber, required String password}) async => user!;

  @override
  Future<bool> verifyPhone({required String phoneNumber, required String code}) async => true;

  @override
  Future<void> signOut() async {
    user = null;
  }
}

class FakeSyncTransport extends AgentHttpTransport {
  @override
  Future<AgentHttpResponse> get({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    return const AgentHttpResponse(statusCode: 200, body: '[]');
  }

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    return const AgentHttpResponse(statusCode: 200, body: '{}');
  }

  @override
  Future<AgentHttpResponse> putJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    return const AgentHttpResponse(statusCode: 200, body: '{}');
  }

  @override
  Future<AgentHttpResponse> delete({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    return const AgentHttpResponse(statusCode: 200, body: '{}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixedClock = DateTime(2026, 10, 2, 12, 0);

  final task1 = Task(
    id: 'task-active-1',
    title: 'File Tax Return',
    description: 'Submit by Friday noon',
    dueDate: DateTime(2026, 10, 5),
    dueHour: 15,
    dueMinute: 0,
    priority: Priority.high,
    recurrence: Recurrence.monthly,
    isCompleted: false,
    createdAt: DateTime(2026, 10, 1, 10, 0),
  );

  final task2 = Task(
    id: 'task-active-2',
    title: 'Buy Groceries',
    description: 'Milk, eggs, oats',
    dueDate: DateTime(2026, 10, 3),
    dueHour: 18,
    dueMinute: 30,
    priority: Priority.medium,
    recurrence: Recurrence.weekly,
    isCompleted: false,
    createdAt: DateTime(2026, 10, 1, 11, 0),
  );

  final taskCompleted = Task(
    id: 'task-done-1',
    title: 'Completed Project Review',
    description: 'Reviewed with team lead',
    dueDate: DateTime(2026, 10, 1),
    dueHour: 14,
    dueMinute: 0,
    priority: Priority.low,
    recurrence: Recurrence.none,
    isCompleted: true,
    completedAt: DateTime(2026, 10, 1, 14, 30),
    createdAt: DateTime(2026, 9, 30, 9, 0),
  );

  group('Task Model & Serialization Tests', () {
    test('Task model completedAt serialization to/from JSON', () {
      final completedTime = DateTime(2026, 10, 2, 11, 15);
      final task = Task(
        id: 'json-test-1',
        title: 'Review PR',
        dueDate: DateTime(2026, 10, 2),
        dueHour: 11,
        dueMinute: 0,
        isCompleted: true,
        completedAt: completedTime,
        createdAt: DateTime(2026, 10, 1),
      );

      final json = task.toJson();
      expect(json['completedAt'], completedTime.toIso8601String());

      final parsed = Task.fromJson(json);
      expect(parsed.completedAt, completedTime);
      expect(parsed.isCompleted, isTrue);
    });

    test('Task model fromJson supports snake_case completed_at from backend', () {
      final json = {
        'id': 'cloud-test-1',
        'title': 'Sync from Cloud',
        'dueDate': '2026-10-02T00:00:00.000',
        'dueHour': 10,
        'dueMinute': 0,
        'priority': 'high',
        'recurrence': 'daily',
        'isCompleted': true,
        'completed_at': '2026-10-02T10:30:00.000Z',
        'createdAt': '2026-10-01T08:00:00.000',
      };

      final parsed = Task.fromJson(json);
      expect(parsed.completedAt, DateTime.parse('2026-10-02T10:30:00.000Z'));
      expect(parsed.recurrence, Recurrence.daily);
      expect(parsed.isCompleted, isTrue);
    });

    test('ReminderSyncService parseCloudReminder and taskToCloudPayload preserve completed_at and recurrence', () {
      final task = Task(
        id: 'sync-task-1',
        title: 'Recurring Meeting',
        description: 'Standup update',
        dueDate: DateTime(2026, 10, 5),
        dueHour: 9,
        dueMinute: 30,
        priority: Priority.high,
        recurrence: Recurrence.daily,
        isCompleted: true,
        completedAt: DateTime(2026, 10, 5, 9, 45),
        createdAt: DateTime(2026, 10, 1),
      );

      final payload = ReminderSyncService.taskToCloudPayload(task);
      expect(payload['status'], 'COMPLETED');
      expect(payload['completed_at'], DateTime(2026, 10, 5, 9, 45).toIso8601String());
      expect(payload['recurrence'], 'daily');

      final cloudJson = {
        'id': 'sync-task-1',
        'title': 'Recurring Meeting',
        'description': 'Standup update',
        'due_date': '2026-10-05',
        'due_hour': 9,
        'due_minute': 30,
        'priority': 'high',
        'recurrence': 'daily',
        'status': 'COMPLETED',
        'completed_at': '2026-10-05T09:45:00.000',
        'created_at': '2026-10-01T08:00:00.000',
      };

      final reconstructed = ReminderSyncService.parseCloudReminder(cloudJson);
      expect(reconstructed.isCompleted, isTrue);
      expect(reconstructed.completedAt, DateTime.parse('2026-10-05T09:45:00.000'));
      expect(reconstructed.recurrence, Recurrence.daily);
    });
  });

  group('TaskProvider History Logic Unit Tests', () {
    late InMemoryTaskRepository repo;
    late FakeNotificationService notif;
    late TaskProvider provider;

    setUp(() async {
      repo = InMemoryTaskRepository([task1, task2, taskCompleted]);
      notif = FakeNotificationService();
      provider = TaskProvider(
        repository: repo,
        notificationService: notif,
        clock: () => fixedClock,
        syncService: ReminderSyncService(transport: FakeSyncTransport()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('Active task list under TaskFilter.all excludes completed tasks', () {
      provider.setFilter(TaskFilter.all);
      final activeList = provider.filteredTasks;
      expect(activeList.length, 2);
      expect(activeList.every((t) => !t.isCompleted), isTrue);
      expect(activeList.map((t) => t.id), containsAll(['task-active-1', 'task-active-2']));
      expect(activeList.map((t) => t.id), isNot(contains('task-done-1')));
    });

    test('historyTasks getter returns only completed tasks', () {
      final history = provider.historyTasks;
      expect(history.length, 1);
      expect(history.first.id, 'task-done-1');
      expect(history.first.isCompleted, isTrue);
      expect(history.first.completedAt, isNotNull);
    });

    test('Completing an active task immediately removes it from active list and moves to history', () async {
      provider.setFilter(TaskFilter.all);
      expect(provider.filteredTasks.length, 2);

      await provider.toggleTaskStatus('task-active-1');

      // Immediately removed from filtered active tasks
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.id, 'task-active-2');

      // Present in history tasks with timestamp
      expect(provider.historyTasks.length, 2);
      final completed = provider.historyTasks.firstWhere((t) => t.id == 'task-active-1');
      expect(completed.isCompleted, isTrue);
      expect(completed.completedAt, fixedClock);
      // Recurrence info is preserved
      expect(completed.recurrence, Recurrence.monthly);

      // Notification was cancelled
      expect(notif.cancelledNotificationIds, contains(task1.notificationId));

      // Persisted to repository
      final saved = await repo.getAllTasks();
      final savedTask1 = saved.firstWhere((t) => t.id == 'task-active-1');
      expect(savedTask1.isCompleted, isTrue);
      expect(savedTask1.completedAt, fixedClock);
    });

    test('Re-opening a completed task restores it to active list and clears completedAt', () async {
      expect(provider.historyTasks.length, 1);

      await provider.toggleTaskStatus('task-done-1');

      // History is now empty
      expect(provider.historyTasks.length, 0);

      // Present in active list
      provider.setFilter(TaskFilter.all);
      expect(provider.filteredTasks.any((t) => t.id == 'task-done-1'), isTrue);
      final restored = provider.filteredTasks.firstWhere((t) => t.id == 'task-done-1');
      expect(restored.isCompleted, isFalse);
      expect(restored.completedAt, isNull);
    });
  });

  group('HistoryScreen and ProfileScreen Widget Tests', () {
    late InMemoryTaskRepository repo;
    late FakeNotificationService notif;
    late TaskProvider taskProvider;
    late AuthProvider authProvider;

    final testUser = UserProfile(
      id: 'usr-100',
      name: 'Alice Wonder',
      phoneNumber: '+15551234567',
      createdAt: DateTime(2026, 1, 1),
    );

    setUp(() async {
      repo = InMemoryTaskRepository([task1, taskCompleted]);
      notif = FakeNotificationService();
      taskProvider = TaskProvider(
        repository: repo,
        notificationService: notif,
        clock: () => fixedClock,
        syncService: ReminderSyncService(transport: FakeSyncTransport()),
      );
      final authService = FakeAuthService(testUser);
      authProvider = AuthProvider(authService: authService);
      await authProvider.loadUser();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    Widget createTestApp(Widget homeWidget) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: taskProvider),
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ],
        child: MaterialApp(
          home: homeWidget,
        ),
      );
    }

    testWidgets('HistoryScreen displays completed reminder with details, recurrence, and checkmark', (tester) async {
      await tester.pumpWidget(createTestApp(const HistoryScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Reminder History'), findsOneWidget);
      expect(find.text('Completed Project Review'), findsOneWidget);
      expect(find.text('Reviewed with team lead'), findsOneWidget);
      expect(find.textContaining('Due:'), findsOneWidget);
      expect(find.textContaining('Completed:'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

      // Verify NO strike-through on history screen title
      final titleWidget = tester.widget<Text>(find.text('Completed Project Review'));
      expect(titleWidget.style?.decoration, isNot(TextDecoration.lineThrough));
    });

    testWidgets('HistoryScreen displays empty state when no completed reminders exist', (tester) async {
      final emptyRepo = InMemoryTaskRepository([task1]);
      final emptyProvider = TaskProvider(
        repository: emptyRepo,
        notificationService: notif,
        clock: () => fixedClock,
        syncService: ReminderSyncService(transport: FakeSyncTransport()),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<TaskProvider>.value(value: emptyProvider),
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ],
          child: const MaterialApp(
            home: HistoryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No completed reminders yet'), findsOneWidget);
      expect(find.text('Reminders you mark as completed will appear here.'), findsOneWidget);
    });

    testWidgets('Reopening a task in HistoryScreen moves it to active list', (tester) async {
      await tester.pumpWidget(createTestApp(const HistoryScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Completed Project Review'), findsOneWidget);

      final reopenButton = find.byKey(const Key('reopen_task_task-done-1'));
      expect(reopenButton, findsOneWidget);
      await tester.tap(reopenButton);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      // Should now show empty state in history
      expect(find.text('No completed reminders yet'), findsOneWidget);
      // And task is back in active
      expect(taskProvider.activeTasks.any((t) => t.id == 'task-done-1'), isTrue);
    });

    testWidgets('ProfileScreen displays user info, stats, and Reminder History tile that navigates to HistoryScreen', (tester) async {
      await tester.pumpWidget(createTestApp(const ProfileScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Alice Wonder'), findsOneWidget);
      expect(find.text('+15551234567'), findsOneWidget);
      expect(find.text('Member since 1 January 2026'), findsOneWidget);

      final historyTile = find.byKey(const Key('profile_history_tile'));
      expect(historyTile, findsOneWidget);
      expect(find.text('Reminder History'), findsOneWidget);
      expect(find.text('1 completed reminder'), findsOneWidget);

      // Tap History tile
      await tester.tap(historyTile);
      await tester.pumpAndSettle();

      // Navigates to HistoryScreen
      expect(find.byType(HistoryScreen), findsOneWidget);
      expect(find.text('Completed Project Review'), findsOneWidget);
    });

    testWidgets('HomeScreen AppBar has history action button navigating to HistoryScreen', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestApp(const HomeScreen()));
      await tester.pumpAndSettle();

      final historyButton = find.byKey(const Key('home_history_action_button'));
      expect(historyButton, findsOneWidget);

      await tester.tap(historyButton);
      await tester.pumpAndSettle();

      expect(find.byType(HistoryScreen), findsOneWidget);
      expect(find.text('Completed Project Review'), findsOneWidget);
    });
  });
}
