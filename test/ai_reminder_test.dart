import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dont_miss/models/ai_reminder_draft.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/screens/home_screen.dart';
import 'package:dont_miss/services/ai_reminder_service.dart';
import 'package:dont_miss/services/notification_service.dart';

/// Fake repository for isolated tests.
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
  final fixedRefTime = DateTime(2026, 9, 20, 10, 0); // Sunday, Sep 20, 2026, 10:00 AM
  const service = LocalAiReminderService();

  group('LocalAiReminderService Unit Tests', () {
    test('Tomorrow date parsing', () async {
      const prompt = 'Remind me tomorrow at 9 PM about my Amazon interview';
      final draft = await service.parsePrompt(prompt, referenceTime: fixedRefTime);

      expect(draft.dueDate.year, 2026);
      expect(draft.dueDate.month, 9);
      expect(draft.dueDate.day, 21); // 20 + 1 = 21
    });

    test('Today date parsing', () async {
      const prompt = 'Remind me today at 10:30 AM about Doctor appointment';
      final draft = await service.parsePrompt(prompt, referenceTime: fixedRefTime);

      expect(draft.dueDate.year, 2026);
      expect(draft.dueDate.month, 9);
      expect(draft.dueDate.day, 20);
    });

    test('9 PM time parsing (12-hour format)', () async {
      const prompt = 'Remind me tomorrow at 9 PM about Amazon interview';
      final draft = await service.parsePrompt(prompt, referenceTime: fixedRefTime);

      expect(draft.dueHour, 21);
      expect(draft.dueMinute, 0);
    });

    test('10:30 AM time parsing (12-hour with minutes)', () async {
      const prompt = 'Remind me today at 10:30 AM about standup';
      final draft = await service.parsePrompt(prompt, referenceTime: fixedRefTime);

      expect(draft.dueHour, 10);
      expect(draft.dueMinute, 30);
    });

    test('24-hour time parsing (e.g. at 15:00)', () async {
      const prompt = 'Pay electric bill tomorrow at 15:00';
      final draft = await service.parsePrompt(prompt, referenceTime: fixedRefTime);

      expect(draft.dueHour, 15);
      expect(draft.dueMinute, 0);
    });

    test('Title extraction from "about ..."', () async {
      const prompt =
          'Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare questions';
      final draft = await service.parsePrompt(prompt, referenceTime: fixedRefTime);

      expect(draft.title, 'Amazon interview');
    });

    test('Description extraction from "because ..."', () async {
      const prompt =
          'Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare questions';
      final draft = await service.parsePrompt(prompt, referenceTime: fixedRefTime);

      expect(draft.description, 'I need to prepare questions');
    });

    test('Priority inference for high-stakes and low-stakes keywords', () async {
      final interviewDraft = await service.parsePrompt(
        'Remind me tomorrow at 9 PM about my Amazon interview',
        referenceTime: fixedRefTime,
      );
      expect(interviewDraft.priority, Priority.high);

      final urgentDraft = await service.parsePrompt(
        'Remind me today at 14:00 about urgent production bug fix',
        referenceTime: fixedRefTime,
      );
      expect(urgentDraft.priority, Priority.high);

      final casualDraft = await service.parsePrompt(
        'Remind me tomorrow at 16:00 about casual coffee chat',
        referenceTime: fixedRefTime,
      );
      expect(casualDraft.priority, Priority.low);

      final normalDraft = await service.parsePrompt(
        'Remind me tomorrow at 18:00 about grocery shopping',
        referenceTime: fixedRefTime,
      );
      expect(normalDraft.priority, Priority.medium);
    });

    test('Recurrence inference from prompt keywords', () async {
      final dailyDraft = await service.parsePrompt(
        'Remind me tomorrow at 9 AM about daily standup every day',
        referenceTime: fixedRefTime,
      );
      expect(dailyDraft.recurrence, Recurrence.daily);

      final weeklyDraft = await service.parsePrompt(
        'Remind me tomorrow at 10 AM about team retrospective every week',
        referenceTime: fixedRefTime,
      );
      expect(weeklyDraft.recurrence, Recurrence.weekly);

      final noneDraft = await service.parsePrompt(
        'Remind me tomorrow at 9 PM about Amazon interview',
        referenceTime: fixedRefTime,
      );
      expect(noneDraft.recurrence, Recurrence.none);
    });

    test('Invalid/missing required information throws AiParsingException', () async {
      // Empty prompt
      expect(
        () => service.parsePrompt('', referenceTime: fixedRefTime),
        throwsA(isA<AiParsingException>()),
      );

      // Missing date
      expect(
        () => service.parsePrompt('Remind me at 9 PM about interview', referenceTime: fixedRefTime),
        throwsA(isA<AiParsingException>()),
      );

      // Missing time
      expect(
        () => service.parsePrompt('Remind me tomorrow about interview', referenceTime: fixedRefTime),
        throwsA(isA<AiParsingException>()),
      );
    });

    test('Raw prompt preservation in draft', () async {
      const raw = 'Remind me tomorrow at 9 PM about Amazon interview';
      final draft = await service.parsePrompt(raw, referenceTime: fixedRefTime);
      expect(draft.rawPrompt, raw);
    });
  });

  group('AiReminderDraft Model Tests', () {
    test('toTask() creates a valid Task with correct fields and unique id', () {
      final draft = AiReminderDraft(
        title: 'Amazon Interview Prep',
        description: 'Review distributed architectures',
        dueDate: DateTime(2026, 9, 21),
        dueHour: 21,
        dueMinute: 0,
        priority: Priority.high,
        recurrence: Recurrence.none,
        rawPrompt: 'Remind me tomorrow at 9 PM about Amazon Interview Prep',
      );

      final task = draft.toTask();

      expect(task.id, isNotEmpty);
      expect(task.title, 'Amazon Interview Prep');
      expect(task.description, 'Review distributed architectures');
      expect(task.dueDate, DateTime(2026, 9, 21));
      expect(task.dueHour, 21);
      expect(task.dueMinute, 0);
      expect(task.priority, Priority.high);
      expect(task.recurrence, Recurrence.none);
      expect(task.isCompleted, isFalse);
      expect(task.isNotificationEnabled, isTrue);
    });

    test('Serialization and deserialization round-trip', () {
      final draft = AiReminderDraft(
        title: 'Pay Electric Bill',
        description: 'Utility payment',
        dueDate: DateTime(2026, 9, 21),
        dueHour: 15,
        dueMinute: 30,
        priority: Priority.medium,
        recurrence: Recurrence.monthly,
        reasoning: 'Monthly recurrence inferred',
        rawPrompt: 'Pay electric bill tomorrow at 15:30 monthly',
      );

      final json = draft.toJson();
      final fromJson = AiReminderDraft.fromJson(json);

      expect(fromJson.title, draft.title);
      expect(fromJson.description, draft.description);
      expect(fromJson.dueDate, draft.dueDate);
      expect(fromJson.dueHour, draft.dueHour);
      expect(fromJson.dueMinute, draft.dueMinute);
      expect(fromJson.priority, draft.priority);
      expect(fromJson.recurrence, draft.recurrence);
      expect(fromJson.reasoning, draft.reasoning);
      expect(fromJson.rawPrompt, draft.rawPrompt);
    });
  });

  group('AI Assistant Widget & Confirmation Tests', () {
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

    Widget createWidgetUnderTest() {
      return ChangeNotifierProvider<TaskProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: HomeScreen(),
        ),
      );
    }

    testWidgets('Opens AI Assistant sheet, enters prompt, previews and confirms reminder',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      // 1. Initial state: 0 tasks
      expect(provider.totalCount, 0);

      // 2. Tap AI Assistant icon in AppBar
      expect(find.byTooltip('AI Reminder Assistant'), findsOneWidget);
      await tester.tap(find.byTooltip('AI Reminder Assistant'));
      await tester.pumpAndSettle();

      // 3. Verify assistant sheet is shown
      expect(find.text('AI Reminder Assistant'), findsOneWidget);
      expect(find.text('Generate Reminder Draft'), findsOneWidget);

      // 4. Enter natural language prompt
      await tester.enterText(
        find.byKey(const Key('ai_prompt_input')),
        'Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare questions',
      );
      await tester.pumpAndSettle();

      // 5. Tap Generate
      await tester.tap(find.text('Generate Reminder Draft'));
      await tester.pumpAndSettle();

      // 6. Verify structured preview card appears
      expect(find.text('Amazon interview'), findsOneWidget);
      expect(find.text('I need to prepare questions'), findsOneWidget);
      expect(find.text('Tomorrow at 9:00 PM'), findsOneWidget);
      expect(find.text('Confirm & Add'), findsOneWidget);
      expect(find.text('Edit in Form'), findsOneWidget);

      // 7. CRITICAL VERIFICATION: No task is created before confirmation!
      expect(provider.totalCount, 0);

      // 8. Tap "Confirm & Add"
      await tester.tap(find.text('Confirm & Add'));
      await tester.pumpAndSettle();

      // 9. Verify task was created and saved to TaskProvider
      expect(provider.totalCount, 1);
      final createdTask = provider.allTasks.first;
      expect(createdTask.title, 'Amazon interview');
      expect(createdTask.description, 'I need to prepare questions');
      expect(createdTask.dueHour, 21);
      expect(createdTask.priority, Priority.high);
    });

    testWidgets('Edit in Form opens AddEditTaskScreen with prefilled draft', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      // Open AI Assistant
      await tester.tap(find.byTooltip('AI Reminder Assistant'));
      await tester.pumpAndSettle();

      // Enter prompt
      await tester.enterText(
        find.byKey(const Key('ai_prompt_input')),
        'Remind me tomorrow at 15:00 about Doctor appointment',
      );
      await tester.pumpAndSettle();

      // Generate draft
      await tester.tap(find.text('Generate Reminder Draft'));
      await tester.pumpAndSettle();

      // Tap "Edit in Form"
      expect(find.text('Edit in Form'), findsOneWidget);
      await tester.tap(find.text('Edit in Form'));
      await tester.pumpAndSettle();

      // Verify AddEditTaskScreen is opened with prefilled title
      expect(find.text('Doctor appointment'), findsOneWidget);
      expect(find.text('Create Reminder'), findsOneWidget);

      // Still no task created yet!
      expect(provider.totalCount, 0);
    });
  });
}
