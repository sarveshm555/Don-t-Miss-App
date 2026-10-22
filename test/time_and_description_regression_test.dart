import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dont_miss/models/ai_reminder_draft.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/screens/add_edit_task_screen.dart';
import 'package:dont_miss/services/ai_reminder_service.dart';
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
  Future<void> cancelTaskNotification(int notificationId) async {}

  @override
  Future<void> cancelAllNotifications() async {}
}

void main() {
  final fixedRef = DateTime(2026, 10, 20, 10, 0); // Tuesday, Oct 20, 2026, 10:00 AM
  const localService = LocalAiReminderService();

  group('Bug 1 Regression Tests: Explicit Time Preservation and Defaults', () {
    test('Explicit 9 AM is preserved as 09:00 (never changed to 10:00 default)', () async {
      final draft = await localService.parsePrompt(
        "Remind me tomorrow at 9 AM to send my resume to my ma'am.",
        referenceTime: fixedRef,
      );
      expect(draft.dueHour, 9);
      expect(draft.dueMinute, 0);
      expect(draft.dueDate.day, 21);
      expect(draft.title, "Send my resume to my ma'am");
    });

    test('Explicit 7:30 AM is preserved as 07:30', () async {
      final draft = await localService.parsePrompt(
        "Remind me tomorrow at 7:30 AM to call the client",
        referenceTime: fixedRef,
      );
      expect(draft.dueHour, 7);
      expect(draft.dueMinute, 30);
    });

    test('Explicit 12 PM is preserved as 12:00', () async {
      final draft = await localService.parsePrompt(
        "Remind me tomorrow at 12 PM to attend the product sync",
        referenceTime: fixedRef,
      );
      expect(draft.dueHour, 12);
      expect(draft.dueMinute, 0);
    });

    test('Explicit 6:45 PM is preserved as 18:45', () async {
      final draft = await localService.parsePrompt(
        "Remind me tomorrow at 6:45 PM to send daily report",
        referenceTime: fixedRef,
      );
      expect(draft.dueHour, 18);
      expect(draft.dueMinute, 45);
    });

    test('Default time (09:00 AM) applied ONLY when no time is given', () async {
      final draft = await localService.parsePrompt(
        "Remind me tomorrow to send my resume to my ma'am.",
        referenceTime: fixedRef,
      );
      expect(draft.dueHour, 9);
      expect(draft.dueMinute, 0);
      expect(draft.title, "Send my resume to my ma'am");
    });
  });

  group('Bug 2 Regression Tests: Title and Description Separation', () {
    test('Separates title and description for "Tomorrow at 9 AM, send my resume... and mention..."', () async {
      final draft = await localService.parsePrompt(
        "Tomorrow at 9 AM, send my resume to my ma'am and mention my project experience",
        referenceTime: fixedRef,
      );
      expect(draft.title, "Send my resume to my ma'am");
      expect(draft.description, "Mention my project experience");
      expect(draft.dueHour, 9);
      expect(draft.dueMinute, 0);
    });

    test('Separates title and description for "Remind me tomorrow at 9 AM to send my resume... and mention..."', () async {
      final draft = await localService.parsePrompt(
        "Remind me tomorrow at 9 AM to send my resume to my ma'am and mention my project experience",
        referenceTime: fixedRef,
      );
      expect(draft.title, "Send my resume to my ma'am");
      expect(draft.description, "Mention my project experience");
      expect(draft.dueHour, 9);
      expect(draft.dueMinute, 0);
    });

    test('Separates secondary clauses with "and attach ..."', () async {
      final draft = await localService.parsePrompt(
        "Remind me tomorrow at 6:45 PM to submit assignment and attach the PDF report",
        referenceTime: fixedRef,
      );
      expect(draft.title, "Submit assignment");
      expect(draft.description, "Attach the PDF report");
      expect(draft.dueHour, 18);
      expect(draft.dueMinute, 45);
    });

    test('Separates context with "because ..."', () async {
      final draft = await localService.parsePrompt(
        "Remind me tomorrow at 9 AM to call Arun because he asked for an update",
        referenceTime: fixedRef,
      );
      expect(draft.title, "Call Arun");
      expect(draft.description, "He asked for an update");
      expect(draft.dueHour, 9);
      expect(draft.dueMinute, 0);
    });
  });

  group('Complete Data Flow: Draft -> Task -> Notifications & Editing', () {
    test('draft.toTask() preserves title, description, dueHour, and dueMinute exactly', () {
      final draft = AiReminderDraft(
        id: 'draft-abc',
        title: "Send my resume to my ma'am",
        description: "Mention my project experience",
        dueDate: DateTime(2026, 10, 21),
        dueHour: 9,
        dueMinute: 0,
        rawPrompt: "Tomorrow at 9 AM, send my resume to my ma'am and mention my project experience",
      );

      final task = draft.toTask();
      expect(task.id, 'draft-abc');
      expect(task.title, "Send my resume to my ma'am");
      expect(task.description, "Mention my project experience");
      expect(task.dueHour, 9);
      expect(task.dueMinute, 0);
      expect(task.fullDueDateTime, DateTime(2026, 10, 21, 9, 0));
    });

    test('AiReminderDraft.fromJson and Task.fromJson handle snake_case and camelCase accurately', () {
      final cloudJson = {
        'id': 'cloud-123',
        'title': 'Send resume',
        'description': 'Include references',
        'due_date': '2026-10-21',
        'due_hour': 9,
        'due_minute': 0,
        'priority': 'high',
        'recurrence': 'none',
      };

      final draft = AiReminderDraft.fromJson(cloudJson);
      expect(draft.dueHour, 9);
      expect(draft.dueMinute, 0);
      expect(draft.description, 'Include references');

      final task = Task.fromJson(cloudJson);
      expect(task.dueHour, 9);
      expect(task.dueMinute, 0);
      expect(task.description, 'Include references');
    });

    testWidgets('AddEditTaskScreen initialized with initialAiDraft retains explicit 9 AM and description', (tester) async {
      final draft = AiReminderDraft(
        id: 'draft-xyz',
        title: "Send my resume to my ma'am",
        description: "Mention my project experience",
        dueDate: DateTime(2026, 10, 21),
        dueHour: 9,
        dueMinute: 0,
        priority: Priority.high,
        rawPrompt: "Tomorrow at 9 AM, send my resume to my ma'am and mention my project experience",
      );

      final repo = FakeTaskRepository();
      final notify = FakeNotificationService();
      final provider = TaskProvider(repository: repo, notificationService: notify);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TaskProvider>.value(
            value: provider,
            child: AddEditTaskScreen(
              initialAiDraft: draft,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify title controller is prefilled
      expect(find.text("Send my resume to my ma'am"), findsOneWidget);
      // Verify description controller is prefilled
      expect(find.text("Mention my project experience"), findsOneWidget);
      // Verify time is 9:00 AM (NOT 10:00 AM default!)
      expect(find.textContaining('9:00'), findsOneWidget);
      expect(find.textContaining('10:00'), findsNothing);
    });
  });
}
