// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'agent_http_transport.dart';

AgentHttpTransport getAgentHttpTransport() => HtmlAgentHttpTransport();

class HtmlAgentHttpTransport implements AgentHttpTransport {
  Future<AgentHttpResponse> _send(
    String method,
    Uri uri, {
    Map<String, dynamic>? payload,
    required Duration timeout,
    Map<String, String>? headers,
  }) {
    final completer = Completer<AgentHttpResponse>();
    final request = html.HttpRequest();

    request.open(method, uri.toString(), async: true);
    if (payload != null) {
      request.setRequestHeader('Content-Type', 'application/json');
    }
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
      if (payload != null) {
        request.send(jsonEncode(payload));
      } else {
        request.send();
      }
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(
          AgentNetworkException('Failed to send request: $e', e),
        );
      }
    }

    return completer.future;
  }

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return _send('POST', uri, payload: payload, timeout: timeout, headers: headers);
  }

  @override
  Future<AgentHttpResponse> get({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return _send('GET', uri, timeout: timeout, headers: headers);
  }

  @override
  Future<AgentHttpResponse> putJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return _send('PUT', uri, payload: payload, timeout: timeout, headers: headers);
  }

  @override
  Future<AgentHttpResponse> delete({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return _send('DELETE', uri, timeout: timeout, headers: headers);
  }
}
