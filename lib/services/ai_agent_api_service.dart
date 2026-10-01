import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/ai_reminder_draft.dart';
import '../models/priority.dart';
import '../models/recurrence.dart';
import 'agent_http_transport.dart';
import 'ai_reminder_service.dart';

/// Service that delegates natural-language reminder parsing to the
/// FastAPI Strands Agents SDK backend at `POST /agent/reminder`.
class StrandsAgentApiService implements AiReminderService {
  final String? baseUrl;
  final Duration timeout;
  final AiReminderService? fallbackService;
  final dynamic clientFactory;
  final AgentHttpTransport? transport;

  const StrandsAgentApiService({
    this.baseUrl,
    this.timeout = const Duration(seconds: 180),
    this.fallbackService,
    this.clientFactory,
    this.transport,
  });

  /// Base URL configured at build/run time via `--dart-define=AGENT_BASE_URL=...`.
  static const String environmentBaseUrl =
      String.fromEnvironment('AGENT_BASE_URL', defaultValue: '');

  /// Default API base URL: resolves from --dart-define=AGENT_BASE_URL if supplied,
  /// otherwise 10.0.2.2:8000 for Android emulator and 127.0.0.1:8000 for other platforms.
  static String get defaultBaseUrl {
    if (environmentBaseUrl.isNotEmpty) {
      return environmentBaseUrl;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000';
    }
    return 'http://127.0.0.1:8000';
  }

  /// The active base URL resolving configured URL or platform default.
  String get effectiveBaseUrl => baseUrl ?? defaultBaseUrl;

  /// The active HTTP transport (explicit transport or platform-specific conditional import).
  AgentHttpTransport get effectiveTransport =>
      transport ?? createAgentHttpTransport();

  @override
  Future<AiReminderDraft> parsePrompt(
    String prompt, {
    DateTime? referenceTime,
  }) async {
    final cleanPrompt = prompt.trim();
    if (cleanPrompt.isEmpty) {
      throw const AiParsingException('Please enter a reminder request.');
    }

    final now = referenceTime ?? DateTime.now();
    final currentDate =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final currentTime =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final payload = {
      'prompt': cleanPrompt,
      'current_date': currentDate,
      'current_time': currentTime,
    };

    final uri = Uri.parse('$effectiveBaseUrl/agent/reminder');

    try {
      final response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: timeout,
        clientFactory: clientFactory,
      );

      if (response.statusCode != 200) {
        throw AiParsingException(
          'AI Agent service returned status code ${response.statusCode}: ${response.body}',
        );
      }

      final Map<String, dynamic> data =
          jsonDecode(response.body) as Map<String, dynamic>;
      final success = data['success'] as bool? ?? false;

      if (!success) {
        final error = data['error'] as String? ??
            data['message'] as String? ??
            'AI Agent could not propose a reminder.';
        throw AiParsingException(error);
      }

      final proposal = data['proposal'] as Map<String, dynamic>?;
      if (proposal == null) {
        throw const AiParsingException('No reminder proposal received from AI Agent.');
      }

      final draftMap = proposal['draft'] as Map<String, dynamic>?;
      if (draftMap == null) {
        throw const AiParsingException('Proposal missing reminder draft data.');
      }

      final title = draftMap['title'] as String? ?? 'Untitled Reminder';
      final description = draftMap['description'] as String? ?? '';
      final dueDateStr = draftMap['dueDate'] as String?;
      DateTime dueDate;
      if (dueDateStr != null && dueDateStr.isNotEmpty) {
        dueDate = DateTime.tryParse(dueDateStr) ?? now;
      } else {
        dueDate = now;
      }
      final dueHour = draftMap['dueHour'] as int? ?? 9;
      final dueMinute = draftMap['dueMinute'] as int? ?? 0;
      final priority = Priority.fromString(draftMap['priority'] as String?);
      final recurrence = Recurrence.fromString(draftMap['recurrence'] as String?);
      final url = draftMap['url'] as String?;
      final channels = draftMap['channels'] != null
          ? List<String>.from(draftMap['channels'] as List)
          : const ['local', 'whatsapp'];
      final reasoning = draftMap['reasoning'] as String? ??
          proposal['message'] as String? ??
          data['message'] as String?;
      final rawPrompt = proposal['raw_prompt'] as String? ?? cleanPrompt;

      return AiReminderDraft(
        title: title,
        description: description,
        dueDate: dueDate,
        dueHour: dueHour,
        dueMinute: dueMinute,
        priority: priority,
        recurrence: recurrence,
        url: url,
        channels: channels,
        reasoning: reasoning,
        rawPrompt: rawPrompt,
      );
    } on AgentNetworkException catch (e) {
      if (fallbackService != null) {
        debugPrint(
          'StrandsAgentApiService: Connection to $effectiveBaseUrl failed ($e). Delegating to fallback service.',
        );
        return fallbackService!.parsePrompt(prompt, referenceTime: referenceTime);
      }
      throw AiParsingException(
        'Could not connect to AI backend at $effectiveBaseUrl. Ensure the Strands agent service is running.',
      );
    } catch (e) {
      if (e is AiParsingException) {
        rethrow;
      }
      if (fallbackService != null) {
        debugPrint(
          'StrandsAgentApiService: Network error ($e). Delegating to fallback service.',
        );
        return fallbackService!.parsePrompt(prompt, referenceTime: referenceTime);
      }
      throw AiParsingException('Error communicating with AI Agent: $e');
    }
  }
}
