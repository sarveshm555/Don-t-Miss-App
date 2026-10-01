import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dont_miss/models/ai_reminder_draft.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/screens/add_edit_task_screen.dart';
import 'package:dont_miss/services/action_dispatch_service.dart';
import 'package:dont_miss/services/notification_service.dart';

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

class FakeActionDispatchService implements ActionDispatchService {
  bool returnValue;
  int dispatchCount = 0;
  AiReminderDraft? lastDispatchedDraft;
  String? lastPhoneNumber;
  Duration delay;

  FakeActionDispatchService({
    this.returnValue = true,
    this.delay = Duration.zero,
  });

  @override
  Future<bool> dispatchConfirmedAction({
    required AiReminderDraft draft,
    String? userPhoneNumber,
    String? userId,
    String? authToken,
    String? reminderId,
  }) async {
    dispatchCount++;
    lastDispatchedDraft = draft;
    lastPhoneNumber = userPhoneNumber;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    return returnValue;
  }
}

void main() {
  final fixedRefTime = DateTime(2026, 10, 1, 10, 0);

  group('Edit-in-Form Persistence Flow Tests', () {
    late FakeTaskRepository repository;
    late FakeNotificationService notificationService;
    late TaskProvider provider;

    setUp(() async {
      repository = FakeTaskRepository();
      notificationService = FakeNotificationService();
      provider = TaskProvider(
        repository: repository,
        notificationService: notificationService,
        clock: () => fixedRefTime,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    Widget createScreenUnderTest({
      required AiReminderDraft aiDraft,
      required ActionDispatchService dispatchService,
    }) {
      return ChangeNotifierProvider<TaskProvider>.value(
        value: provider,
        child: MaterialApp(
          home: AddEditTaskScreen(
            initialDraft: aiDraft.toTask(),
            initialAiDraft: aiDraft,
            actionDispatchService: dispatchService,
            notificationService: notificationService,
          ),
        ),
      );
    }

    testWidgets('1 & 2 & 3 & 4 & 5: AI proposal -> Edit in Form -> User edits fields -> Save reflects in local and backend payload',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final initialDraft = AiReminderDraft(
        rawPrompt: 'Remind me tomorrow at 9 PM about Amazon interview',
        title: 'Amazon interview',
        description: 'Prepare questions',
        dueDate: DateTime(2026, 10, 2),
        dueHour: 21,
        dueMinute: 0,
        priority: Priority.high,
        recurrence: Recurrence.none,
        channels: const ['local', 'whatsapp'],
      );

      final fakeDispatch = FakeActionDispatchService(returnValue: true);

      await tester.pumpWidget(createScreenUnderTest(
        aiDraft: initialDraft,
        dispatchService: fakeDispatch,
      ));
      await tester.pumpAndSettle();

      // Verify fields prefilled
      expect(find.text('Amazon interview'), findsOneWidget);
      expect(find.text('Prepare questions'), findsOneWidget);

      // User edits the title and description
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amazon interview'),
        'Amazon Senior Bar Raiser Interview',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Prepare questions'),
        'Prepare LP stories & system design questions',
      );
      await tester.pumpAndSettle();

      // Tap Save button
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // 3. Local save occurs
      expect(provider.totalCount, 1);
      final savedTask = provider.allTasks.first;
      expect(savedTask.title, 'Amazon Senior Bar Raiser Interview');
      expect(savedTask.description, 'Prepare LP stories & system design questions');

      // 4. POST /action/confirm dispatch occurs
      expect(fakeDispatch.dispatchCount, 1);

      // 2. Edited fields are reflected in backend payload
      final dispatched = fakeDispatch.lastDispatchedDraft;
      expect(dispatched, isNotNull);
      expect(dispatched!.title, 'Amazon Senior Bar Raiser Interview');
      expect(dispatched.description, 'Prepare LP stories & system design questions');
      expect(dispatched.rawPrompt, 'Remind me tomorrow at 9 PM about Amazon interview');
      expect(dispatched.channels, contains('whatsapp'));

      // 5. Backend success handled: shows success snackbar
      expect(find.text('Scheduled reminder: "Amazon Senior Bar Raiser Interview"'), findsOneWidget);
    });

    testWidgets('6: Backend failure keeps local reminder and shows cloud sync offline warning',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final initialDraft = AiReminderDraft(
        rawPrompt: 'Remind me tomorrow at 10 AM to pay electricity bill',
        title: 'Pay electricity bill',
        description: 'Account #12345',
        dueDate: DateTime(2026, 10, 2),
        dueHour: 10,
        dueMinute: 0,
        priority: Priority.medium,
        channels: const ['local'],
      );

      final failingDispatch = FakeActionDispatchService(returnValue: false);

      await tester.pumpWidget(createScreenUnderTest(
        aiDraft: initialDraft,
        dispatchService: failingDispatch,
      ));
      await tester.pumpAndSettle();

      // Save without editing
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Local reminder is preserved!
      expect(provider.totalCount, 1);
      expect(provider.allTasks.first.title, 'Pay electricity bill');

      // Dispatch was attempted
      expect(failingDispatch.dispatchCount, 1);

      // Shows warning SnackBar
      expect(
        find.text('Scheduled locally: "Pay electricity bill" (cloud sync offline)'),
        findsOneWidget,
      );
    });

    testWidgets('7: Rapid taps on Save do not trigger duplicate local saves or backend dispatches',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final initialDraft = AiReminderDraft(
        rawPrompt: 'Team standup tomorrow at 9:30 AM',
        title: 'Team standup',
        dueDate: DateTime(2026, 10, 2),
        dueHour: 9,
        dueMinute: 30,
        priority: Priority.medium,
      );

      // Add a slight delay to simulate network latency
      final delayedDispatch = FakeActionDispatchService(
        returnValue: true,
        delay: const Duration(milliseconds: 50),
      );

      await tester.pumpWidget(createScreenUnderTest(
        aiDraft: initialDraft,
        dispatchService: delayedDispatch,
      ));
      await tester.pumpAndSettle();

      // Rapidly tap Save multiple times
      await tester.tap(find.text('Save'));
      await tester.tap(find.text('Save'), warnIfMissed: false);
      await tester.tap(find.text('Save'), warnIfMissed: false);

      // Advance through asynchronous operations
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();

      // Exactly 1 local task added
      expect(provider.totalCount, 1);

      // Exactly 1 backend dispatch
      expect(delayedDispatch.dispatchCount, 1);
    });
  });
}
