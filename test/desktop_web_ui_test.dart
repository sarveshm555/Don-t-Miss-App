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
import 'package:dont_miss/screens/home_screen.dart';
import 'package:dont_miss/screens/sign_in_screen.dart';
import 'package:dont_miss/services/auth_service.dart';
import 'package:dont_miss/services/notification_service.dart';
import 'package:dont_miss/widgets/desktop/desktop_sidebar.dart';
import 'package:dont_miss/widgets/desktop/desktop_ai_centerpiece.dart';
import 'package:dont_miss/widgets/desktop/desktop_task_card.dart';

class FakeTaskRepository implements TaskRepository {
  List<Task> _tasks;
  FakeTaskRepository([List<Task>? tasks]) : _tasks = tasks ?? [];

  @override
  Future<List<Task>> getAllTasks() async => List.from(_tasks);

  @override
  Future<void> saveAllTasks(List<Task> tasks) async {
    _tasks = List.from(tasks);
  }
}

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

class FakeAuthService implements AuthService {
  UserProfile? currentUser;

  @override
  Future<UserProfile?> getCurrentUser() async => currentUser;
  @override
  Future<bool> isAuthenticated() async => currentUser != null;
  @override
  Future<UserProfile> signIn({required String phoneNumber, required String password}) async =>
      currentUser!;
  @override
  Future<UserProfile> signUp(
          {required String name, required String phoneNumber, required String password}) async =>
      currentUser!;
  @override
  Future<bool> verifyPhone({required String phoneNumber, required String code}) async => true;
  @override
  Future<void> signOut() async {
    currentUser = null;
  }
}

void main() {
  final testDate = DateTime(2026, 10, 15);

  group('Desktop Web UI Redesign Tests', () {
    late FakeTaskRepository repository;
    late FakeNotificationService notificationService;
    late FakeAuthService authService;
    late TaskProvider taskProvider;
    late AuthProvider authProvider;

    setUp(() async {
      final sampleTasks = [
        Task(
          id: 'task-1',
          title: 'System Design Interview',
          description: 'Review distributed consensus algorithms',
          dueDate: testDate,
          dueHour: 15,
          dueMinute: 0,
          priority: Priority.high,
          recurrence: Recurrence.none,
          createdAt: testDate,
        ),
        Task(
          id: 'task-2',
          title: 'Weekly Standup',
          description: 'Sync with product and engineering teams',
          dueDate: testDate,
          dueHour: 10,
          dueMinute: 0,
          priority: Priority.medium,
          recurrence: Recurrence.weekly,
          createdAt: testDate,
        ),
        Task(
          id: 'task-3',
          title: 'Pay Cloud Invoice',
          description: 'AWS & Supabase infrastructure billing',
          dueDate: testDate,
          dueHour: 18,
          dueMinute: 0,
          priority: Priority.low,
          isCompleted: true,
          completedAt: testDate,
          recurrence: Recurrence.monthly,
          createdAt: testDate,
        ),
      ];

      repository = FakeTaskRepository(sampleTasks);
      notificationService = FakeNotificationService();
      authService = FakeAuthService()
        ..currentUser = UserProfile(
          id: 'usr-desktop-1',
          name: 'Sarah Connor',
          phoneNumber: '+15559876543',
          createdAt: DateTime(2026, 1, 1),
        );

      taskProvider = TaskProvider(
        repository: repository,
        notificationService: notificationService,
      );
      authProvider = AuthProvider(authService: authService);

      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    Widget createTestApp(Widget home) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<TaskProvider>.value(value: taskProvider),
        ],
        child: MaterialApp(
          home: home,
        ),
      );
    }

    testWidgets('Desktop layout renders sidebar, AI centerpiece, stats, and desktop task cards at 1440x900',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestApp(const HomeScreen()));
      await tester.pumpAndSettle();

      // 1. Sidebar is present on desktop
      expect(find.byType(DesktopSidebar), findsOneWidget);
      expect(find.text("Don't Miss"), findsWidgets);
      expect(find.text('Action Agent'), findsOneWidget);
      expect(find.text('Dashboard'), findsWidgets);
      expect(find.text('Active Reminders'), findsWidgets);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);

      // 2. AI Centerpiece is visible and prominent
      expect(find.byType(DesktopAiCenterpiece), findsOneWidget);
      expect(find.text('AI Personal Action Agent'), findsOneWidget);
      expect(find.text('AI proposes. Human decides. Application executes.'), findsWidgets);

      // 3. Desktop Task Cards are rendered for active tasks
      expect(find.byType(DesktopTaskCard), findsNWidgets(2));
      expect(find.text('System Design Interview'), findsOneWidget);
      expect(find.text('Weekly Standup'), findsOneWidget);
      expect(find.text('Pay Cloud Invoice'), findsNothing); // Completed task is filtered out of active list
    });

    testWidgets('Desktop sidebar navigation switches between Dashboard, Active Reminders, History, and Profile',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestApp(const HomeScreen()));
      await tester.pumpAndSettle();

      // Switch to History
      await tester.tap(find.widgetWithText(InkWell, 'History'));
      await tester.pumpAndSettle();

      expect(find.text('Completed Reminders (1)'), findsOneWidget);
      expect(find.text('Pay Cloud Invoice'), findsOneWidget);
      expect(find.byKey(const Key('history_task_reopen_button_task-3')), findsOneWidget);

      // Switch to Profile
      await tester.tap(find.widgetWithText(InkWell, 'Profile'));
      await tester.pumpAndSettle();

      expect(find.text('Sarah Connor'), findsWidgets);
      expect(find.text('+15559876543'), findsWidgets);
      expect(find.text('Productivity Statistics'), findsOneWidget);

      // Switch back to Dashboard
      await tester.tap(find.widgetWithText(InkWell, 'Dashboard'));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopAiCenterpiece), findsOneWidget);
      expect(find.text('System Design Interview'), findsOneWidget);
    });

    testWidgets('Desktop AI Centerpiece generates structured proposal and requires human confirmation',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestApp(const HomeScreen()));
      await tester.pumpAndSettle();

      const initialCount = 2; // Active tasks
      expect(taskProvider.pendingCount, initialCount);

      // Enter a prompt in the desktop AI input
      final promptField = find.byKey(const Key('desktop_ai_prompt_field'));
      await tester.enterText(
          promptField, 'Doctor consultation tomorrow at 4 PM urgent');
      await tester.pumpAndSettle();

      // Tap Propose
      await tester.tap(find.byKey(const Key('desktop_ai_propose_button')));
      await tester.pumpAndSettle();

      // Proposal appears with explicit confirmation banner
      expect(find.text('AI PROPOSAL — AWAITING HUMAN CONFIRMATION'), findsOneWidget);
      expect(find.text('Doctor consultation urgent'), findsOneWidget);
      expect(find.text('Confirm & Save'), findsOneWidget);
      expect(find.text('Edit in Form'), findsOneWidget);

      // STRICT CHECK: Nothing added yet!
      expect(taskProvider.pendingCount, initialCount);

      // Tap Confirm & Save
      await tester.tap(find.text('Confirm & Save'));
      await tester.pumpAndSettle();

      // Task is now saved!
      expect(taskProvider.pendingCount, initialCount + 1);
      expect(find.text('Doctor consultation urgent'), findsOneWidget);
    });

    testWidgets('SignInScreen renders split hero layout at desktop resolution (1440x900)',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestApp(const SignInScreen()));
      await tester.pumpAndSettle();

      // Left pane brand hero
      expect(find.text("Think it. Confirm it. Don't Miss it."), findsOneWidget);
      expect(find.text('Turn natural-language intentions into actionable reminders with a strict human-in-the-loop workflow.'),
          findsOneWidget);
      expect(find.text('Core Workflow'), findsOneWidget);

      // Right pane compact auth card
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.byKey(const Key('sign_in_phone_field')), findsOneWidget);
      expect(find.byKey(const Key('sign_in_password_field')), findsOneWidget);
      expect(find.byKey(const Key('sign_in_submit_button')), findsOneWidget);
    });
  });
}
