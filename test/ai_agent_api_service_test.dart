import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/services/agent_http_transport.dart';
import 'package:dont_miss/services/ai_agent_api_service.dart';
import 'package:dont_miss/services/ai_reminder_service.dart';

void main() {
  setUpAll(() {
    HttpOverrides.global = null;
  });

  final fixedTime = DateTime(2026, 9, 20, 10, 30); // 2026-09-20 10:30

  group('StrandsAgentApiService Unit Tests', () {
    test('Successful backend proposal maps accurately to AiReminderDraft', () async {
      final mockResponseData = {
        'success': true,
        'proposal': {
          'status': 'PROPOSED',
          'action': 'create_reminder',
          'requires_confirmation': true,
          'raw_prompt':
              'Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare interview questions.',
          'draft': {
            'title': 'Amazon interview',
            'description': 'I need to prepare interview questions.',
            'dueDate': '2026-09-21',
            'dueHour': 21,
            'dueMinute': 0,
            'priority': 'high',
            'recurrence': 'none',
            'url': null,
            'reasoning': 'Extracted via Strands create_reminder tool',
          },
        },
        'message': 'Proposal created successfully',
      };

      // Create an in-memory HTTP server to mock FastAPI
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/agent/reminder');

        final body = await utf8.decoder.bind(request).join();
        final jsonBody = jsonDecode(body) as Map<String, dynamic>;

        expect(jsonBody['prompt'], contains('Amazon interview'));
        expect(jsonBody['current_date'], '2026-09-20');
        expect(jsonBody['current_time'], '10:30');

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(mockResponseData));
        await request.response.close();
      });

      try {
        final service = StrandsAgentApiService(
          baseUrl: 'http://${server.address.host}:${server.port}',
          timeout: const Duration(seconds: 5),
        );

        final draft = await service.parsePrompt(
          'Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare interview questions.',
          referenceTime: fixedTime,
        );

        expect(draft.title, 'Amazon interview');
        expect(draft.description, 'I need to prepare interview questions.');
        expect(draft.dueDate.year, 2026);
        expect(draft.dueDate.month, 9);
        expect(draft.dueDate.day, 21);
        expect(draft.dueHour, 21);
        expect(draft.dueMinute, 0);
        expect(draft.priority, Priority.high);
        expect(draft.recurrence, Recurrence.none);
        expect(draft.reasoning, contains('Strands'));
        expect(draft.rawPrompt, contains('Amazon interview'));
      } finally {
        await server.close(force: true);
      }
    });

    test('Backend failure status throws AiParsingException', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Internal Server Error');
        await request.response.close();
      });

      try {
        final service = StrandsAgentApiService(
          baseUrl: 'http://${server.address.host}:${server.port}',
          timeout: const Duration(seconds: 5),
        );

        await expectLater(
          service.parsePrompt('Buy groceries tomorrow at 10 AM', referenceTime: fixedTime),
          throwsA(isA<AiParsingException>()),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('Backend success=false response throws AiParsingException with error detail', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'success': false,
            'error': 'Agent did not propose a reminder for this prompt.',
          }));
        await request.response.close();
      });

      try {
        final service = StrandsAgentApiService(
          baseUrl: 'http://${server.address.host}:${server.port}',
          timeout: const Duration(seconds: 5),
        );

        await expectLater(
          service.parsePrompt('Hello world', referenceTime: fixedTime),
          throwsA(predicate((e) =>
              e is AiParsingException &&
              e.message.contains('Agent did not propose a reminder'))),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('Offline backend falls back to fallbackService if configured', () async {
      // Pointing to an unused port with no server running
      const offlineService = StrandsAgentApiService(
        baseUrl: 'http://127.0.0.1:59999',
        fallbackService: LocalAiReminderService(),
      );

      final draft = await offlineService.parsePrompt(
        'Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare questions',
        referenceTime: fixedTime,
      );

      expect(draft.title, 'Amazon interview');
      expect(draft.dueHour, 21);
      expect(draft.dueMinute, 0);
      expect(draft.priority, Priority.high);
    });

    test('Offline backend throws AiParsingException if no fallbackService is provided', () async {
      const offlineService = StrandsAgentApiService(
        baseUrl: 'http://127.0.0.1:59999',
        fallbackService: null,
      );

      await expectLater(
        offlineService.parsePrompt(
          'Remind me tomorrow at 9 PM about my Amazon interview',
          referenceTime: fixedTime,
        ),
        throwsA(isA<AiParsingException>()),
      );
    });

    test('Empty prompt throws AiParsingException before network request', () async {
      const service = StrandsAgentApiService();

      await expectLater(
        service.parsePrompt('   ', referenceTime: fixedTime),
        throwsA(isA<AiParsingException>()),
      );
    });

    test('BaseUrl configuration resolves correctly', () {
      const custom = StrandsAgentApiService(baseUrl: 'http://custom-host:9000');
      expect(custom.effectiveBaseUrl, 'http://custom-host:9000');

      expect(StrandsAgentApiService.environmentBaseUrl, isEmpty);

      const defaultService = StrandsAgentApiService();
      expect(defaultService.effectiveBaseUrl, StrandsAgentApiService.defaultBaseUrl);
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        expect(StrandsAgentApiService.defaultBaseUrl, 'http://10.0.2.2:8000');
      } else {
        expect(StrandsAgentApiService.defaultBaseUrl, 'http://127.0.0.1:8000');
      }
    });

    test('Custom AgentHttpTransport can be injected and executed', () async {
      final mockTransport = _MockAgentHttpTransport(
        statusCode: 200,
        body: jsonEncode({
          'success': true,
          'proposal': {
            'status': 'PROPOSED',
            'action': 'create_reminder',
            'requires_confirmation': true,
            'raw_prompt': 'Buy milk',
            'draft': {
              'title': 'Buy milk',
              'description': '',
              'dueDate': '2026-09-21',
              'dueHour': 10,
              'dueMinute': 0,
              'priority': 'medium',
              'recurrence': 'none',
            },
          },
        }),
      );

      final service = StrandsAgentApiService(
        transport: mockTransport,
      );

      final draft = await service.parsePrompt('Buy milk', referenceTime: fixedTime);
      expect(draft.title, 'Buy milk');
      expect(mockTransport.called, isTrue);
    });
  });
}

class _MockAgentHttpTransport implements AgentHttpTransport {
  final int statusCode;
  final String body;
  bool called = false;

  _MockAgentHttpTransport({required this.statusCode, required this.body});

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    dynamic clientFactory,
  }) async {
    called = true;
    return AgentHttpResponse(statusCode: statusCode, body: body);
  }
}

