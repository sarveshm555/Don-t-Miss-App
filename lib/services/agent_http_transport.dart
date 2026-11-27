import 'agent_http_transport_stub.dart'
    if (dart.library.io) 'agent_http_transport_io.dart'
    if (dart.library.html) 'agent_http_transport_html.dart';

abstract class AgentHttpTransport {
  bool get supportsMultipart => false;

  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  });

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
    throw UnimplementedError('postMultipart not implemented');
  }

  Future<AgentHttpResponse> get({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    throw UnimplementedError('GET not implemented');
  }

  Future<AgentHttpResponse> putJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    throw UnimplementedError('PUT not implemented');
  }

  Future<AgentHttpResponse> delete({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    throw UnimplementedError('DELETE not implemented');
  }
}

AgentHttpTransport createAgentHttpTransport() => getAgentHttpTransport();

class AgentHttpResponse {
  final int statusCode;
  final String body;

  const AgentHttpResponse({
    required this.statusCode,
    required this.body,
  });
}

class AgentNetworkException implements Exception {
  final String message;
  final dynamic originalError;

  const AgentNetworkException(this.message, [this.originalError]);

  @override
  String toString() => message;
}
