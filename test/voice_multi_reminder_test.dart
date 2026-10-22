import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dont_miss/models/ai_reminder_draft.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/services/ai_reminder_service.dart';
import 'package:dont_miss/services/notification_service.dart';
import 'package:dont_miss/services/voice_recording_service.dart';
import 'package:dont_miss/services/voice_recording_platform.dart';
import 'package:dont_miss/services/ai_agent_api_service.dart';
import 'package:dont_miss/services/agent_http_transport.dart';
import 'package:record/record.dart';
import 'package:dont_miss/widgets/ai_confirmation_sheet.dart';

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

class FakeVoiceRecordingService implements VoiceRecordingService {
  bool permitted = true;
  bool _isRecording = false;
  final StreamController<Duration> _controller =
      StreamController<Duration>.broadcast();
  List<int> returnedAudio = [0x52, 0x49, 0x46, 0x46]; // RIFF header mockup

  @override
  bool get isRecording => _isRecording;

  @override
  String get recordedFilename => 'test_recording.m4a';

  @override
  Stream<Duration> get durationStream => _controller.stream;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<void> startRecording() async {
    if (!permitted) throw Exception('Permission denied');
    _isRecording = true;
    _controller.add(const Duration(seconds: 1));
  }

  @override
  Future<List<int>?> stopRecording() async {
    _isRecording = false;
    return returnedAudio;
  }

  @override
  Future<void> cancelRecording() async {
    _isRecording = false;
  }

  @override
  void dispose() {
    _controller.close();
  }
}

class MockPlatformHelper implements VoiceRecordingPlatformHelper {
  String preparedPath = '/fake/dir/recording.m4a';
  List<int> bytesToReturn = [0x00, 0x01, 0x02];
  bool cleanedUp = false;

  @override
  String getFilename() => 'recording.m4a';

  @override
  RecordConfig getRecordConfig() =>
      const RecordConfig(encoder: AudioEncoder.aacLc);

  @override
  Future<String> prepareRecordingPath(String extension) async => preparedPath;

  @override
  Future<List<int>?> readAndCleanupBytes(String path) async {
    cleanedUp = true;
    return bytesToReturn;
  }

  @override
  Future<void> cleanupPath(String path) async {
    cleanedUp = true;
  }
}

class MockAudioRecorder extends Fake implements AudioRecorder {
  bool permitted = true;
  bool startCalled = false;
  String? startPath;
  RecordConfig? startConfig;
  bool stopCalled = false;
  bool cancelCalled = false;

  @override
  Future<bool> hasPermission({bool request = true}) async => permitted;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startCalled = true;
    startConfig = config;
    startPath = path;
  }

  @override
  Future<String?> stop() async {
    stopCalled = true;
    return startPath;
  }

  @override
  Future<void> cancel() async {
    cancelCalled = true;
  }

  @override
  Future<void> dispose() async {}
}

class FakeMultiAiService implements AiReminderService {
  final List<AiReminderDraft> draftsToReturn;
  String transcribedTextToReturn;

  FakeMultiAiService({
    required this.draftsToReturn,
    this.transcribedTextToReturn = 'Test speech to text input',
  });

  @override
  Future<AiReminderDraft> parsePrompt(String prompt, {DateTime? referenceTime}) async {
    if (draftsToReturn.isNotEmpty) return draftsToReturn.first;
    return AiReminderDraft(
      title: prompt,
      dueDate: DateTime.now().add(const Duration(days: 1)),
      dueHour: 9,
      dueMinute: 0,
      priority: Priority.medium,
      recurrence: Recurrence.none,
      rawPrompt: prompt,
    );
  }

  @override
  Future<List<AiReminderDraft>> parseMultiPrompt(
    String prompt, {
    DateTime? referenceTime,
    String? timezone,
    String? authToken,
  }) async {
    return draftsToReturn;
  }

  @override
  Future<String> transcribeAudio(
    List<int> audioBytes, {
    String filename = 'audio.wav',
    String? language,
    String? authToken,
  }) async {
    return transcribedTextToReturn;
  }
}

class MockFailingTransport extends Fake implements AgentHttpTransport {
  final Object errorToThrow;
  MockFailingTransport({required this.errorToThrow});

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    throw errorToThrow;
  }
}

class MockRouteTransport extends Fake implements AgentHttpTransport {
  final Future<AgentHttpResponse> Function(Uri uri, Map<String, dynamic> payload) handler;
  MockRouteTransport(this.handler);

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return handler(uri, payload);
  }
}

class FakeAsyncAiService extends FakeMultiAiService {
  final Completer<String> transcribeCompleter;

  FakeAsyncAiService({
    required this.transcribeCompleter,
  }) : super(draftsToReturn: []);

  @override
  Future<String> transcribeAudio(
    List<int> audioBytes, {
    String filename = 'audio.wav',
    String? language,
    String? authToken,
  }) async {
    return transcribeCompleter.future;
  }
}

void main() {
  group('Voice and Multi-Task Reminder Tests', () {
    late FakeTaskRepository repository;
    late FakeNotificationService notificationService;
    late TaskProvider provider;

    setUp(() {
      repository = FakeTaskRepository();
      notificationService = FakeNotificationService();
      provider = TaskProvider(
        repository: repository,
        notificationService: notificationService,
      );
    });

    test('AppVoiceRecordingService records to file path and reads bytes on stop', () async {
      final mockRecorder = MockAudioRecorder();
      final mockHelper = MockPlatformHelper();
      final service = AppVoiceRecordingService(
        recorder: mockRecorder,
        platformHelper: mockHelper,
      );

      expect(await service.hasPermission(), isTrue);
      expect(service.isRecording, isFalse);

      await service.startRecording();
      expect(service.isRecording, isTrue);
      expect(mockRecorder.startCalled, isTrue);
      expect(mockRecorder.startPath, '/fake/dir/recording.m4a');
      expect(mockRecorder.startConfig?.encoder, AudioEncoder.aacLc);

      final bytes = await service.stopRecording();
      expect(service.isRecording, isFalse);
      expect(mockRecorder.stopCalled, isTrue);
      expect(mockHelper.cleanedUp, isTrue);
      expect(bytes, [0x00, 0x01, 0x02]);

      service.dispose();
    });

    test('AppVoiceRecordingService cancel cleans up without returning bytes', () async {
      final mockRecorder = MockAudioRecorder();
      final mockHelper = MockPlatformHelper();
      final service = AppVoiceRecordingService(
        recorder: mockRecorder,
        platformHelper: mockHelper,
      );

      await service.startRecording();
      expect(service.isRecording, isTrue);

      await service.cancelRecording();
      expect(service.isRecording, isFalse);
      expect(mockRecorder.cancelCalled, isTrue);
      expect(mockHelper.cleanedUp, isTrue);

      service.dispose();
    });

    test('AppVoiceRecordingService throws when permission denied', () async {
      final mockRecorder = MockAudioRecorder()..permitted = false;
      final mockHelper = MockPlatformHelper();
      final service = AppVoiceRecordingService(
        recorder: mockRecorder,
        platformHelper: mockHelper,
      );

      expect(await service.hasPermission(), isFalse);
      expect(() => service.startRecording(), throwsException);
      expect(service.isRecording, isFalse);

      service.dispose();
    });

    test('TaskProvider.addTasksBatch saves all tasks and schedules notifications', () async {
      final now = DateTime(2026, 10, 20, 10, 0);
      final task1 = Task(
        id: 'task-1',
        title: 'Gemini Hackathon',
        dueDate: DateTime(2026, 10, 21),
        dueHour: 10,
        dueMinute: 0,
        priority: Priority.high,
        createdAt: now,
      );
      final task2 = Task(
        id: 'task-2',
        title: "Friend's Birthday",
        dueDate: DateTime(2026, 10, 22),
        dueHour: 9,
        dueMinute: 0,
        priority: Priority.medium,
        createdAt: now,
      );

      await provider.addTasksBatch([task1, task2]);

      expect(provider.totalCount, 2);
      expect(provider.allTasks.map((t) => t.title), containsAll(['Gemini Hackathon', "Friend's Birthday"]));
      expect(notificationService.scheduledTasks.length, 2);
    });

    testWidgets('Voice input flow: record, stop, transcribe, preview and edit text', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeVoice = FakeVoiceRecordingService();
      final fakeAi = FakeMultiAiService(
        draftsToReturn: [],
        transcribedTextToReturn: 'Doctor appointment tomorrow at 10 AM',
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<TaskProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: AiConfirmationSheet(
                aiService: fakeAi,
                voiceRecordingService: fakeVoice,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Verify mic button is present
      expect(find.byKey(const Key('voice_record_button')), findsOneWidget);

      // 2. Tap mic button to start recording
      await tester.tap(find.byKey(const Key('voice_record_button')));
      await tester.pumpAndSettle();

      // 3. Verify active recording UI
      expect(find.textContaining('Recording...'), findsOneWidget);
      expect(find.byKey(const Key('cancel_recording_button')), findsOneWidget);
      expect(find.byKey(const Key('stop_recording_button')), findsOneWidget);

      // 4. Tap stop recording to transcribe
      await tester.tap(find.byKey(const Key('stop_recording_button')));
      await tester.pumpAndSettle();

      // 5. Verify transcribed text appears in text field
      final textField = tester.widget<TextField>(find.byKey(const Key('ai_prompt_input')));
      expect(textField.controller?.text, 'Doctor appointment tomorrow at 10 AM');

      // 6. User can edit transcribed text
      await tester.enterText(
        find.byKey(const Key('ai_prompt_input')),
        'Doctor appointment tomorrow at 11 AM',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byKey(const Key('ai_prompt_input'))).controller?.text,
        'Doctor appointment tomorrow at 11 AM',
      );
    });

    testWidgets('Multi-draft parsing, checklist selection, individual removal, and batch confirmation', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final draft1 = AiReminderDraft(
        id: 'draft-1',
        title: 'Gemini Hackathon Demo',
        dueDate: DateTime(2026, 10, 21),
        dueHour: 10,
        dueMinute: 0,
        priority: Priority.high,
        recurrence: Recurrence.none,
        rawPrompt: 'Gemini hackathon demo today at 10 AM',
      );
      final draft2 = AiReminderDraft(
        id: 'draft-2',
        title: "Buy Birthday Cake",
        dueDate: DateTime(2026, 10, 22),
        dueHour: 15,
        dueMinute: 30,
        priority: Priority.medium,
        recurrence: Recurrence.none,
        rawPrompt: 'Buy birthday cake tomorrow at 3:30 PM',
      );

      final fakeAi = FakeMultiAiService(
        draftsToReturn: [draft1, draft2],
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<TaskProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: AiConfirmationSheet(
                aiService: fakeAi,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Enter multi-task prompt and tap Generate
      await tester.enterText(
        find.byKey(const Key('ai_prompt_input')),
        'Gemini hackathon demo today at 10 AM and buy birthday cake tomorrow at 3:30 PM',
      );
      await tester.tap(find.text('Generate Reminder Draft'));
      await tester.pumpAndSettle();

      // Verify checklist view appears with both cards
      expect(find.text('Extracted Reminders (2/2 selected)'), findsOneWidget);
      expect(find.text('Gemini Hackathon Demo'), findsOneWidget);
      expect(find.text('Buy Birthday Cake'), findsOneWidget);

      // Verify no tasks created before confirmation
      expect(provider.totalCount, 0);

      // Deselect draft 2
      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsNWidgets(2));
      await tester.tap(checkboxes.at(1));
      await tester.pumpAndSettle();

      expect(find.text('Extracted Reminders (1/2 selected)'), findsOneWidget);
      expect(find.text('Confirm Selected (1)'), findsOneWidget);

      // Confirm only selected draft 1
      await tester.tap(find.byKey(const Key('confirm_batch_button')));
      await tester.pumpAndSettle();

      // Verify only draft 1 was created
      expect(provider.totalCount, 1);
      expect(provider.allTasks.first.title, 'Gemini Hackathon Demo');
    });

    testWidgets('Select All toggles all drafts on and off', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final draft1 = AiReminderDraft(
        id: 'draft-1',
        title: 'Task A',
        dueDate: DateTime(2026, 10, 21),
        dueHour: 10,
        dueMinute: 0,
        priority: Priority.low,
        recurrence: Recurrence.none,
        rawPrompt: 'Task A',
      );
      final draft2 = AiReminderDraft(
        id: 'draft-2',
        title: 'Task B',
        dueDate: DateTime(2026, 10, 22),
        dueHour: 11,
        dueMinute: 0,
        priority: Priority.medium,
        recurrence: Recurrence.none,
        rawPrompt: 'Task B',
      );

      final fakeAi = FakeMultiAiService(draftsToReturn: [draft1, draft2]);

      await tester.pumpWidget(
        ChangeNotifierProvider<TaskProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: AiConfirmationSheet(
                aiService: fakeAi,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('ai_prompt_input')), 'Task A and Task B');
      await tester.tap(find.text('Generate Reminder Draft'));
      await tester.pumpAndSettle();

      // Initially 2/2 selected, button says 'Deselect All'
      expect(find.text('Deselect All'), findsOneWidget);
      await tester.tap(find.text('Deselect All'));
      await tester.pumpAndSettle();

      // Now 0/2 selected, button says 'Select All'
      expect(find.text('Select All'), findsOneWidget);
      expect(find.text('Extracted Reminders (0/2 selected)'), findsOneWidget);

      // Confirm button disabled when none selected
      final confirmBtn = tester.widget<ElevatedButton>(find.byKey(const Key('confirm_batch_button')));
      expect(confirmBtn.onPressed, isNull);

      // Tap 'Select All'
      await tester.tap(find.text('Select All'));
      await tester.pumpAndSettle();
      expect(find.text('Extracted Reminders (2/2 selected)'), findsOneWidget);
      expect(find.text('Confirm Selected (2)'), findsOneWidget);
    });

    testWidgets('Individual reminder can be removed with delete button', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final draft1 = AiReminderDraft(
        id: 'draft-1',
        title: 'Task Keep',
        dueDate: DateTime(2026, 10, 21),
        dueHour: 10,
        dueMinute: 0,
        priority: Priority.low,
        recurrence: Recurrence.none,
        rawPrompt: 'Task Keep',
      );
      final draft2 = AiReminderDraft(
        id: 'draft-2',
        title: 'Task Delete',
        dueDate: DateTime(2026, 10, 22),
        dueHour: 11,
        dueMinute: 0,
        priority: Priority.medium,
        recurrence: Recurrence.none,
        rawPrompt: 'Task Delete',
      );

      final fakeAi = FakeMultiAiService(draftsToReturn: [draft1, draft2]);

      await tester.pumpWidget(
        ChangeNotifierProvider<TaskProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: AiConfirmationSheet(
                aiService: fakeAi,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('ai_prompt_input')), 'Keep and delete');
      await tester.tap(find.text('Generate Reminder Draft'));
      await tester.pumpAndSettle();

      expect(find.text('Task Keep'), findsOneWidget);
      expect(find.text('Task Delete'), findsOneWidget);

      // Tap delete icon on Task Delete
      final deleteButtons = find.byTooltip('Remove reminder');
      expect(deleteButtons, findsNWidgets(2));
      await tester.tap(deleteButtons.at(1));
      await tester.pumpAndSettle();

      // Now only 1 draft remains (Task Keep), which triggers single draft preview!
      expect(find.text('Task Delete'), findsNothing);
      expect(find.text('Task Keep'), findsOneWidget);
      expect(find.text('Confirm & Add'), findsOneWidget);
    });

    test('StrandsAgentApiService productionBaseUrl is configured correctly', () {
      expect(
        StrandsAgentApiService.productionBaseUrl,
        'https://dont-miss-backend.onrender.com',
      );
      const service = StrandsAgentApiService(
        baseUrl: StrandsAgentApiService.productionBaseUrl,
      );
      expect(service.effectiveBaseUrl, 'https://dont-miss-backend.onrender.com');
    });

    test('StrandsAgentApiService sanitize network errors and hides internal host', () async {
      final fakeTransport = MockFailingTransport(
        errorToThrow: const AgentNetworkException(
          'Connection failed: SocketException: HTTP connection timed out after 0:00:15',
        ),
      );
      final service = StrandsAgentApiService(
        baseUrl: 'http://10.0.2.2:8000',
        transport: fakeTransport,
      );

      expect(
        () => service.transcribeAudio([1, 2, 3]),
        throwsA(predicate<AiParsingException>((e) {
          final msg = e.message;
          return !msg.contains('10.0.2.2') && msg.contains('timed out');
        })),
      );
    });

    testWidgets('Voice UI transitions through transcribing state', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeVoice = FakeVoiceRecordingService();
      final completer = Completer<String>();
      final slowAi = FakeAsyncAiService(transcribeCompleter: completer);

      await tester.pumpWidget(
        ChangeNotifierProvider<TaskProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: AiConfirmationSheet(
                aiService: slowAi,
                voiceRecordingService: fakeVoice,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Start recording
      await tester.tap(find.byKey(const Key('voice_record_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Recording...'), findsOneWidget);

      // Stop recording -> transitions to transcribing state
      await tester.tap(find.byKey(const Key('stop_recording_button')));
      await tester.pump(); // single pump so async remains pending

      // Verify transcribing UI is visible
      expect(find.text('Transcribing your audio with AI...'), findsOneWidget);

      // Complete transcription
      completer.complete('Doctor appointment tomorrow at 10 AM');
      await tester.pumpAndSettle();

      // Verify transcribed state
      expect(
        find.text('Voice transcribed! You can edit or generate drafts.'),
        findsOneWidget,
      );
      expect(find.text('Doctor appointment tomorrow at 10 AM'), findsOneWidget);
    });

    test('parseMultiPrompt falls back to parsePrompt when /agent/reminders/plan returns 404', () async {
      final transport = MockRouteTransport((uri, payload) async {
        if (uri.path.endsWith('/agent/reminders/plan')) {
          return const AgentHttpResponse(
            statusCode: 404,
            body: '{"detail":"Not Found"}',
          );
        }
        if (uri.path.endsWith('/agent/reminder')) {
          return const AgentHttpResponse(
            statusCode: 200,
            body: '''{
              "success": true,
              "proposal": {
                "status": "PROPOSED",
                "action": "create_reminder",
                "draft": {
                  "title": "Interview tomorrow",
                  "dueDate": "2026-10-22",
                  "dueHour": 9,
                  "dueMinute": 0,
                  "priority": "high",
                  "recurrence": "none"
                }
              }
            }''',
          );
        }
        return const AgentHttpResponse(statusCode: 500, body: 'Unexpected route');
      });

      final service = StrandsAgentApiService(
        baseUrl: 'https://dont-miss-backend.onrender.com',
        transport: transport,
      );

      final drafts = await service.parseMultiPrompt('Interview tomorrow at 9 AM');
      expect(drafts.length, 1);
      expect(drafts.first.title, 'Interview tomorrow');
      expect(drafts.first.dueHour, 9);
    });

    test('parseMultiPrompt delegates to fallbackService when both endpoints fail', () async {
      final transport = MockRouteTransport((uri, payload) async {
        return const AgentHttpResponse(
          statusCode: 404,
          body: '{"detail":"Not Found"}',
        );
      });

      final service = StrandsAgentApiService(
        baseUrl: 'https://dont-miss-backend.onrender.com',
        transport: transport,
        fallbackService: const LocalAiReminderService(),
      );

      final drafts = await service.parseMultiPrompt('Interview tomorrow at 9 AM');
      expect(drafts.length, 1);
      expect(drafts.first.title, contains('Interview'));
    });

    test('transcribeAudio returns informative message when backend returns 404', () async {
      final transport = MockRouteTransport((uri, payload) async {
        return const AgentHttpResponse(
          statusCode: 404,
          body: '{"detail":"Not Found"}',
        );
      });

      final service = StrandsAgentApiService(
        baseUrl: 'https://dont-miss-backend.onrender.com',
        transport: transport,
      );

      expect(
        () => service.transcribeAudio([1, 2, 3]),
        throwsA(predicate<AiParsingException>((e) {
          return e.message.contains('temporarily unavailable') &&
              !e.message.contains('Not Found') &&
              !e.message.contains('10.0.2.2');
        })),
      );
    });
  });
}
