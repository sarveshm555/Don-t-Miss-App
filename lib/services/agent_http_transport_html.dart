// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'agent_http_transport.dart';

AgentHttpTransport getAgentHttpTransport() => HtmlAgentHttpTransport();

class HtmlAgentHttpTransport implements AgentHttpTransport {
  @override
  bool get supportsMultipart => true;

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
    request.setRequestHeader('Accept', 'application/json');
    if (payload != null) {
      request.setRequestHeader('Content-Type', 'application/json; charset=utf-8');
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
  Future<AgentHttpResponse> postMultipart({
    required Uri uri,
    required String fieldName,
    required List<int> fileBytes,
    required String filename,
    String contentType = 'application/octet-stream',
    Map<String, String>? fields,
    Map<String, String>? headers,
    required Duration timeout,
    dynamic clientFactory,
  }) {
    final completer = Completer<AgentHttpResponse>();
    final request = html.HttpRequest();
    request.open('POST', uri.toString(), async: true);
    request.setRequestHeader('Accept', 'application/json');
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
          AgentNetworkException('Network error uploading audio to $uri'),
        );
      }
    });

    request.onTimeout.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          AgentNetworkException('Upload to $uri timed out after $timeout'),
        );
      }
    });

    try {
      final formData = html.FormData();
      if (fields != null) {
        fields.forEach((key, value) => formData.append(key, value));
      }
      final blob = html.Blob([Uint8List.fromList(fileBytes)], contentType);
      formData.appendBlob(fieldName, blob, filename);
      request.send(formData);
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(
          AgentNetworkException('Failed to send multipart request: $e', e),
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
