// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'agent_http_transport.dart';

AgentHttpTransport getAgentHttpTransport() => HtmlAgentHttpTransport();

class HtmlAgentHttpTransport implements AgentHttpTransport {
  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    final completer = Completer<AgentHttpResponse>();
    final request = html.HttpRequest();

    request.open('POST', uri.toString(), async: true);
    request.setRequestHeader('Content-Type', 'application/json');
    if (headers != null) {
      headers.forEach((key, value) {
        request.setRequestHeader(key, value);
      });
    }
    request.timeout = timeout.inMilliseconds;

    request.onLoad.listen((_) {
      if (!completer.isCompleted) {
        completer.complete(
          AgentHttpResponse(
            statusCode: request.status ?? 0,
            body: request.responseText ?? '',
          ),
        );
      }
    });

    request.onError.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          AgentNetworkException('Network error connecting to $uri'),
        );
      }
    });

    request.onTimeout.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          AgentNetworkException('Request to $uri timed out after $timeout'),
        );
      }
    });

    try {
      request.send(jsonEncode(payload));
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(
          AgentNetworkException('Failed to send request: $e', e),
        );
      }
    }

    return completer.future;
  }
}
