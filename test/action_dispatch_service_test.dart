import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_miss/models/ai_reminder_draft.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/services/action_dispatch_service.dart';
import 'package:dont_miss/services/agent_http_transport.dart';

void main() {
  group('BackendActionDispatchService Unit Tests', () {
    final sampleDraft = AiReminderDraft(
      rawPrompt: 'Remind me tomorrow at 3:30 PM to review team PR',
      title: 'Review team PR',
      description: 'Check architecture and unit test coverage',
      dueDate: DateTime(2026, 10, 2),
      dueHour: 15,
      dueMinute: 30,
      priority: Priority.high,
      recurrence: Recurrence.none,
      channels: const ['local'],
    );

    final sampleWhatsAppDraft = AiReminderDraft(
      rawPrompt: 'Remind me on Oct 3 at 10 AM for doctor appointment on WhatsApp',
      title: 'Doctor appointment reminder',
      description: 'Bring medical reports',
      dueDate: DateTime(2026, 10, 3),
      dueHour: 10,
      dueMinute: 0,
      priority: Priority.high,
      recurrence: Recurrence.none,
      channels: const ['local', 'whatsapp'],
    );

    test('Local-only reminder dispatches POST /action/confirm for cloud persistence', () async {
      final mockTransport = _MockActionTransport(
        statusCode: 200,
        body: jsonEncode({'success': true, 'reminder_id': 'rem-123'}),
      );

      final service = BackendActionDispatchService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final result = await service.dispatchConfirmedAction(draft: sampleDraft);

      expect(result, isTrue);
      expect(mockTransport.invokedCount, 1);
      expect(mockTransport.lastUri?.path, '/action/confirm');
      expect(mockTransport.lastPayload?['action'], 'confirm_reminder');
      expect(mockTransport.lastPayload?['draft']['title'], 'Review team PR');
      expect(mockTransport.lastPayload?['draft']['channels'], contains('local'));
    });

    test('WhatsApp reminder dispatches POST /action/confirm with user_phone_number', () async {
      final mockTransport = _MockActionTransport(
        statusCode: 200,
        body: jsonEncode({'success': true, 'reminder_id': 'rem-456'}),
      );

      final service = BackendActionDispatchService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final result = await service.dispatchConfirmedAction(
        draft: sampleWhatsAppDraft,
        userPhoneNumber: '+1234567890',
      );

      expect(result, isTrue);
      expect(mockTransport.invokedCount, 1);
      expect(mockTransport.lastPayload?['user_phone_number'], '+1234567890');
      expect(mockTransport.lastPayload?['draft']['channels'], contains('whatsapp'));
    });

    test('Backend failure status (500) returns false without throwing exception', () async {
      final mockTransport = _MockActionTransport(
        statusCode: 500,
        body: jsonEncode({'detail': 'Internal database error'}),
      );

      final service = BackendActionDispatchService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final result = await service.dispatchConfirmedAction(draft: sampleDraft);

      expect(result, isFalse);
      expect(mockTransport.invokedCount, 1);
    });

    test('Backend success: false response returns false', () async {
      final mockTransport = _MockActionTransport(
        statusCode: 200,
        body: jsonEncode({'success': false, 'error': 'Database constraint violation'}),
      );

      final service = BackendActionDispatchService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final result = await service.dispatchConfirmedAction(draft: sampleDraft);

      expect(result, isFalse);
      expect(mockTransport.invokedCount, 1);
    });

    test('Network transport exception returns false gracefully without breaking client flow', () async {
      final mockTransport = _MockThrowingTransport();

      final service = BackendActionDispatchService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final result = await service.dispatchConfirmedAction(draft: sampleDraft);

      expect(result, isFalse);
    });
  });
}

class _MockActionTransport implements AgentHttpTransport {
  final int statusCode;
  final String body;
  int invokedCount = 0;
  Uri? lastUri;
  Map<String, dynamic>? lastPayload;

  _MockActionTransport({required this.statusCode, required this.body});

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    invokedCount++;
    lastUri = uri;
    lastPayload = payload;
    return AgentHttpResponse(statusCode: statusCode, body: body);
  }
}

class _MockThrowingTransport implements AgentHttpTransport {
  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    throw Exception('Connection refused: Backend unreachable');
  }
}
