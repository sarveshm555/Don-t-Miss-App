import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import '../models/ai_reminder_draft.dart';
import '../models/priority.dart';
import '../models/recurrence.dart';
import 'agent_http_transport.dart';
import 'ai_reminder_service.dart';
import 'auth_service.dart';

/// Service that delegates natural-language reminder parsing to the
/// FastAPI OpenAI Agents backend at `POST /agent/reminders/plan` & `/agent/reminder`.
class StrandsAgentApiService implements AiReminderService {
  final String? baseUrl;
  final Duration timeout;
  final AiReminderService? fallbackService;
  final dynamic clientFactory;
  final AgentHttpTransport? transport;
  final Future<String?> Function()? tokenRefresher;
  final VoidCallback? onSessionExpired;

  static String? _cachedDeviceTimezone;

  const StrandsAgentApiService({
    this.baseUrl,
    this.timeout = const Duration(seconds: 180),
    this.fallbackService,
    this.clientFactory,
    this.transport,
    this.tokenRefresher,
    this.onSessionExpired,
  });

  /// Returns device IANA timezone name with safe caching and Asia/Kolkata fallback.
  static Future<String> resolveDeviceTimezone() async {
    if (_cachedDeviceTimezone != null && _cachedDeviceTimezone!.isNotEmpty) {
      return _cachedDeviceTimezone!;
    }
    try {
      final tzInfo = await FlutterTimezone.getLocalTimezone().timeout(
        const Duration(seconds: 1),
      );
      var tzId = tzInfo.identifier.trim();
      if (tzId == 'Asia/Calcutta') tzId = 'Asia/Kolkata';
      if (tzId.isNotEmpty) {
        _cachedDeviceTimezone = tzId;
        return tzId;
      }
    } catch (_) {
      // Headless unit test environments without platform channel fallback safely
    }
    return 'Asia/Kolkata';
  }

  /// Synchronous best-effort cached device timezone getter (falls back to Asia/Kolkata).
  static String get cachedDeviceTimezone => _cachedDeviceTimezone ?? 'Asia/Kolkata';

  static String _inferAudioContentType(String filename) {
    final ext = filename.contains('.') ? filename.split('.').last.toLowerCase() : 'm4a';
    switch (ext) {
      case 'm4a':
      case 'mp4':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'mp3':
      case 'mpeg':
      case 'mpga':
        return 'audio/mpeg';
      case 'webm':
        return 'audio/webm';
      case 'ogg':
      case 'oga':
        return 'audio/ogg';
      case 'flac':
        return 'audio/flac';
      default:
        return 'application/octet-stream';
    }
  }

  Future<String?> _attemptTokenRefresh() async {
    try {
      if (tokenRefresher != null) {
        return await tokenRefresher!();
      }
      return await ApiAuthService.shared.refreshSession();
    } catch (_) {
      return null;
    }
  }

  void _notifySessionExpired() {
    try {
      onSessionExpired?.call();
    } catch (_) {}
  }

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
    final effectiveTimezone = (timezone != null && timezone.trim().isNotEmpty)
        ? timezone.trim()
        : await resolveDeviceTimezone();

    final payload = {
      'prompt': cleanPrompt,
      'current_date': currentDate,
      'current_time': currentTime,
      'timezone': effectiveTimezone,
    };

    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    final uri = Uri.parse('$effectiveBaseUrl/agent/reminder');

    try {
      var response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: timeout,
        headers: headers.isEmpty ? null : headers,
        clientFactory: clientFactory,
      );

      if (response.statusCode == 401 && headers.isNotEmpty) {
        final refreshedToken = await _attemptTokenRefresh();
        if (refreshedToken != null && refreshedToken.isNotEmpty) {
          final retryHeaders = Map<String, String>.from(headers);
          retryHeaders['Authorization'] = 'Bearer $refreshedToken';
          response = await effectiveTransport.postJson(
            uri: uri,
            payload: payload,
            timeout: timeout,
            headers: retryHeaders,
            clientFactory: clientFactory,
          );
        }
        if (response.statusCode == 401) {
          _notifySessionExpired();
          throw const AiParsingException(
            'Authentication session expired. Please sign in again.',
          );
        }
      }

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

      return _parseSingleDraftResponse(
        response.body,
        cleanPrompt: cleanPrompt,
        now: now,
      );
    } on AgentNetworkException catch (e) {
      if (fallbackService != null) {
        debugPrint(
          'StrandsAgentApiService: Connection to $effectiveBaseUrl failed ($e). Delegating to fallback service.',
        );
        return fallbackService!.parsePrompt(prompt, referenceTime: referenceTime);
      }
      throw const AiParsingException(
        'Could not connect to AI backend. Please verify your internet connection and ensure the service is reachable.',
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

  AiReminderDraft _parseSingleDraftResponse(
    String responseBody, {
    required String cleanPrompt,
    required DateTime now,
  }) {
    final Map<String, dynamic> data =
        jsonDecode(responseBody) as Map<String, dynamic>;
    final success = data['success'] as bool? ?? false;

    if (!success) {
      final clarification = data['clarification_needed'] as String?;
      final error = clarification ??
          data['error'] as String? ??
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

    final reasoning = draftMap['reasoning'] as String? ??
        proposal['message'] as String? ??
        data['message'] as String?;
    final rawPrompt = proposal['raw_prompt'] as String? ?? cleanPrompt;

    return mapJsonToDraft(
      draftMap,
      rawPrompt: rawPrompt,
      now: now,
      reasoning: reasoning,
    );
  }

  List<AiReminderDraft> _parseMultiDraftResponse(
    String responseBody, {
    required String cleanPrompt,
    required DateTime now,
  }) {
    final Map<String, dynamic> data =
        jsonDecode(responseBody) as Map<String, dynamic>;
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
    if (drafts.isEmpty) {
      throw const AiParsingException('No reminder proposals returned by AI.');
    }
    return drafts;
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
    final effectiveTimezone = (timezone != null && timezone.trim().isNotEmpty)
        ? timezone.trim()
        : await resolveDeviceTimezone();

    final payload = {
      'prompt': cleanPrompt,
      'current_date': currentDate,
      'current_time': currentTime,
      'timezone': effectiveTimezone,
    };

    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    final uri = Uri.parse('$effectiveBaseUrl/agent/reminders/plan');

    try {
      var response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: timeout,
        headers: headers,
        clientFactory: clientFactory,
      );

      if (response.statusCode == 401) {
        final refreshedToken = await _attemptTokenRefresh();
        if (refreshedToken != null && refreshedToken.isNotEmpty) {
          final retryHeaders = Map<String, String>.from(headers);
          retryHeaders['Authorization'] = 'Bearer $refreshedToken';
          response = await effectiveTransport.postJson(
            uri: uri,
            payload: payload,
            timeout: timeout,
            headers: retryHeaders,
            clientFactory: clientFactory,
          );
        }
        if (response.statusCode == 401) {
          _notifySessionExpired();
          throw const AiParsingException(
            'Authentication session expired. Please sign in again.',
          );
        }
      }

      if (response.statusCode == 200) {
        return _parseMultiDraftResponse(
          response.body,
          cleanPrompt: cleanPrompt,
          now: now,
        );
      }

      // If the multi-reminder plan route is not yet available (HTTP 404),
      // gracefully fallback to the single-reminder endpoint POST /agent/reminder.
      if (response.statusCode == 404) {
        try {
          final singleDraft = await parsePrompt(
            prompt,
            referenceTime: referenceTime,
            timezone: effectiveTimezone,
            authToken: authToken,
          );
          return [singleDraft];
        } on AiParsingException catch (e) {
          // If /agent/reminder also returns 404 or unreachable, allow local fallback if configured;
          // otherwise surface AI clarifications/auth errors cleanly.
          final msg = e.message.toLowerCase();
          final bothUnavailable = msg.contains('404') || msg.contains('could not connect');
          if (bothUnavailable && fallbackService != null) {
            return await fallbackService!.parseMultiPrompt(
              prompt,
              referenceTime: referenceTime,
              timezone: effectiveTimezone,
              authToken: authToken,
            );
          }
          rethrow;
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
    } on AgentNetworkException catch (e) {
      if (fallbackService != null) {
        debugPrint(
          'StrandsAgentApiService: Connection failed ($e). Delegating to fallback service.',
        );
        return fallbackService!.parseMultiPrompt(
          prompt,
          referenceTime: referenceTime,
          timezone: effectiveTimezone,
          authToken: authToken,
        );
      }
      throw const AiParsingException(
        'Could not connect to AI backend. Please verify your internet connection and ensure the agent service is running.',
      );
    } catch (e) {
      if (e is AiParsingException) {
        rethrow;
      }
      if (fallbackService != null) {
        return fallbackService!.parseMultiPrompt(
          prompt,
          referenceTime: referenceTime,
          timezone: effectiveTimezone,
          authToken: authToken,
        );
      }
      throw AiParsingException('Error communicating with AI Agent: $e');
    }
  }

  String _parseTranscribeResponseBody(String responseBody) {
    final Map<String, dynamic> data =
        jsonDecode(responseBody) as Map<String, dynamic>;
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
    const maxBytes = 25 * 1024 * 1024;
    if (audioBytes.length > maxBytes) {
      throw const AiParsingException(
        'Audio recording exceeds the 25 MB upload limit. Please record a shorter message.',
      );
    }

    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    final uri = Uri.parse('$effectiveBaseUrl/agent/voice/transcribe');

    var useMultipart = false;
    try {
      useMultipart = effectiveTransport.supportsMultipart;
    } on UnimplementedError {
      useMultipart = false;
    }

    Future<AgentHttpResponse> sendUpload(Map<String, String> reqHeaders) {
      if (useMultipart) {
        return effectiveTransport.postMultipart(
          uri: uri,
          fieldName: 'file',
          fileBytes: audioBytes,
          filename: filename,
          contentType: _inferAudioContentType(filename),
          fields: language != null ? {'language': language} : null,
          headers: reqHeaders,
          timeout: timeout,
          clientFactory: clientFactory,
        );
      }
      final audioBase64 = base64Encode(audioBytes);
      final payload = {
        'audio_base64': audioBase64,
        'filename': filename,
        if (language != null) 'language': language,
      };
      return effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: timeout,
        headers: reqHeaders,
        clientFactory: clientFactory,
      );
    }

    try {
      var response = await sendUpload(headers);

      if (response.statusCode == 401) {
        final refreshedToken = await _attemptTokenRefresh();
        if (refreshedToken != null && refreshedToken.isNotEmpty) {
          final retryHeaders = Map<String, String>.from(headers);
          retryHeaders['Authorization'] = 'Bearer $refreshedToken';
          response = await sendUpload(retryHeaders);
        }
        if (response.statusCode == 401) {
          _notifySessionExpired();
          throw const AiParsingException(
            'Authentication session expired. Please sign in again.',
          );
        }
      }

      if (response.statusCode != 200) {
        if (response.statusCode == 404) {
          throw const AiParsingException(
            'Voice transcription service is temporarily unavailable on the server. Please try again shortly or type your reminder.',
          );
        }
        if (response.statusCode == 413) {
          throw const AiParsingException(
            'Audio recording is too large for transcription (max 25 MB).',
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

      return _parseTranscribeResponseBody(response.body);
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
