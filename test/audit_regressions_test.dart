import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dont_miss/models/ai_reminder_draft.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/models/user_profile.dart';
import 'package:dont_miss/providers/auth_provider.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/services/action_dispatch_service.dart';
import 'package:dont_miss/services/agent_http_transport.dart';
import 'package:dont_miss/services/agent_http_transport_io.dart';
import 'package:dont_miss/services/ai_agent_api_service.dart';
import 'package:dont_miss/services/ai_reminder_service.dart';
import 'package:dont_miss/services/auth_service.dart';
import 'package:dont_miss/services/notification_service.dart';
import 'package:dont_miss/services/reminder_sync_service.dart';
import 'package:dont_miss/services/voice_recording_service.dart';
import 'package:dont_miss/widgets/ai_confirmation_sheet.dart';
import 'package:dont_miss/widgets/auth_gate.dart';
import 'package:dont_miss/widgets/desktop/desktop_ai_centerpiece.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemTaskRepository implements TaskRepository {
  List<Task> tasks;
  _MemTaskRepository([List<Task>? initial]) : tasks = initial ?? [];

  @override
  Future<List<Task>> getAllTasks() async => List.from(tasks);

  @override
  Future<void> saveAllTasks(List<Task> newTasks) async {
    tasks = List.from(newTasks);
  }
}

class _SpyNotificationService implements NotificationService {
  final List<Task> scheduled = [];
  final List<int> cancelled = [];
  int cancelAllCount = 0;

  @override
  Future<void> init() async {}

  @override
  Future<bool?> requestPermissions() async => true;

  @override
  Future<void> scheduleTaskNotification(Task task) async {
    scheduled.add(task);
  }

  @override
  Future<void> cancelTaskNotification(int notificationId) async {
    cancelled.add(notificationId);
  }

  @override
  Future<void> cancelAllNotifications() async {
    cancelAllCount++;
  }
}

class _MutableAuthService implements AuthService {
  UserProfile? user;
  String? token;
  String? refreshTok;
  int refreshCalls = 0;
  String? nextRefreshedToken;

  _MutableAuthService({this.user, this.token});

  @override
  String? get currentToken => token;

  @override
  String? get currentRefreshToken => refreshTok;

  @override
  Future<String?> refreshSession() async {
    refreshCalls++;
    if (nextRefreshedToken != null) {
      token = nextRefreshedToken;
    }
    return nextRefreshedToken;
  }

  @override
  Future<UserProfile?> getCurrentUser() async => user;

  @override
  Future<bool> isAuthenticated() async => user != null && token != null;

  @override
  Future<UserProfile> signIn({
    required String phoneNumber,
    required String password,
  }) async {
    return user!;
  }

  @override
  Future<UserProfile> signUp({
    required String name,
    required String phoneNumber,
    required String password,
  }) async {
    return user!;
  }

  @override
  Future<bool> verifyPhone({
    required String phoneNumber,
    required String code,
  }) async =>
      true;

  @override
  Future<void> signOut() async {
    user = null;
    token = null;
    refreshTok = null;
  }
}

class _RecordingSyncService extends ReminderSyncService {
  bool clearAllDeletedCalled = false;
  List<Task> cloudTasksToReturn = [];

  _RecordingSyncService() : super(baseUrl: 'http://127.0.0.1:8000');

  @override
  Future<void> clearAllDeletedIds() async {
    clearAllDeletedCalled = true;
  }

  @override
  Future<SyncResult> sync(List<Task> localTasks, String authToken) async {
    return SyncResult(
      mergedTasks: cloudTasksToReturn,
      success: true,
      downloadedCount: cloudTasksToReturn.length,
    );
  }
}

class _MultipartTransport extends AgentHttpTransport {
  final Future<AgentHttpResponse> Function({
    required String kind,
    required Uri uri,
    Map<String, String>? headers,
    Map<String, dynamic>? payload,
    List<int>? fileBytes,
    String? filename,
  }) handler;

  _MultipartTransport(this.handler);

  @override
  bool get supportsMultipart => true;

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return handler(
      kind: 'json',
      uri: uri,
      headers: headers,
      payload: payload,
    );
  }

  @override
  Future<AgentHttpResponse> postMultipart({
    required Uri uri,
    required String fieldName,
    required List<int> fileBytes,
    required String filename,
    String contentType = 'application/octet-stream',
    Map<String, String>? fields,
    Map<String, String>? headers,
    required Duration timeout,
    dynamic clientFactory,
  }) {
    return handler(
      kind: 'multipart',
      uri: uri,
      headers: headers,
      fileBytes: fileBytes,
      filename: filename,
    );
  }
}

class _JsonRouteTransport extends AgentHttpTransport {
  final Future<AgentHttpResponse> Function(
    Uri uri,
    Map<String, dynamic> payload,
    Map<String, String>? headers,
  ) handler;

  _JsonRouteTransport(this.handler);

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return handler(uri, payload, headers);
  }
}

class _RecordingDispatchService implements ActionDispatchService {
  int singleCalls = 0;
  int batchCalls = 0;
  List<AiReminderDraft> lastBatchDrafts = [];
  String? lastIdempotencyKey;

  @override
  Future<bool> dispatchConfirmedAction({
    required AiReminderDraft draft,
    String? userPhoneNumber,
    String? userId,
    String? authToken,
    String? reminderId,
  }) async {
    singleCalls++;
    return true;
  }

  @override
  Future<BatchConfirmResult> dispatchBatchConfirmedActions({
    required List<AiReminderDraft> drafts,
    String? idempotencyKey,
    String? authToken,
  }) async {
    batchCalls++;
    lastBatchDrafts = drafts;
    lastIdempotencyKey = idempotencyKey;
    return BatchConfirmResult(
      success: true,
      status: 'CONFIRMED',
      totalRequested: drafts.length,
      totalCreated: drafts.length,
      createdReminderIds: drafts.map((d) => d.id ?? '').toList(),
      message: 'Synced cleanly',
    );
  }
}

class _MockMultiAiService implements AiReminderService {
  final List<AiReminderDraft> drafts;
  final Completer<String>? transcribeCompleter;

  _MockMultiAiService({
    required this.drafts,
    this.transcribeCompleter,
  });

  @override
  Future<AiReminderDraft> parsePrompt(
    String prompt, {
    DateTime? referenceTime,
  }) async =>
      drafts.first;

  @override
  Future<List<AiReminderDraft>> parseMultiPrompt(
    String prompt, {
    DateTime? referenceTime,
    String? timezone,
    String? authToken,
  }) async =>
      drafts;

  @override
  Future<String> transcribeAudio(
    List<int> audioBytes, {
    String filename = 'audio.m4a',
    String? language,
    String? authToken,
  }) async {
    if (transcribeCompleter != null) {
      return transcribeCompleter!.future;
    }
    return 'Transcribed speech';
  }
}

class _ControlledVoiceService implements VoiceRecordingService {
  final Object? startError;
  final StreamController<Duration> _ctrl =
      StreamController<Duration>.broadcast();
  bool _recording = false;

  _ControlledVoiceService({this.startError});

  @override
  Stream<Duration> get durationStream => _ctrl.stream;

  @override
  bool get isRecording => _recording;

  @override
  String get recordedFilename => 'voice_note.m4a';

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> startRecording() async {
    if (startError != null) throw startError!;
    _recording = true;
    _ctrl.add(const Duration(seconds: 1));
  }

  @override
  Future<List<int>?> stopRecording() async {
    _recording = false;
    return [1, 2, 3, 4];
  }

  @override
  Future<void> cancelRecording() async {
    _recording = false;
  }

  @override
  void dispose() {
    _ctrl.close();
  }
}

void main() {
  group('IoAgentHttpTransport real loopback HTTP verification', () {
    test('postJson sends explicit UTF-8 Content-Length and postMultipart streams raw audio bytes', () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        late String receivedJsonPath;
        late String? receivedJsonContentType;
        late int receivedJsonContentLength;
        late String receivedJsonBody;

        late String receivedMpPath;
        late String? receivedMpContentType;
        late String? receivedAuth;
        late List<int> receivedMpBytes;

        server.listen((HttpRequest req) async {
          final bytes = await req.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
          if (req.uri.path == '/agent/reminders/plan') {
            receivedJsonPath = req.uri.path;
            receivedJsonContentType = req.headers.contentType?.value;
            receivedJsonContentLength = req.headers.contentLength;
            receivedJsonBody = utf8.decode(bytes);
            req.response
              ..statusCode = 200
              ..write(jsonEncode({'success': true, 'reminders': []}))
              ..close();
          } else {
            receivedMpPath = req.uri.path;
            receivedMpContentType = req.headers.contentType?.value;
            receivedAuth = req.headers.value('authorization');
            receivedMpBytes = bytes;
            req.response
              ..statusCode = 200
              ..write(jsonEncode({'success': true, 'text': 'Remind me tomorrow'}))
              ..close();
          }
        });

        final transport = IoAgentHttpTransport();
        final baseUrl = 'http://127.0.0.1:${server.port}';

        final jsonResp = await transport.postJson(
          uri: Uri.parse('$baseUrl/agent/reminders/plan'),
          payload: {'prompt': 'Café meeting — 9 AM'},
          timeout: const Duration(seconds: 10),
        );
        expect(jsonResp.statusCode, 200);
        expect(receivedJsonPath, '/agent/reminders/plan');
        expect(receivedJsonContentType, 'application/json');
        expect(receivedJsonContentLength, utf8.encode(receivedJsonBody).length);
        expect(jsonDecode(receivedJsonBody)['prompt'], 'Café meeting — 9 AM');

        final rawAudio = [0x52, 0x49, 0x46, 0x46, 0x00, 0xFE, 0xED];
        final mpResp = await transport.postMultipart(
          uri: Uri.parse('$baseUrl/agent/voice/transcribe'),
          fieldName: 'file',
          fileBytes: rawAudio,
          filename: 'clip.m4a',
          contentType: 'audio/mp4',
          fields: {'language': 'en'},
          headers: {'Authorization': 'Bearer tok-123'},
          timeout: const Duration(seconds: 10),
        );
        expect(mpResp.statusCode, 200);
        expect(receivedMpPath, '/agent/voice/transcribe');
        expect(receivedMpContentType, contains('multipart/form-data'));
        expect(receivedAuth, 'Bearer tok-123');
        final textView = latin1.decode(receivedMpBytes);
        expect(textView, contains('name="file"; filename="clip.m4a"'));
        expect(textView, contains('name="language"\r\n\r\nen'));
      } finally {
        await server.close(force: true);
        HttpOverrides.global = prevOverrides;
      }
    });
  });

  group('StrandsAgentApiService 401 refresh, clarification propagation & multipart', () {
    test('parseMultiPrompt refreshes on 401 and retries successfully', () async {
      int calls = 0;
      String? refreshedWith;
      final transport = _JsonRouteTransport((uri, payload, headers) async {
        calls++;
        if (calls == 1) {
          return const AgentHttpResponse(statusCode: 401, body: '{"detail":"Expired"}');
        }
        refreshedWith = headers?['Authorization'];
        return AgentHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'reminders': [
              {
                'title': 'Send resume',
                'description': 'Mention project experience',
                'dueDate': '2026-12-01',
                'dueHour': 9,
                'dueMinute': 0,
                'priority': 'high',
                'recurrence': 'none',
              }
            ],
          }),
        );
      });

      final service = StrandsAgentApiService(
        baseUrl: 'https://dont-miss-backend.onrender.com',
        transport: transport,
        tokenRefresher: () async => 'fresh-jwt',
      );

      final drafts = await service.parseMultiPrompt(
        'Send resume tomorrow at 9 AM',
        timezone: 'Asia/Kolkata',
        authToken: 'stale-jwt',
      );
      expect(calls, 2);
      expect(refreshedWith, 'Bearer fresh-jwt');
      expect(drafts.single.title, 'Send resume');
      expect(drafts.single.description, 'Mention project experience');
    });

    test('parseMultiPrompt notifies onSessionExpired on repeated 401', () async {
      bool expiredNotified = false;
      final transport = _JsonRouteTransport((_, __, ___) async {
        return const AgentHttpResponse(statusCode: 401, body: '{"detail":"Invalid"}');
      });

      final service = StrandsAgentApiService(
        baseUrl: 'https://dont-miss-backend.onrender.com',
        transport: transport,
        tokenRefresher: () async => null,
        onSessionExpired: () => expiredNotified = true,
      );

      expect(
        () => service.parseMultiPrompt(
          'Remind me tomorrow',
          timezone: 'UTC',
          authToken: 'expired-jwt',
        ),
        throwsA(isA<AiParsingException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(expiredNotified, isTrue);
    });

    test('parseMultiPrompt propagates AI clarification from /agent/reminder on /plan 404 even with fallbackService', () async {
      final transport = _JsonRouteTransport((uri, payload, headers) async {
        if (uri.path == '/agent/reminders/plan') {
          return const AgentHttpResponse(statusCode: 404, body: '{"detail":"Not Found"}');
        }
        return AgentHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': false,
            'clarification_needed': 'What time would you like me to set that reminder?',
          }),
        );
      });

      final service = StrandsAgentApiService(
        baseUrl: 'https://dont-miss-backend.onrender.com',
        transport: transport,
        fallbackService: const LocalAiReminderService(),
      );

      expect(
        () => service.parseMultiPrompt(
          'Remind me to pay rent',
          timezone: 'Asia/Kolkata',
        ),
        throwsA(
          predicate<AiParsingException>(
            (e) => e.message.contains('What time would you like'),
          ),
        ),
      );
    });

    test('transcribeAudio uses postMultipart when supported and refreshes on 401', () async {
      int calls = 0;
      String? uploadKind;
      String? retryAuth;
      final transport = _MultipartTransport(({
        required String kind,
        required Uri uri,
        Map<String, String>? headers,
        Map<String, dynamic>? payload,
        List<int>? fileBytes,
        String? filename,
      }) async {
        calls++;
        uploadKind = kind;
        if (calls == 1) {
          return const AgentHttpResponse(statusCode: 401, body: '{"detail":"Expired"}');
        }
        retryAuth = headers?['Authorization'];
        return AgentHttpResponse(
          statusCode: 200,
          body: jsonEncode({'success': true, 'text': 'Submit report Friday at 6 PM'}),
        );
      });

      final service = StrandsAgentApiService(
        baseUrl: 'https://dont-miss-backend.onrender.com',
        transport: transport,
        tokenRefresher: () async => 'new-voice-jwt',
      );

      final transcript = await service.transcribeAudio(
        [10, 20, 30],
        filename: 'speech.m4a',
        authToken: 'old-voice-jwt',
      );
      expect(uploadKind, 'multipart');
      expect(calls, 2);
      expect(retryAuth, 'Bearer new-voice-jwt');
      expect(transcript, 'Submit report Friday at 6 PM');
    });
  });

  group('Multi-draft selection, unified IDs, and Desktop UI state regressions', () {
    testWidgets('AiConfirmationSheet shows checkboxes selected when draft.id is null and syncs unified batch UUIDs', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
      final authService = _MutableAuthService(
        user: UserProfile(
          id: 'u-1',
          name: 'Tester',
          phoneNumber: '+15551112222',
          isVerified: true,
          createdAt: DateTime(2026, 11, 20),
        ),
        token: 'jwt-valid',
      );
      final authProvider = AuthProvider(authService: authService);
      await authProvider.loadUser();

      final taskProvider = TaskProvider(
        repository: _MemTaskRepository(),
        notificationService: _SpyNotificationService(),
      );
      final dispatchService = _RecordingDispatchService();
      final multiAi = _MockMultiAiService(
        drafts: [
          AiReminderDraft(
            id: null,
            title: 'Hackathon Kickoff',
            dueDate: DateTime(2026, 12, 1),
            dueHour: 10,
            dueMinute: 0,
            rawPrompt: 'Hackathon at 10 AM',
          ),
          AiReminderDraft(
            id: null,
            title: 'Submit Assignment',
            dueDate: DateTime(2026, 12, 2),
            dueHour: 18,
            dueMinute: 0,
            rawPrompt: 'Submit assignment at 6 PM',
          ),
        ],
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<TaskProvider>.value(value: taskProvider),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AiConfirmationSheet(
                aiService: multiAi,
                actionDispatchService: dispatchService,
                voiceRecordingService: _ControlledVoiceService(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('ai_prompt_input')),
        'Hackathon and assignment',
      );
      await tester.tap(find.byKey(const Key('generate_draft_button')));
      await tester.pumpAndSettle();

      final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(checkboxes.length, 2);
      expect(checkboxes[0].value, isTrue);
      expect(checkboxes[1].value, isTrue);

      // Uncheck first card only
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      final updatedCheckboxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(updatedCheckboxes[0].value, isFalse);
      expect(updatedCheckboxes[1].value, isTrue);

      await tester.tap(find.byKey(const Key('confirm_batch_button')));
      await tester.pumpAndSettle();

      expect(taskProvider.totalCount, 1);
      expect(taskProvider.allTasks.single.title, 'Submit Assignment');
      expect(dispatchService.batchCalls, 1);
      expect(dispatchService.lastBatchDrafts.length, 1);
      expect(dispatchService.lastBatchDrafts.single.id, taskProvider.allTasks.single.id);
      expect(dispatchService.lastIdempotencyKey, isNotNull);
      expect(dispatchService.lastIdempotencyKey, isNotEmpty);
    });

    testWidgets('DesktopAiCenterpiece shows transcribing banner and clean VoiceRecordingException errors', (tester) async {
      final completer = Completer<String>();
      final ai = _MockMultiAiService(drafts: [], transcribeCompleter: completer);
      final voice = _ControlledVoiceService();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopAiCenterpiece(
              aiService: ai,
              voiceRecordingService: voice,
              onConfirmDraft: (_) {},
              onEditDraft: (_) {},
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('desktop_ai_mic_button')));
      await tester.pump();
      expect(find.textContaining('Listening...'), findsOneWidget);

      await tester.tap(find.byTooltip('Stop & Transcribe'));
      await tester.pump();
      expect(find.text('Transcribing your audio with AI...'), findsOneWidget);

      completer.complete('Tomorrow at 9 AM send resume');
      await tester.pumpAndSettle();
      expect(find.text('Transcribing your audio with AI...'), findsNothing);
      expect(find.text('Tomorrow at 9 AM send resume'), findsOneWidget);

      // Verify clean error message (without raw Exception: prefix)
      final deniedVoice = _ControlledVoiceService(
        startError: const VoiceRecordingException(
          'Microphone permission denied. Please enable access.',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopAiCenterpiece(
              key: const Key('denied_voice_centerpiece'),
              aiService: ai,
              voiceRecordingService: deniedVoice,
              onConfirmDraft: (_) {},
              onEditDraft: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('desktop_ai_mic_button')));
      await tester.pumpAndSettle();
      expect(
        find.text('Microphone permission denied. Please enable access.'),
        findsOneWidget,
      );
    });

    testWidgets('AuthGate passes actionDispatchService to Desktop HomeScreen batch flow', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
      final authService = _MutableAuthService(
        user: UserProfile(
          id: 'u-desktop',
          name: 'Desktop User',
          phoneNumber: '+15559990000',
          isVerified: true,
          createdAt: DateTime(2026, 11, 20),
        ),
        token: 'desktop-jwt',
      );
      final authProvider = AuthProvider(authService: authService);
      await authProvider.loadUser();

      final taskProvider = TaskProvider(
        repository: _MemTaskRepository(),
        notificationService: _SpyNotificationService(),
      );
      final dispatchService = _RecordingDispatchService();
      final multiAi = _MockMultiAiService(
        drafts: [
          AiReminderDraft(
            title: 'Task One',
            dueDate: DateTime(2026, 12, 1),
            dueHour: 9,
            dueMinute: 0,
            rawPrompt: 'Task One',
          ),
          AiReminderDraft(
            title: 'Task Two',
            dueDate: DateTime(2026, 12, 2),
            dueHour: 18,
            dueMinute: 0,
            rawPrompt: 'Task Two',
          ),
        ],
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<TaskProvider>.value(value: taskProvider),
          ],
          child: MaterialApp(
            home: AuthGate(
              aiService: multiAi,
              actionDispatchService: dispatchService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('desktop_ai_prompt_field')),
        'Task One and Task Two',
      );
      await tester.tap(find.byKey(const Key('desktop_ai_propose_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('desktop_ai_confirm_batch_button')));
      await tester.pumpAndSettle();

      expect(taskProvider.totalCount, 2);
      expect(dispatchService.batchCalls, 1);
      expect(dispatchService.lastIdempotencyKey, isNotEmpty);
    });
  });

  group('Account isolation, notification reconciliation & expired JWT cleanup', () {
    test('TaskProvider clears cached tasks, tombstones, and notifications on account switch and reconciles after sync', () async {
      SharedPreferences.setMockInitialValues({});
      final notifSpy = _SpyNotificationService();
      final repo = _MemTaskRepository([
        Task(
          id: 't-user-a',
          title: 'Private Task A',
          dueDate: DateTime(2026, 12, 1),
          dueHour: 10,
          dueMinute: 0,
          createdAt: DateTime(2026, 11, 20),
        ),
      ]);
      final syncSpy = _RecordingSyncService();
      final provider = TaskProvider(
        repository: repo,
        notificationService: notifSpy,
        syncService: syncSpy,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.totalCount, 1);

      final authService = _MutableAuthService(
        user: UserProfile(
          id: 'user-A',
          name: 'User A',
          phoneNumber: '+15550000001',
          createdAt: DateTime(2026, 11, 20),
        ),
        token: 'tok-A',
      );
      final authProvider = AuthProvider(authService: authService);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      provider.bindAuth(authProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Switch to User B with synced active + completed tasks
      final activeTaskB = Task(
        id: 't-user-b-1',
        title: 'Cloud Active B',
        dueDate: DateTime(2026, 12, 5),
        dueHour: 9,
        dueMinute: 30,
        createdAt: DateTime(2026, 11, 20),
      );
      final completedTaskB = Task(
        id: 't-user-b-2',
        title: 'Cloud Completed B',
        dueDate: DateTime(2026, 12, 6),
        dueHour: 11,
        dueMinute: 0,
        isCompleted: true,
        createdAt: DateTime(2026, 11, 20),
      );
      syncSpy.cloudTasksToReturn = [activeTaskB, completedTaskB];

      authService.user = UserProfile(
        id: 'user-B',
        name: 'User B',
        phoneNumber: '+15550000002',
        createdAt: DateTime(2026, 11, 20),
      );
      authService.token = 'tok-B';
      await authProvider.loadUser();

      provider.bindAuth(authProvider);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(notifSpy.cancelAllCount, greaterThanOrEqualTo(1));
      expect(syncSpy.clearAllDeletedCalled, isTrue);
      expect(provider.allTasks.map((t) => t.id), isNot(contains('t-user-a')));
      expect(provider.allTasks.map((t) => t.id), containsAll(['t-user-b-1', 't-user-b-2']));
      expect(notifSpy.scheduled.map((t) => t.id), contains('t-user-b-1'));
      expect(notifSpy.cancelled, contains(completedTaskB.notificationId));
    });

    test('ApiAuthService.getCurrentUser clears expired structural JWT when refresh fails', () async {
      final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}')).replaceAll('=', '');
      final pastExp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 3600;
      final payload = base64Url.encode(utf8.encode('{"sub":"u1","exp":$pastExp}')).replaceAll('=', '');
      final expiredJwt = '$header.$payload.sig';

      SharedPreferences.setMockInitialValues({
        'dont_miss_auth_user_v1': jsonEncode({
          'id': 'u1',
          'name': 'Expired User',
          'phoneNumber': '+15551234567',
          'isVerified': true,
          'createdAt': DateTime(2026, 11, 20).toIso8601String(),
        }),
        'dont_miss_auth_token_v1': expiredJwt,
        'dont_miss_auth_refresh_token_v1': expiredJwt,
      });

      final transport = _JsonRouteTransport((_, __, ___) async {
        return const AgentHttpResponse(statusCode: 401, body: '{"detail":"Expired"}');
      });
      final authService = ApiAuthService(
        baseUrl: 'https://dont-miss-backend.onrender.com',
        transport: transport,
      );

      final user = await authService.getCurrentUser();
      expect(user, isNull);
      expect(authService.currentToken, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dont_miss_auth_user_v1'), isNull);
      expect(prefs.getString('dont_miss_auth_token_v1'), isNull);
    });
  });
}
