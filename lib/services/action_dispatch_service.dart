import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/ai_reminder_draft.dart';
import 'agent_http_transport.dart';
import 'ai_agent_api_service.dart';

/// Contract for dispatching human-confirmed reminder actions for cloud persistence
/// (Supabase PostgreSQL) and external channel routing (e.g. WhatsApp).
/// Ensures no third-party credentials (like Twilio tokens or database keys) are ever stored on or exposed by the client.
abstract class ActionDispatchService {
  Future<bool> dispatchConfirmedAction({
    required AiReminderDraft draft,
    String? userPhoneNumber,
  });
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
  }) async {
    final payload = {
      'action': 'confirm_reminder',
      'draft': draft.toJson(),
      'user_phone_number': userPhoneNumber,
    };

    final uri = Uri.parse('$effectiveBaseUrl/action/confirm');

    try {
      final response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: const Duration(seconds: 15),
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
}
