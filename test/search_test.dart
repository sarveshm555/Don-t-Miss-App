import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
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

/// Fake notification service to prevent native plugin calls during tests.
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
  final testDate = DateTime(2026, 9, 20);
  final sampleTasks = [
    Task(
      id: 'task-1',
      title: 'Amazon Interview Prep',
      description: 'Review system design architectures & AWS services',
      dueDate: testDate,
      dueHour: 10,
      dueMinute: 0,
      priority: Priority.high,
      recurrence: Recurrence.none,
      createdAt: testDate,
    ),
    Task(
      id: 'task-2',
      title: 'Grocery shopping',
      description: 'Buy milk, eggs, apples, and bananas',
      dueDate: testDate,
      dueHour: 15,
      dueMinute: 30,
      priority: Priority.low,
      recurrence: Recurrence.weekly,
      createdAt: testDate,
    ),
    Task(
      id: 'task-3',
      title: 'WeMakeDevs Hackathon Submission',
      description: 'Push final commits and verify GitHub repository',
      dueDate: testDate,
      dueHour: 18,
      dueMinute: 0,
      priority: Priority.high,
      recurrence: Recurrence.none,
      createdAt: testDate,
    ),
    Task(
      id: 'task-4',
      title: 'Pay electric bill',
      description: 'Utility payment due before end of month',
      dueDate: testDate,
      dueHour: 20,
      dueMinute: 0,
      priority: Priority.medium,
      isCompleted: true,
      recurrence: Recurrence.monthly,
      createdAt: testDate,
    ),
  ];

  group('TaskProvider Search Logic Unit Tests', () {
    late FakeTaskRepository repository;
    late FakeNotificationService notificationService;
    late TaskProvider provider;

    setUp(() async {
      repository = FakeTaskRepository(sampleTasks);
      notificationService = FakeNotificationService();
      provider = TaskProvider(
        repository: repository,
        notificationService: notificationService,
      );
      // Wait for async loadTasks to finish
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('Empty search query returns all reminders', () {
      provider.setSearchQuery('');
      expect(provider.filteredTasks.length, 4);
      expect(provider.searchQuery, isEmpty);
    });

    test('Whitespace-only query trims to empty and returns all reminders', () {
      provider.setSearchQuery('   ');
      expect(provider.filteredTasks.length, 4);
      expect(provider.searchQuery, isEmpty);
    });

    test('Case-insensitive title matching', () {
      // Lowercase match
      provider.setSearchQuery('amazon');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.title, 'Amazon Interview Prep');

      // Uppercase query
      provider.setSearchQuery('AMAZON');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.title, 'Amazon Interview Prep');

      // Partial title match
      provider.setSearchQuery('wemake');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.title, 'WeMakeDevs Hackathon Submission');
    });

    test('Case-insensitive description matching', () {
      // Match keyword 'architectures' in description
      provider.setSearchQuery('architectures');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.title, 'Amazon Interview Prep');

      // Case-insensitive uppercase 'APPLES' in description
      provider.setSearchQuery('APPLES');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.title, 'Grocery shopping');

      // Match 'github' in description
      provider.setSearchQuery('github');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.title, 'WeMakeDevs Hackathon Submission');
    });

    test('Query with no matches returns empty list', () {
      provider.setSearchQuery('NonExistentTermXYZ');
      expect(provider.filteredTasks, isEmpty);
    });

    test('Clearing search resets to all reminders', () {
      provider.setSearchQuery('amazon');
      expect(provider.filteredTasks.length, 1);

      provider.clearSearch();
      expect(provider.searchQuery, isEmpty);
      expect(provider.filteredTasks.length, 4);
    });

    test('Search query combined with filter chips', () {
      // High priority filter + search
      provider.setFilter(TaskFilter.highPriority);
      expect(provider.filteredTasks.length, 2); // Amazon Prep & WeMakeDevs Hackathon

      provider.setSearchQuery('amazon');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.id, 'task-1');

      // Completed filter + search
      provider.setFilter(TaskFilter.completed);
      provider.setSearchQuery('bill');
      expect(provider.filteredTasks.length, 1);
      expect(provider.filteredTasks.first.id, 'task-4');

      // Completed filter + search for uncompleted task
      provider.setSearchQuery('amazon');
      expect(provider.filteredTasks, isEmpty);
    });
  });

  group('HomeScreen Search Widget Tests', () {
    late FakeTaskRepository repository;
    late FakeNotificationService notificationService;
    late TaskProvider provider;

    setUp(() async {
      repository = FakeTaskRepository(sampleTasks);
      notificationService = FakeNotificationService();
      provider = TaskProvider(
        repository: repository,
        notificationService: notificationService,
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

    testWidgets('Renders search input field with placeholder', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Search tasks, deadlines, keywords...'), findsOneWidget);
      expect(find.byType(TaskCard), findsNWidgets(4));
    });

    testWidgets('Typing into search field filters reminder list', (tester) async {
      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      // Enter search term
      await tester.enterText(find.byType(TextField), 'Grocery');
      await tester.pumpAndSettle();

      expect(find.byType(TaskCard), findsOneWidget);
      expect(find.text('Grocery shopping'), findsOneWidget);
      expect(find.text('Amazon Interview Prep'), findsNothing);
    });

    testWidgets('Clear button appears and tapping it clears search', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      // Enter text
      await tester.enterText(find.byType(TextField), 'Hackathon');
      await tester.pumpAndSettle();

      expect(find.byType(TaskCard), findsOneWidget);
      expect(find.byIcon(Icons.clear), findsOneWidget);

      // Tap clear icon
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      // All tasks should be restored
      expect(find.byType(TaskCard), findsNWidgets(4));
    });

    testWidgets('Query with no matches displays EmptyStateView with Clear Search button', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'qwertyuiop');
      await tester.pumpAndSettle();

      expect(find.byType(TaskCard), findsNothing);
      expect(find.byType(EmptyStateView), findsOneWidget);
      expect(find.text('No matching reminders'), findsOneWidget);
      expect(find.text('Try searching with different keywords.'), findsOneWidget);
      expect(find.text('Clear Search'), findsOneWidget);

      // Tapping "Clear Search" restores the list
      await tester.tap(find.text('Clear Search'));
      await tester.pumpAndSettle();

      expect(find.byType(TaskCard), findsNWidgets(4));
    });
  });
}
