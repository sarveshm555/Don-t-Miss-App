import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/services/agent_http_transport.dart';
import 'package:dont_miss/services/reminder_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReminderSyncService Unit Tests', () {
    test('1. Cloud reminder parsing converts json map to Task model correctly', () {
      final jsonMap = {
        'id': 'rem-abc-123',
        'user_id': 'usr-xyz',
        'title': 'Doctor Visit',
        'description': 'Annual health checkup',
        'due_date': '2026-10-15',
        'due_hour': 14,
        'due_minute': 30,
        'priority': 'high',
        'recurrence': 'monthly',
        'url': 'https://clinic.example.com',
        'status': 'COMPLETED',
        'raw_prompt': 'Remind me for doctor visit',
        'created_at': '2026-10-01T08:00:00.000Z',
        'updated_at': '2026-10-01T09:30:00.000Z',
      };

      final task = ReminderSyncService.parseCloudReminder(jsonMap);

      expect(task.id, 'rem-abc-123');
      expect(task.title, 'Doctor Visit');
      expect(task.description, 'Annual health checkup');
      expect(task.dueDate.year, 2026);
      expect(task.dueDate.month, 10);
      expect(task.dueDate.day, 15);
      expect(task.dueHour, 14);
      expect(task.dueMinute, 30);
      expect(task.priority, Priority.high);
      expect(task.recurrence, Recurrence.monthly);
      expect(task.url, 'https://clinic.example.com');
      expect(task.isCompleted, isTrue);
      expect(task.createdAt, DateTime.parse('2026-10-01T08:00:00.000Z'));
      expect(task.updatedAt, DateTime.parse('2026-10-01T09:30:00.000Z'));
    });

    test('2. Sync request includes JWT authorization header', () async {
      final mockTransport = _MockSyncTransport(
        handler: (method, uri, payload, headers) {
          expect(headers?['Authorization'], 'Bearer test.secret.jwt.token');
          return AgentHttpResponse(
            statusCode: 200,
            body: jsonEncode([]),
          );
        },
      );

      final service = ReminderSyncService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final reminders = await service.fetchCloudReminders('test.secret.jwt.token');
      expect(reminders, isEmpty);
      expect(mockTransport.callCount, 1);
    });

    test('3. Local-only reminder is uploaded to cloud', () async {
      final localTask = Task(
        id: 'local-task-1',
        title: 'Offline Created Task',
        description: 'Sync this to cloud',
        dueDate: DateTime(2026, 10, 10),
        dueHour: 10,
        dueMinute: 0,
        priority: Priority.high,
        recurrence: Recurrence.none,
        createdAt: DateTime(2026, 10, 1, 10, 0),
        updatedAt: DateTime(2026, 10, 1, 10, 0),
      );

      bool uploaded = false;
      final mockTransport = _MockSyncTransport(
        handler: (method, uri, payload, headers) {
          if (method == 'GET' && uri.path == '/reminders') {
            return const AgentHttpResponse(statusCode: 200, body: '[]');
          }
          if (method == 'POST' && uri.path == '/reminders') {
            uploaded = true;
            expect(payload?['id'], 'local-task-1');
            expect(payload?['title'], 'Offline Created Task');
            return AgentHttpResponse(
              statusCode: 201,
              body: jsonEncode({
                'id': 'local-task-1',
                'user_id': 'usr-1',
                'title': 'Offline Created Task',
                'description': 'Sync this to cloud',
                'due_date': '2026-10-10',
                'due_hour': 10,
                'due_minute': 0,
                'priority': 'high',
                'recurrence': 'none',
                'status': 'CONFIRMED',
                'created_at': DateTime(2026, 10, 1, 10, 0).toIso8601String(),
                'updated_at': DateTime(2026, 10, 1, 10, 0).toIso8601String(),
              }),
            );
          }
          throw UnimplementedError();
        },
      );

      final service = ReminderSyncService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final result = await service.sync([localTask], 'token-123');

      expect(result.success, isTrue);
      expect(uploaded, isTrue);
      expect(result.uploadedCount, 1);
      expect(result.mergedTasks.length, 1);
      expect(result.mergedTasks.first.id, 'local-task-1');
    });

    test('4. Cloud-only reminder is downloaded locally', () async {
      final cloudJson = {
        'id': 'cloud-rem-1',
        'user_id': 'usr-1',
        'title': 'Remote Cloud Task',
        'description': 'Created on web or another device',
        'due_date': '2026-10-12',
        'due_hour': 11,
        'due_minute': 30,
        'priority': 'medium',
        'recurrence': 'none',
        'status': 'CONFIRMED',
        'created_at': '2026-10-01T10:00:00.000Z',
        'updated_at': '2026-10-01T10:00:00.000Z',
      };

      final mockTransport = _MockSyncTransport(
        handler: (method, uri, payload, headers) {
          if (method == 'GET' && uri.path == '/reminders') {
            return AgentHttpResponse(statusCode: 200, body: jsonEncode([cloudJson]));
          }
          throw UnimplementedError();
        },
      );

      final service = ReminderSyncService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final result = await service.sync([], 'token-123');

      expect(result.success, isTrue);
      expect(result.downloadedCount, 1);
      expect(result.mergedTasks.length, 1);
      expect(result.mergedTasks.first.id, 'cloud-rem-1');
      expect(result.mergedTasks.first.title, 'Remote Cloud Task');
    });

    test('5. Newer record wins when timestamps are available', () async {
      // 5A: Cloud is newer -> Cloud wins
      final localOlder = Task(
        id: 'shared-id-1',
        title: 'Local Older Title',
        dueDate: DateTime(2026, 10, 10),
        dueHour: 10,
        dueMinute: 0,
        createdAt: DateTime(2026, 10, 1, 8, 0),
        updatedAt: DateTime(2026, 10, 1, 9, 0),
      );

      final cloudNewerJson = {
        'id': 'shared-id-1',
        'user_id': 'usr-1',
        'title': 'Cloud Newer Title Wins',
        'due_date': '2026-10-10',
        'due_hour': 10,
        'due_minute': 0,
        'priority': 'medium',
        'recurrence': 'none',
        'status': 'CONFIRMED',
        'created_at': DateTime(2026, 10, 1, 8, 0).toIso8601String(),
        'updated_at': DateTime(2026, 10, 1, 11, 0).toIso8601String(), // Newer!
      };

      final mockTransportA = _MockSyncTransport(
        handler: (method, uri, payload, headers) {
          return AgentHttpResponse(statusCode: 200, body: jsonEncode([cloudNewerJson]));
        },
      );

      final serviceA = ReminderSyncService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransportA,
      );

      final resultA = await serviceA.sync([localOlder], 'token-123');
      expect(resultA.mergedTasks.first.title, 'Cloud Newer Title Wins');
      expect(resultA.downloadedCount, 1);

      // 5B: Local is newer -> Local wins and pushes PUT to cloud
      bool putCalled = false;
      final localNewer = Task(
        id: 'shared-id-2',
        title: 'Local Newer Title Wins',
        dueDate: DateTime(2026, 10, 10),
        dueHour: 10,
        dueMinute: 0,
        createdAt: DateTime(2026, 10, 1, 8, 0),
        updatedAt: DateTime(2026, 10, 1, 14, 0), // Newer!
      );

      final cloudOlderJson = {
        'id': 'shared-id-2',
        'user_id': 'usr-1',
        'title': 'Cloud Older Title',
        'due_date': '2026-10-10',
        'due_hour': 10,
        'due_minute': 0,
        'priority': 'medium',
        'recurrence': 'none',
        'status': 'CONFIRMED',
        'created_at': DateTime(2026, 10, 1, 8, 0).toIso8601String(),
        'updated_at': DateTime(2026, 10, 1, 9, 0).toIso8601String(),
      };

      final mockTransportB = _MockSyncTransport(
        handler: (method, uri, payload, headers) {
          if (method == 'GET') {
            return AgentHttpResponse(statusCode: 200, body: jsonEncode([cloudOlderJson]));
          }
          if (method == 'PUT' && uri.path == '/reminders/shared-id-2') {
            putCalled = true;
            expect(payload?['title'], 'Local Newer Title Wins');
            return AgentHttpResponse(
              statusCode: 200,
              body: jsonEncode({
                ...cloudOlderJson,
                'title': 'Local Newer Title Wins',
                'updated_at': DateTime(2026, 10, 1, 14, 0).toIso8601String(),
              }),
            );
          }
          throw UnimplementedError();
        },
      );

      final serviceB = ReminderSyncService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransportB,
      );

      final resultB = await serviceB.sync([localNewer], 'token-123');
      expect(resultB.mergedTasks.first.title, 'Local Newer Title Wins');
      expect(putCalled, isTrue);
      expect(resultB.updatedCount, 1);
    });

    test('6. Cloud failure does not destroy local reminder', () async {
      final localTasks = [
        Task(
          id: 'task-preserve-1',
          title: 'Preserve 1',
          dueDate: DateTime(2026, 10, 10),
          dueHour: 10,
          dueMinute: 0,
          createdAt: DateTime.now(),
        ),
        Task(
          id: 'task-preserve-2',
          title: 'Preserve 2',
          dueDate: DateTime(2026, 10, 11),
          dueHour: 11,
          dueMinute: 0,
          createdAt: DateTime.now(),
        ),
      ];

      final throwingTransport = _MockSyncTransport(
        handler: (method, uri, payload, headers) {
          throw const AgentNetworkException('Server connection failed: 503');
        },
      );

      final service = ReminderSyncService(
        baseUrl: 'http://localhost:8000',
        transport: throwingTransport,
      );

      final result = await service.sync(localTasks, 'token-123');

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Server connection failed'));
      // Local reminders MUST be completely preserved
      expect(result.mergedTasks.length, 2);
      expect(result.mergedTasks[0].id, 'task-preserve-1');
      expect(result.mergedTasks[1].id, 'task-preserve-2');
    });

    test('7. Duplicate reminder IDs are not duplicated locally', () async {
      final localTask = Task(
        id: 'dedup-task-id',
        title: 'Local DeDup Title',
        dueDate: DateTime(2026, 10, 10),
        dueHour: 10,
        dueMinute: 0,
        createdAt: DateTime(2026, 10, 1, 8, 0),
        updatedAt: DateTime(2026, 10, 1, 8, 0),
      );

      final cloudDuplicate = {
        'id': 'dedup-task-id',
        'user_id': 'usr-1',
        'title': 'Cloud DeDup Title',
        'due_date': '2026-10-10',
        'due_hour': 10,
        'due_minute': 0,
        'priority': 'medium',
        'recurrence': 'none',
        'status': 'CONFIRMED',
        'created_at': DateTime(2026, 10, 1, 8, 0).toIso8601String(),
        'updated_at': DateTime(2026, 10, 1, 8, 0).toIso8601String(),
      };

      final mockTransport = _MockSyncTransport(
        handler: (method, uri, payload, headers) {
          return AgentHttpResponse(statusCode: 200, body: jsonEncode([cloudDuplicate]));
        },
      );

      final service = ReminderSyncService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final result = await service.sync([localTask], 'token-123');

      expect(result.success, isTrue);
      // Merged tasks must have exactly 1 record, never 2
      expect(result.mergedTasks.length, 1);
      expect(result.mergedTasks.first.id, 'dedup-task-id');
    });

    test('8. Offline deletion tombstone propagates deletion to cloud', () async {
      final cloudJson = {
        'id': 'to-delete-cloud-id',
        'user_id': 'usr-1',
        'title': 'Deleted Locally Offline',
        'due_date': '2026-10-15',
        'due_hour': 10,
        'due_minute': 0,
        'priority': 'medium',
        'recurrence': 'none',
        'status': 'CONFIRMED',
        'created_at': '2026-10-01T10:00:00.000Z',
        'updated_at': '2026-10-01T10:00:00.000Z',
      };

      bool deleteInvoked = false;
      final mockTransport = _MockSyncTransport(
        handler: (method, uri, payload, headers) {
          if (method == 'GET') {
            return AgentHttpResponse(statusCode: 200, body: jsonEncode([cloudJson]));
          }
          if (method == 'DELETE' && uri.path == '/reminders/to-delete-cloud-id') {
            deleteInvoked = true;
            return const AgentHttpResponse(statusCode: 200, body: '{"success": true}');
          }
          throw UnimplementedError();
        },
      );

      final service = ReminderSyncService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      // Record offline deletion tombstone
      await service.recordLocalDeletion('to-delete-cloud-id');

      final result = await service.sync([], 'token-123');

      expect(result.success, isTrue);
      expect(deleteInvoked, isTrue);
      expect(result.deletedCount, 1);
      expect(result.mergedTasks, isEmpty);
      // Tombstone should be cleared after successful propagation
      final remainingDeleted = await service.getDeletedTaskIds();
      expect(remainingDeleted, isNot(contains('to-delete-cloud-id')));
    });

    test('11. Cloud reminder parsing and payload serialization preserve channels', () {
      final jsonMap = {
        'id': 'rem-channels-1',
        'title': 'Channels Test',
        'due_date': '2026-10-20',
        'due_hour': 18,
        'due_minute': 0,
        'channels': ['whatsapp'],
      };

      final parsed = ReminderSyncService.parseCloudReminder(jsonMap);
      expect(parsed.channels, equals(['whatsapp']));

      final payload = ReminderSyncService.taskToCloudPayload(parsed);
      expect(payload['channels'], equals(['whatsapp']));
    });
  });
}

class _MockSyncTransport extends AgentHttpTransport {
  final AgentHttpResponse Function(
    String method,
    Uri uri,
    Map<String, dynamic>? payload,
    Map<String, String>? headers,
  ) handler;
  int callCount = 0;

  _MockSyncTransport({required this.handler});

  @override
  Future<AgentHttpResponse> get({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    callCount++;
    return handler('GET', uri, null, headers);
  }

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    callCount++;
    return handler('POST', uri, payload, headers);
  }

  @override
  Future<AgentHttpResponse> putJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    callCount++;
    return handler('PUT', uri, payload, headers);
  }

  @override
  Future<AgentHttpResponse> delete({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    callCount++;
    return handler('DELETE', uri, null, headers);
  }
}
