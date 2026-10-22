import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/ai_reminder_draft.dart';
import 'agent_http_transport.dart';
import 'ai_agent_api_service.dart';

/// Result of a multi-reminder batch confirmation request.
class BatchConfirmResult {
  final bool success;
  final String status;
  final int totalRequested;
  final int totalCreated;
  final List<String> createdReminderIds;
  final List<Map<String, dynamic>> reminders;
  final List<Map<String, dynamic>> schedulingStatus;
  final List<Map<String, dynamic>> failures;
  final String message;
  final String? errorMessage;

  const BatchConfirmResult({
    required this.success,
    this.status = 'CONFIRMED',
    this.totalRequested = 0,
    this.totalCreated = 0,
    this.createdReminderIds = const [],
    this.reminders = const [],
    this.schedulingStatus = const [],
    this.failures = const [],
    this.message = '',
    this.errorMessage,
  });

  factory BatchConfirmResult.fromJson(Map<String, dynamic> json) {
    return BatchConfirmResult(
      success: json['success'] as bool? ?? false,
      status: json['status'] as String? ?? 'CONFIRMED',
      totalRequested: json['total_requested'] as int? ?? 0,
      totalCreated: json['total_created'] as int? ?? 0,
      createdReminderIds: (json['created_reminder_ids'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      reminders: (json['reminders'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
      schedulingStatus: (json['scheduling_status'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
      failures: (json['failures'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
      message: json['message'] as String? ?? '',
      errorMessage: json['error'] as String?,
    );
  }

  factory BatchConfirmResult.failure(String errorMessage) {
    return BatchConfirmResult(
      success: false,
      status: 'FAILED',
      errorMessage: errorMessage,
      message: errorMessage,
    );
  }
}

/// Contract for dispatching human-confirmed reminder actions for cloud persistence
/// (Supabase PostgreSQL) and external channel routing (e.g. WhatsApp).
/// Ensures no third-party credentials (like Twilio tokens or database keys) are ever stored on or exposed by the client.
abstract class ActionDispatchService {
  Future<bool> dispatchConfirmedAction({
    required AiReminderDraft draft,
    String? userPhoneNumber,
    String? userId,
    String? authToken,
    String? reminderId,
  });

  Future<BatchConfirmResult> dispatchBatchConfirmedActions({
    required List<AiReminderDraft> drafts,
    String? idempotencyKey,
    String? authToken,
  }) {
    return Future.value(BatchConfirmResult(
      success: true,
      status: 'CONFIRMED',
      totalRequested: drafts.length,
      totalCreated: drafts.length,
      createdReminderIds: drafts.map((d) => d.id ?? '').where((id) => id.isNotEmpty).toList(),
      message: 'Batch saved locally.',
    ));
  }
}

/// Dispatches confirmed actions to the backend Action Router endpoint `POST /action/confirm`
/// for persistent cloud storage and optional external channel routing.
class BackendActionDispatchService implements ActionDispatchService {
  final String? baseUrl;
  final AgentHttpTransport? transport;

  const BackendActionDispatchService({
    this.baseUrl,
    this.transport,
  });

  String get effectiveBaseUrl =>
      baseUrl ?? StrandsAgentApiService.defaultBaseUrl;

  AgentHttpTransport get effectiveTransport =>
      transport ?? createAgentHttpTransport();

  @override
  Future<bool> dispatchConfirmedAction({
    required AiReminderDraft draft,
    String? userPhoneNumber,
    String? userId,
    String? authToken,
    String? reminderId,
  }) async {
    final payload = {
      'action': 'confirm_reminder',
      'draft': draft.toJson(),
      'user_phone_number': userPhoneNumber,
      if (userId != null) 'user_id': userId,
      if (reminderId != null) 'reminder_id': reminderId,
    };

    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    final uri = Uri.parse('$effectiveBaseUrl/action/confirm');

    try {
      final response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: const Duration(seconds: 15),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['success'] as bool? ?? false;
      }
      return false;
    } catch (e) {
      debugPrint('ActionDispatchService: Cloud confirmation / dispatch note: $e');
      // Do not block local reminder scheduling if backend dispatch is offline
      return false;
    }
  }

  @override
  Future<BatchConfirmResult> dispatchBatchConfirmedActions({
    required List<AiReminderDraft> drafts,
    String? idempotencyKey,
    String? authToken,
  }) async {
    final payload = {
      'reminders': drafts.map((d) => d.toJson()).toList(),
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
    };

    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }
    if (idempotencyKey != null) {
      headers['Idempotency-Key'] = idempotencyKey;
    }

    final uri = Uri.parse('$effectiveBaseUrl/agent/reminders/batch');

    try {
      final response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: const Duration(seconds: 30),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return BatchConfirmResult.fromJson(data);
      } else {
        String? detail;
        try {
          final errJson = jsonDecode(response.body) as Map<String, dynamic>;
          detail = errJson['detail'] as String? ?? errJson['message'] as String?;
        } catch (_) {}
        return BatchConfirmResult.failure(
          detail ?? 'Server returned status ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('ActionDispatchService batch confirmation error: $e');
      return BatchConfirmResult.failure(
        'Could not reach server for cloud confirmation ($e). Reminders are saved locally.',
      );
    }
  }
}
