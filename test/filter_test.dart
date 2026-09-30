import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/screens/home_screen.dart';
import 'package:dont_miss/services/notification_service.dart';
import 'package:dont_miss/widgets/empty_state_view.dart';
import 'package:dont_miss/widgets/task_card.dart';

/// Fake in-memory repository for isolated unit/widget tests.
class FakeTaskRepository implements TaskRepository {
  List<Task> _tasks;

  FakeTaskRepository(this._tasks);

  @override
  Future<List<Task>> getAllTasks() async => List.from(_tasks);

  @override
  Future<void> saveAllTasks(List<Task> tasks) async {
    _tasks = List.from(tasks);
  }
}

/// Fake notification service to avoid native plugin calls.
class FakeNotificationService implements NotificationService {
  @override
  Future<void> init() async {}

  @override
  Future<bool?> requestPermissions() async => true;

  @override
  Future<void> scheduleTaskNotification(Task task) async {}

  @override
  Future<void> cancelTaskNotification(int notificationId) async {}

  @override
  Future<void> cancelAllNotifications() async {}
}

void main() {
  // Deterministic reference time: Sunday, 20 September 2026 at 2:00 PM
  final fixedNow = DateTime(2026, 9, 20, 14, 0);

  final sampleTasks = [
    // 1. Due today, 4:00 PM, uncompleted, medium priority
    Task(
      id: 'task-today-pending',
      title: 'Submit Hackathon Project',
      description: 'AWS and GitHub repository links',
      dueDate: DateTime(2026, 9, 20),
      dueHour: 16,
      dueMinute: 0,
      priority: Priority.medium,
      isCompleted: false,
      createdAt: DateTime(2026, 9, 18),
    ),
    // 2. Due today, 10:00 AM, completed, high priority
    Task(
      id: 'task-today-completed',
      title: 'Morning standup',
      description: 'Review daily goals with team',
      dueDate: DateTime(2026, 9, 20),
      dueHour: 10,
      dueMinute: 0,
      priority: Priority.high,
      isCompleted: true,
      createdAt: DateTime(2026, 9, 18),
    ),
    // 3. Due yesterday, overdue, uncompleted, high priority
    Task(
      id: 'task-overdue-pending',
      title: 'Pay AWS cloud invoice',
      description: 'Overdue server infrastructure bill',
      dueDate: DateTime(2026, 9, 19),
      dueHour: 18,
      dueMinute: 0,
      priority: Priority.high,
      isCompleted: false,
      createdAt: DateTime(2026, 9, 15),
    ),
    // 4. Due 2 days ago, overdue date, completed, high priority
    Task(
      id: 'task-overdue-completed',
      title: 'Renew domain name',
      description: 'Completed past domain renewal',
      dueDate: DateTime(2026, 9, 18),
      dueHour: 12,
      dueMinute: 0,
      priority: Priority.high,
      isCompleted: true,
      createdAt: DateTime(2026, 9, 15),
    ),
    // 5. Future task, uncompleted, high priority
    Task(
      id: 'task-future-pending-high',
      title: 'System Architecture Review',
      description: 'Deep dive into microservices',
      dueDate: DateTime(2026, 9, 25),
      dueHour: 11,
      dueMinute: 0,
      priority: Priority.high,
      isCompleted: false,
      createdAt: DateTime(2026, 9, 18),
    ),
    // 6. Future task, uncompleted, low priority
    Task(
      id: 'task-future-pending-low',
      title: 'Grocery shopping',
      description: 'Buy snacks for team',
      dueDate: DateTime(2026, 9, 28),
      dueHour: 9,
      dueMinute: 0,
      priority: Priority.low,
      isCompleted: false,
      createdAt: DateTime(2026, 9, 18),
    ),
  ];

  group('TaskProvider Filter Logic Unit Tests', () {
    late FakeTaskRepository repository;
    late FakeNotificationService notificationService;
    late TaskProvider provider;

    setUp(() async {
      repository = FakeTaskRepository(sampleTasks);
      notificationService = FakeNotificationService();
      provider = TaskProvider(
        repository: repository,
        notificationService: notificationService,
        clock: () => fixedNow,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('Accurate filter count getters', () {
      expect(provider.totalCount, 6);
      expect(provider.pendingCount, 4);
      expect(provider.completedCount, 2);
      expect(provider.todayCount, 1); // only uncompleted today
      expect(provider.overdueCount, 1); // only uncompleted overdue
      expect(provider.highPriorityCount, 2); // only uncompleted high priority
    });

    test('TaskFilter.all returns all reminders', () {
      provider.setFilter(TaskFilter.all);
      expect(provider.filteredTasks.length, 6);
      expect(provider.filteredTasks.length, provider.totalCount);
    });

    test('TaskFilter.pending returns only uncompleted reminders', () {
      provider.setFilter(TaskFilter.pending);
      expect(provider.filteredTasks.length, 4);
      expect(provider.filteredTasks.length, provider.pendingCount);
      expect(provider.filteredTasks.every((t) => !t.isCompleted), isTrue);
    });

    test('TaskFilter.today returns only uncompleted reminders due on calendar today', () {
      provider.setFilter(TaskFilter.today);
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.length, provider.todayCount);
      expect(provider.filteredTasks.first.id, 'task-today-pending');
      expect(provider.filteredTasks.first.title, 'Submit Hackathon Project');
    });

    test('TaskFilter.overdue returns only uncompleted overdue reminders', () {
      provider.setFilter(TaskFilter.overdue);
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.length, provider.overdueCount);
      expect(provider.filteredTasks.first.id, 'task-overdue-pending');
      expect(provider.filteredTasks.first.title, 'Pay AWS cloud invoice');
    });

    test('TaskFilter.highPriority returns ONLY uncompleted high-priority reminders', () {
      provider.setFilter(TaskFilter.highPriority);
      expect(provider.filteredTasks.length, 2);
      expect(provider.filteredTasks.length, provider.highPriorityCount);

      // Verify IDs: only pending high priority tasks are present
      final ids = provider.filteredTasks.map((t) => t.id).toSet();
      expect(ids, contains('task-overdue-pending'));
      expect(ids, contains('task-future-pending-high'));

      // Crucial: completed high-priority tasks must NOT appear
      expect(ids, isNot(contains('task-today-completed')));
      expect(ids, isNot(contains('task-overdue-completed')));
    });

    test('TaskFilter.completed returns only completed reminders', () {
      provider.setFilter(TaskFilter.completed);
      expect(provider.filteredTasks.length, 2);
      expect(provider.filteredTasks.length, provider.completedCount);
      expect(provider.filteredTasks.every((t) => t.isCompleted), isTrue);
    });

    test('Search + Today filter composition', () {
      provider.setFilter(TaskFilter.today);

      // Matches description of today's task
      provider.setSearchQuery('GitHub');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.id, 'task-today-pending');

      // Query for an overdue task returns empty under today filter
      provider.setSearchQuery('invoice');
      expect(provider.filteredTasks, isEmpty);
    });

    test('Search + Overdue filter composition', () {
      provider.setFilter(TaskFilter.overdue);

      // Matches title of overdue task
      provider.setSearchQuery('AWS');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.id, 'task-overdue-pending');

      // Query for today's task returns empty under overdue filter
      provider.setSearchQuery('hackathon');
      expect(provider.filteredTasks, isEmpty);
    });

    test('Empty filter results when no items match', () {
      // Empty task list repository
      final emptyProvider = TaskProvider(
        repository: FakeTaskRepository([]),
        notificationService: notificationService,
        clock: () => fixedNow,
      );

      emptyProvider.setFilter(TaskFilter.today);
      expect(emptyProvider.filteredTasks, isEmpty);
      expect(emptyProvider.todayCount, 0);

      emptyProvider.setFilter(TaskFilter.overdue);
      expect(emptyProvider.filteredTasks, isEmpty);
      expect(emptyProvider.overdueCount, 0);
    });
  });

  group('HomeScreen Filter Chips Widget Tests', () {
    late FakeTaskRepository repository;
    late FakeNotificationService notificationService;
    late TaskProvider provider;

    setUp(() async {
      repository = FakeTaskRepository(sampleTasks);
      notificationService = FakeNotificationService();
      provider = TaskProvider(
        repository: repository,
        notificationService: notificationService,
        clock: () => fixedNow,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    Widget createWidgetUnderTest() {
      return ChangeNotifierProvider<TaskProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: HomeScreen(),
        ),
      );
    }

    testWidgets('Renders all 6 filter chips with accurate counts', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('All (6)'), findsOneWidget);
      expect(find.text('Pending (4)'), findsOneWidget);
      expect(find.text('Today (1)'), findsOneWidget);
      expect(find.text('Overdue (1)'), findsOneWidget);
      expect(find.text('High Priority (2)'), findsOneWidget);
      expect(find.text('Completed (2)'), findsOneWidget);
    });

    testWidgets('Tapping Today chip filters reminder list', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Today (1)'));
      await tester.pumpAndSettle();

      expect(find.byType(TaskCard), findsOneWidget);
      expect(find.text('Submit Hackathon Project'), findsOneWidget);
    });

    testWidgets('Tapping Overdue chip filters reminder list', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Overdue (1)'));
      await tester.pumpAndSettle();

      expect(find.byType(TaskCard), findsOneWidget);
      expect(find.text('Pay AWS cloud invoice'), findsOneWidget);
    });

    testWidgets('Empty filter state displays proper title and message for Today and Overdue', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Create an empty provider
      final emptyProvider = TaskProvider(
        repository: FakeTaskRepository([]),
        notificationService: notificationService,
        clock: () => fixedNow,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<TaskProvider>.value(
          value: emptyProvider,
          child: const MaterialApp(
            home: HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Today chip
      await tester.tap(find.text('Today (0)'));
      await tester.pumpAndSettle();

      expect(find.byType(EmptyStateView), findsOneWidget);
      expect(find.text('Nothing due today'), findsOneWidget);
      expect(find.text('You have no reminders scheduled for today.'), findsOneWidget);

      // Tap Overdue chip
      await tester.tap(find.text('Overdue (0)'));
      await tester.pumpAndSettle();

      expect(find.byType(EmptyStateView), findsOneWidget);
      expect(find.text('No overdue reminders'), findsOneWidget);
      expect(find.text('Great job! None of your reminders are overdue.'), findsOneWidget);
    });
  });
}
