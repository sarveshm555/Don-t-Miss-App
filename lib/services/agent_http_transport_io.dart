import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'agent_http_transport.dart';

AgentHttpTransport getAgentHttpTransport() => IoAgentHttpTransport();

class IoAgentHttpTransport implements AgentHttpTransport {
  @override
  bool get supportsMultipart => true;

  HttpClient _createClient(dynamic clientFactory, Duration timeout) {
    HttpClient client;
    if (clientFactory != null && clientFactory is HttpClient Function()) {
      client = clientFactory();
    } else {
      client = HttpClient();
    }
    // Allow sufficient handshake time for Render Free cold-starts (30-60s)
    // while honoring shorter custom timeouts when supplied.
    client.connectionTimeout = timeout < const Duration(seconds: 60)
        ? timeout
        : const Duration(seconds: 60);
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
      client = _createClient(clientFactory, timeout);
      Future<AgentHttpResponse> execute() async {
        final HttpClientRequest request;
        switch (method.toUpperCase()) {
          case 'GET':
            request = await client!.getUrl(uri);
            break;
          case 'POST':
            request = await client!.postUrl(uri);
            break;
          case 'PUT':
            request = await client!.putUrl(uri);
            break;
          case 'DELETE':
            request = await client!.deleteUrl(uri);
            break;
          default:
            request = await client!.openUrl(method, uri);
        }

        request.headers.set('accept', 'application/json');
        List<int>? bodyBytes;
        if (payload != null) {
          bodyBytes = utf8.encode(jsonEncode(payload));
          request.headers.set('content-type', 'application/json; charset=utf-8');
          request.contentLength = bodyBytes.length;
        }
        if (headers != null) {
          headers.forEach((key, value) {
            request.headers.set(key, value);
          });
        }
        if (bodyBytes != null) {
          request.add(bodyBytes);
        }

        final response = await request.close();
        final responseBody = await response.transform(utf8.decoder).join();

        return AgentHttpResponse(
          statusCode: response.statusCode,
          body: responseBody,
        );
      }

      return await execute().timeout(timeout);
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
  }) async {
    HttpClient? client;
    try {
      client = _createClient(clientFactory, timeout);
      Future<AgentHttpResponse> execute() async {
        final boundary =
            '----DontMissBoundary${DateTime.now().microsecondsSinceEpoch}';
        final safeFilename = filename.replaceAll('"', '_');
        final builder = BytesBuilder(copy: false);

        if (fields != null) {
          fields.forEach((key, value) {
            builder.add(utf8.encode(
              '--$boundary\r\n'
              'Content-Disposition: form-data; name="$key"\r\n\r\n'
              '$value\r\n',
            ));
          });
        }

        builder.add(utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="$fieldName"; filename="$safeFilename"\r\n'
          'Content-Type: $contentType\r\n\r\n',
        ));
        builder.add(fileBytes);
        builder.add(utf8.encode('\r\n--$boundary--\r\n'));

        final bodyBytes = builder.takeBytes();
        final request = await client!.postUrl(uri);
        request.headers.set('accept', 'application/json');
        request.headers.set(
          'content-type',
          'multipart/form-data; boundary=$boundary',
        );
        request.contentLength = bodyBytes.length;

        if (headers != null) {
          headers.forEach((key, value) {
            request.headers.set(key, value);
          });
        }

        request.add(bodyBytes);
        final response = await request.close();
        final responseBody = await response.transform(utf8.decoder).join();

        return AgentHttpResponse(
          statusCode: response.statusCode,
          body: responseBody,
        );
      }

      return await execute().timeout(timeout);
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
