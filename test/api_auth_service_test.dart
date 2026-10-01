import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dont_miss/services/agent_http_transport.dart';
import 'package:dont_miss/services/auth_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ApiAuthService Unit Tests', () {
    test('signUp sends correct payload, receives token, and persists session', () async {
      final mockTransport = _MockAuthTransport(handler: (uri, payload, headers) {
        expect(uri.path, '/auth/signup');
        expect(payload['name'], 'Alice Smith');
        expect(payload['phone_number'], '+15551234567');
        expect(payload['password'], 'Password123!');

        return AgentHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'user_id': 'usr-alice-01',
            'name': 'Alice Smith',
            'phone_number': '+15551234567',
            'is_verified': false,
            'token': 'jwt.token.alice',
            'message': 'Account created successfully.',
          }),
        );
      });

      final authService = ApiAuthService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final user = await authService.signUp(
        name: 'Alice Smith',
        phoneNumber: '+15551234567',
        password: 'Password123!',
      );

      expect(user.id, 'usr-alice-01');
      expect(user.name, 'Alice Smith');
      expect(user.phoneNumber, '+15551234567');
      expect(user.isVerified, isFalse);
      expect(authService.currentToken, 'jwt.token.alice');

      // Verify persisted session in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dont_miss_auth_token_v1'), 'jwt.token.alice');
      expect(prefs.getString('dont_miss_auth_user_v1'), contains('usr-alice-01'));
    });

    test('signIn sends credentials, updates token, and returns UserProfile', () async {
      final mockTransport = _MockAuthTransport(handler: (uri, payload, headers) {
        expect(uri.path, '/auth/signin');
        expect(payload['phone_number'], '+15559876543');
        expect(payload['password'], 'SecretPass!');

        return AgentHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'user_id': 'usr-bob-02',
            'name': 'Bob Jones',
            'phone_number': '+15559876543',
            'is_verified': true,
            'token': 'jwt.token.bob',
            'message': 'Signed in successfully.',
          }),
        );
      });

      final authService = ApiAuthService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final user = await authService.signIn(
        phoneNumber: '+15559876543',
        password: 'SecretPass!',
      );

      expect(user.id, 'usr-bob-02');
      expect(user.name, 'Bob Jones');
      expect(user.isVerified, isTrue);
      expect(authService.currentToken, 'jwt.token.bob');
      expect(await authService.isAuthenticated(), isTrue);
    });

    test('session restoration restores user and token from storage on startup', () async {
      final initialUserJson = jsonEncode({
        'id': 'usr-persisted-99',
        'name': 'Persisted User',
        'phoneNumber': '+15554443322',
        'isVerified': true,
        'createdAt': '2026-10-01T00:00:00.000',
      });

      SharedPreferences.setMockInitialValues({
        'dont_miss_auth_user_v1': initialUserJson,
        'dont_miss_auth_token_v1': 'jwt.persisted.token',
      });

      final authService = ApiAuthService(baseUrl: 'http://localhost:8000');

      final user = await authService.getCurrentUser();
      expect(user, isNotNull);
      expect(user!.id, 'usr-persisted-99');
      expect(user.name, 'Persisted User');
      expect(user.isVerified, isTrue);
      expect(authService.currentToken, 'jwt.persisted.token');
      expect(await authService.isAuthenticated(), isTrue);
    });

    test('signOut clears persisted session and resets state', () async {
      SharedPreferences.setMockInitialValues({
        'dont_miss_auth_user_v1': '{"id": "usr-1", "name": "A", "phoneNumber": "1", "isVerified": true, "createdAt": "2026-10-01T00:00:00.000"}',
        'dont_miss_auth_token_v1': 'valid.token',
      });

      final mockTransport = _MockAuthTransport(handler: (uri, payload, headers) {
        expect(uri.path, '/auth/signout');
        expect(headers?['Authorization'], 'Bearer valid.token');
        return const AgentHttpResponse(
          statusCode: 200,
          body: '{"success": true, "message": "Signed out successfully."}',
        );
      });

      final authService = ApiAuthService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      // Pre-load user
      await authService.getCurrentUser();
      expect(await authService.isAuthenticated(), isTrue);

      // Perform sign out
      await authService.signOut();

      expect(authService.currentToken, isNull);
      expect(await authService.getCurrentUser(), isNull);
      expect(await authService.isAuthenticated(), isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dont_miss_auth_user_v1'), isNull);
      expect(prefs.getString('dont_miss_auth_token_v1'), isNull);
    });

    test('authentication failure handling exposes AuthException cleanly', () async {
      final mockTransport = _MockAuthTransport(handler: (uri, payload, headers) {
        return AgentHttpResponse(
          statusCode: 401,
          body: jsonEncode({
            'success': false,
            'message': 'Invalid phone number or password.',
          }),
        );
      });

      final authService = ApiAuthService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      await expectLater(
        authService.signIn(
          phoneNumber: '+15550000000',
          password: 'WrongPassword',
        ),
        throwsA(
          predicate((e) =>
              e is AuthException &&
              e.message == 'Invalid phone number or password.'),
        ),
      );
    });

    test('verifyPhone succeeds and transitions isVerified flag to true', () async {
      SharedPreferences.setMockInitialValues({
        'dont_miss_auth_user_v1': '{"id": "usr-verify-1", "name": "Eva", "phoneNumber": "+15551112233", "isVerified": false, "createdAt": "2026-10-01T00:00:00.000"}',
        'dont_miss_auth_token_v1': 'token.pre.verify',
      });

      final mockTransport = _MockAuthTransport(handler: (uri, payload, headers) {
        expect(uri.path, '/auth/verify-phone');
        expect(payload['phone_number'], '+15551112233');
        expect(payload['verification_code'], '123456');

        return AgentHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'user_id': 'usr-verify-1',
            'name': 'Eva',
            'phone_number': '+15551112233',
            'is_verified': true,
            'token': 'token.post.verify',
            'message': 'Phone number verified successfully.',
          }),
        );
      });

      final authService = ApiAuthService(
        baseUrl: 'http://localhost:8000',
        transport: mockTransport,
      );

      final success = await authService.verifyPhone(
        phoneNumber: '+15551112233',
        code: '123456',
      );

      expect(success, isTrue);
      final user = await authService.getCurrentUser();
      expect(user!.isVerified, isTrue);
      expect(authService.currentToken, 'token.post.verify');
    });
  });
}

class _MockAuthTransport extends AgentHttpTransport {
  final AgentHttpResponse Function(
    Uri uri,
    Map<String, dynamic> payload,
    Map<String, String>? headers,
  ) handler;

  _MockAuthTransport({required this.handler});

  @override
  Future<AgentHttpResponse> postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Duration timeout,
    Map<String, String>? headers,
    dynamic clientFactory,
  }) async {
    return handler(uri, payload, headers);
  }
}
