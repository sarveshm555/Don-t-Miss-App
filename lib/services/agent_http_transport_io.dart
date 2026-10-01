import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'agent_http_transport.dart';

AgentHttpTransport getAgentHttpTransport() => IoAgentHttpTransport();

class IoAgentHttpTransport implements AgentHttpTransport {
  HttpClient _createClient(dynamic clientFactory) {
    HttpClient client;
    if (clientFactory != null && clientFactory is HttpClient Function()) {
      client = clientFactory();
    } else {
      client = HttpClient();
    }
    client.connectionTimeout = const Duration(seconds: 15);
    return client;
  }

  Future<AgentHttpResponse> _send(
    String method,
    Uri uri, {
    Map<String, dynamic>? payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    HttpClient? client;
    try {
      client = _createClient(clientFactory);
      final HttpClientRequest request;
      switch (method.toUpperCase()) {
        case 'GET':
          request = await client.getUrl(uri);
          break;
        case 'POST':
          request = await client.postUrl(uri);
          break;
        case 'PUT':
          request = await client.putUrl(uri);
          break;
        case 'DELETE':
          request = await client.deleteUrl(uri);
          break;
        default:
          request = await client.openUrl(method, uri);
      }

      if (payload != null) {
        request.headers.set('content-type', 'application/json');
      }
      if (headers != null) {
        headers.forEach((key, value) {
          request.headers.set(key, value);
        });
      }
      if (payload != null) {
        request.write(jsonEncode(payload));
      }

      final response = await request.close().timeout(timeout);
      final responseBody = await response.transform(utf8.decoder).join();

      return AgentHttpResponse(
        statusCode: response.statusCode,
        body: responseBody,
      );
    } on SocketException catch (e) {
      throw AgentNetworkException('Connection failed: $e', e);
    } on HttpException catch (e) {
      throw AgentNetworkException('HTTP error: $e', e);
    } on IOException catch (e) {
      throw AgentNetworkException('IO error: $e', e);
    } on TimeoutException catch (e) {
      throw AgentNetworkException('Request timed out: $e', e);
    } finally {
      client?.close();
    }
  }

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return _send(
      'POST',
      uri,
      payload: payload,
      timeout: timeout,
      headers: headers,
      clientFactory: clientFactory,
    );
  }

  @override
  Future<AgentHttpResponse> get({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return _send(
      'GET',
      uri,
      timeout: timeout,
      headers: headers,
      clientFactory: clientFactory,
    );
  }

  @override
  Future<AgentHttpResponse> putJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return _send(
      'PUT',
      uri,
      payload: payload,
      timeout: timeout,
      headers: headers,
      clientFactory: clientFactory,
    );
  }

  @override
  Future<AgentHttpResponse> delete({
    required Uri uri,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) {
    return _send(
      'DELETE',
      uri,
      timeout: timeout,
      headers: headers,
      clientFactory: clientFactory,
    );
  }
}
