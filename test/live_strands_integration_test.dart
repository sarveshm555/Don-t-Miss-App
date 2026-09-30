// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/services/ai_agent_api_service.dart';
import 'package:dont_miss/services/notification_service.dart';

class InMemoryTaskRepository implements TaskRepository {
  final List<Task> _tasks = [];

  @override
  Future<List<Task>> getAllTasks() async => List.from(_tasks);

  @override
  Future<void> saveAllTasks(List<Task> tasks) async {
    _tasks.clear();
    _tasks.addAll(tasks);
  }
}

class RecordingNotificationService implements NotificationService {
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
  setUpAll(() {
    HttpOverrides.global = null;
  });

  test('Live integration: Flutter calls FastAPI -> Strands Agent -> proposal -> confirm -> TaskProvider -> NotificationService',
      () async {
    // Verify live backend availability
    try {
      final probe = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await probe.getUrl(Uri.parse('http://127.0.0.1:8000/health'));
      final res = await req.close();
      probe.close();
      if (res.statusCode != 200) {
        print('FastAPI server returned ${res.statusCode}, skipping live test.');
        return;
      }
    } catch (_) {
      print('FastAPI backend not running at 127.0.0.1:8000, skipping live integration test.');
      return;
    }

    print('Starting live integration test...');
    const service = StrandsAgentApiService(
      baseUrl: 'http://127.0.0.1:8000',
      timeout: Duration(seconds: 180),
    );

    const prompt =
        'Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare interview questions.';
    final referenceTime = DateTime(2026, 9, 20, 10, 0);

    print('Calling StrandsAgentApiService.parsePrompt with prompt: "$prompt"');
    final stopwatch = Stopwatch()..start();
    final draft = await service.parsePrompt(prompt, referenceTime: referenceTime);
    stopwatch.stop();
    print('Received draft in ${stopwatch.elapsed.inSeconds}s:');
    print('  Title: "${draft.title}"');
    print('  Description: "${draft.description}"');
    print('  DueDate: ${draft.dueDate.toIso8601String()}');
    print('  Time: ${draft.dueHour}:${draft.dueMinute.toString().padLeft(2, '0')}');
    print('  Priority: ${draft.priority.name}');
    print('  Recurrence: ${draft.recurrence.name}');
    print('  Reasoning: "${draft.reasoning}"');

    // Verify structured proposal fields extracted by Strands
    expect(draft.title.toLowerCase(), contains('amazon interview'));
    expect(draft.dueHour, 21);
    expect(draft.dueMinute, 0);
    expect(draft.priority, Priority.high);
    expect(draft.recurrence, Recurrence.none);
    expect(draft.dueDate.year, 2026);
    expect(draft.dueDate.month, 9);
    expect(draft.dueDate.day, 21);

    // Verify Human-in-the-Loop confirmation simulation:
    // 1. Prior to confirmation, no task exists
    final repository = InMemoryTaskRepository();
    final notificationService = RecordingNotificationService();
    final provider = TaskProvider(
      repository: repository,
      notificationService: notificationService,
      clock: () => referenceTime,
    );

    // Wait for initial load
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.totalCount, 0);
    expect(notificationService.scheduledTasks, isEmpty);

    // 2. User confirms & adds from draft
    final task = draft.toTask();
    expect(task.title, draft.title);
    expect(task.dueDate, draft.dueDate);
    expect(task.dueHour, 21);
    expect(task.priority, Priority.high);

    await provider.addTask(task);

    // 3. Verify task is added to TaskProvider
    expect(provider.totalCount, 1);
    final savedTask = provider.allTasks.first;
    expect(savedTask.id, task.id);
    expect(savedTask.title, draft.title);

    // 4. Verify task is persisted in TaskRepository
    final repoTasks = await repository.getAllTasks();
    expect(repoTasks.length, 1);
    expect(repoTasks.first.title, draft.title);

    // 5. Verify notification scheduled via NotificationService
    expect(notificationService.scheduledTasks.length, 1);
    expect(notificationService.scheduledTasks.first.id, task.id);

    print('LIVE INTEGRATION TEST PASSED SUCCESSFULLY!');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
