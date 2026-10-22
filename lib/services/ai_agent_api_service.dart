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

  /// Production backend URL deployed on Render.
  static const String productionBaseUrl =
      'https://dont-miss-backend.onrender.com';

  /// Base URL configured at build/run time via `--dart-define=AGENT_BASE_URL=...`.
  static const String environmentBaseUrl =
      String.fromEnvironment('AGENT_BASE_URL', defaultValue: '');

  /// Default API base URL: resolves from --dart-define=AGENT_BASE_URL if supplied,
  /// otherwise uses production URL in release mode, and local URLs in development/debug mode.
  static String get defaultBaseUrl {
    if (environmentBaseUrl.isNotEmpty) {
      return environmentBaseUrl;
    }
    if (kReleaseMode) {
      return productionBaseUrl;
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

  static AiReminderDraft mapJsonToDraft(
    Map<String, dynamic> draftMap, {
    required String rawPrompt,
    required DateTime now,
    String? reasoning,
  }) {
    final title = draftMap['title'] as String? ?? 'Untitled Reminder';
    final description = draftMap['description'] as String? ?? '';
    final dueDateStr = (draftMap['dueDate'] ?? draftMap['due_date']) as String?;
    DateTime dueDate;
    if (dueDateStr != null && dueDateStr.isNotEmpty) {
      dueDate = DateTime.tryParse(dueDateStr) ?? now;
    } else {
      dueDate = now;
    }

    final rawHour = draftMap['dueHour'] ?? draftMap['due_hour'];
    final dueHour = rawHour is int ? rawHour : (rawHour != null ? int.tryParse(rawHour.toString()) : null) ?? 9;

    final rawMinute = draftMap['dueMinute'] ?? draftMap['due_minute'];
    final dueMinute = rawMinute is int ? rawMinute : (rawMinute != null ? int.tryParse(rawMinute.toString()) : null) ?? 0;

    final priority = Priority.fromString(draftMap['priority'] as String?);
    final recurrence = Recurrence.fromString(draftMap['recurrence'] as String?);
    final url = draftMap['url'] as String?;
    final channels = draftMap['channels'] != null
        ? List<String>.from(draftMap['channels'] as List)
        : const ['local', 'whatsapp'];

    final draftId = (draftMap['id'] as String?)?.trim();

    return AiReminderDraft(
      id: (draftId != null && draftId.isNotEmpty) ? draftId : null,
      title: title,
      description: description,
      dueDate: dueDate,
      dueHour: dueHour,
      dueMinute: dueMinute,
      priority: priority,
      recurrence: recurrence,
      url: url,
      channels: channels,
      reasoning: reasoning ?? draftMap['reasoning'] as String?,
      rawPrompt: rawPrompt,
    );
  }

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
        String? detail;
        try {
          final errJson = jsonDecode(response.body) as Map<String, dynamic>;
          detail = errJson['detail'] as String? ?? errJson['message'] as String?;
        } catch (_) {}
        final detailSuffix = (detail != null && detail.isNotEmpty) ? ': $detail' : '';
        throw AiParsingException(
          'AI Agent service returned status code ${response.statusCode}$detailSuffix',
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
      final dueDateStr = (draftMap['dueDate'] ?? draftMap['due_date']) as String?;
      DateTime dueDate;
      if (dueDateStr != null && dueDateStr.isNotEmpty) {
        dueDate = DateTime.tryParse(dueDateStr) ?? now;
      } else {
        dueDate = now;
      }
      final rawHour = draftMap['dueHour'] ?? draftMap['due_hour'];
      final dueHour = rawHour is int ? rawHour : (rawHour != null ? int.tryParse(rawHour.toString()) : null) ?? 9;

      final rawMinute = draftMap['dueMinute'] ?? draftMap['due_minute'];
      final dueMinute = rawMinute is int ? rawMinute : (rawMinute != null ? int.tryParse(rawMinute.toString()) : null) ?? 0;

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
      final draftId = (draftMap['id'] as String?)?.trim();

      return AiReminderDraft(
        id: (draftId != null && draftId.isNotEmpty) ? draftId : null,
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

  @override
  Future<List<AiReminderDraft>> parseMultiPrompt(
    String prompt, {
    DateTime? referenceTime,
    String? timezone,
    String? authToken,
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
      'timezone': timezone ?? 'Asia/Kolkata',
    };

    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    final uri = Uri.parse('$effectiveBaseUrl/agent/reminders/plan');

    try {
      final response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: timeout,
        headers: headers,
        clientFactory: clientFactory,
      );

      if (response.statusCode != 200) {
        // If the multi-reminder plan route is not yet available (HTTP 404),
        // gracefully fallback to the single-reminder endpoint POST /agent/reminder.
        if (response.statusCode == 404) {
          try {
            final singleDraft = await parsePrompt(prompt, referenceTime: referenceTime);
            return [singleDraft];
          } catch (_) {
            if (fallbackService != null) {
              return await fallbackService!.parseMultiPrompt(
                prompt,
                referenceTime: referenceTime,
                timezone: timezone,
                authToken: authToken,
              );
            }
          }
        }

        String? detail;
        try {
          final errJson = jsonDecode(response.body) as Map<String, dynamic>;
          detail = errJson['detail'] as String? ?? errJson['message'] as String?;
        } catch (_) {}
        final detailSuffix = (detail != null && detail.isNotEmpty) ? ': $detail' : '';
        throw AiParsingException(
          'AI Planning service returned status ${response.statusCode}$detailSuffix',
        );
      }

      final Map<String, dynamic> data =
          jsonDecode(response.body) as Map<String, dynamic>;
      final success = data['success'] as bool? ?? false;

      if (!success) {
        final clarification = data['clarification_needed'] as String?;
        final error = clarification ??
            data['error'] as String? ??
            data['message'] as String? ??
            'AI Agent could not propose reminders.';
        throw AiParsingException(error);
      }

      final remindersList = data['reminders'] as List?;
      if (remindersList == null || remindersList.isEmpty) {
        throw const AiParsingException('No reminder proposals returned by AI.');
      }

      final List<AiReminderDraft> drafts = [];
      for (final item in remindersList) {
        if (item is Map<String, dynamic>) {
          drafts.add(mapJsonToDraft(item, rawPrompt: cleanPrompt, now: now));
        }
      }

      return drafts;
    } on AgentNetworkException catch (e) {
      if (fallbackService != null) {
        debugPrint(
          'StrandsAgentApiService: Connection failed ($e). Delegating to fallback service.',
        );
        return fallbackService!.parseMultiPrompt(prompt, referenceTime: referenceTime, timezone: timezone, authToken: authToken);
      }
      throw const AiParsingException(
        'Could not connect to AI backend. Please verify your internet connection and ensure the agent service is running.',
      );
    } catch (e) {
      if (e is AiParsingException) {
        rethrow;
      }
      if (fallbackService != null) {
        return fallbackService!.parseMultiPrompt(prompt, referenceTime: referenceTime, timezone: timezone, authToken: authToken);
      }
      throw AiParsingException('Error communicating with AI Agent: $e');
    }
  }

  @override
  Future<String> transcribeAudio(
    List<int> audioBytes, {
    String filename = 'audio.m4a',
    String? language,
    String? authToken,
  }) async {
    if (audioBytes.isEmpty) {
      throw const AiParsingException('Audio recording is empty (0 bytes).');
    }

    final audioBase64 = base64Encode(audioBytes);
    final payload = {
      'audio_base64': audioBase64,
      'filename': filename,
      if (language != null) 'language': language,
    };

    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    final uri = Uri.parse('$effectiveBaseUrl/agent/voice/transcribe');

    try {
      final response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: timeout,
        headers: headers,
        clientFactory: clientFactory,
      );

      if (response.statusCode != 200) {
        if (response.statusCode == 404) {
          throw const AiParsingException(
            'Voice transcription service is temporarily unavailable on the server. Please try again shortly or type your reminder.',
          );
        }
        String? detail;
        try {
          final errJson = jsonDecode(response.body) as Map<String, dynamic>;
          detail = errJson['detail'] as String? ?? errJson['message'] as String?;
        } catch (_) {}
        final detailSuffix = (detail != null && detail.isNotEmpty) ? ': $detail' : '';
        throw AiParsingException('Voice transcription error (${response.statusCode})$detailSuffix');
      }

      final Map<String, dynamic> data =
          jsonDecode(response.body) as Map<String, dynamic>;
      final success = data['success'] as bool? ?? false;
      final text = (data['text'] as String? ?? '').trim();

      if (!success) {
        final error = data['error'] as String? ??
            data['message'] as String? ??
            'Audio transcription failed.';
        throw AiParsingException(error);
      }

      if (text.isEmpty) {
        final msg = data['message'] as String? ??
            'No speech detected in audio. Please speak clearly and try again.';
        throw AiParsingException(msg);
      }

      return text;
    } on AgentNetworkException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('timed out') || msg.contains('timeout')) {
        throw const AiParsingException(
          'Network connection timed out while reaching voice service. Please check your internet connection and try again.',
        );
      }
      throw const AiParsingException(
        'Could not connect to voice service. Please verify your internet connection and try again.',
      );
    } catch (e) {
      if (e is AiParsingException) rethrow;
      final msg = e.toString().toLowerCase();
      if (msg.contains('401') || msg.contains('unauthorized')) {
        throw const AiParsingException(
          'Authentication session expired. Please sign in again.',
        );
      }
      if (msg.contains('503') || msg.contains('service unavailable')) {
        throw const AiParsingException(
          'Voice service is temporarily unavailable. Please try again shortly.',
        );
      }
      if (msg.contains('429') || msg.contains('rate limit')) {
        throw const AiParsingException(
          'Voice transcription rate limit reached. Please wait a moment and try again.',
        );
      }
      throw const AiParsingException(
        'Voice transcription could not be completed. Please try again.',
      );
    }
  }
}
