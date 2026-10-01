import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'agent_http_transport.dart';

AgentHttpTransport getAgentHttpTransport() => IoAgentHttpTransport();

class IoAgentHttpTransport implements AgentHttpTransport {
  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    HttpClient? client;
    try {
      if (clientFactory != null && clientFactory is HttpClient Function()) {
        client = clientFactory();
      } else {
        client = HttpClient();
      }
      client.connectionTimeout = const Duration(seconds: 15);

      final request = await client.postUrl(uri);
      request.headers.set('content-type', 'application/json');
      if (headers != null) {
        headers.forEach((key, value) {
          request.headers.set(key, value);
        });
      }
      request.write(jsonEncode(payload));

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
}
