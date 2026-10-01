import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_profile.dart';
import 'agent_http_transport.dart';
import 'ai_agent_api_service.dart';

/// Exception thrown on authentication errors.
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

/// Contract defining authentication operations.
/// Abstracted so future backend JWT / AWS Cognito / Firebase Auth
/// can be seamlessly plugged in without modifying UI state.
abstract class AuthService {
  Future<UserProfile?> getCurrentUser();
  Future<bool> isAuthenticated();
  Future<UserProfile> signUp({
    required String name,
    required String phoneNumber,
    required String password,
  });
  Future<UserProfile> signIn({
    required String phoneNumber,
    required String password,
  });
  Future<bool> verifyPhone({
    required String phoneNumber,
    required String code,
  });
  Future<void> signOut();
}

/// Production FastAPI + PostgreSQL JWT backend implementation of [AuthService].
class ApiAuthService implements AuthService {
  static const String _userKey = 'dont_miss_auth_user_v1';
  static const String _tokenKey = 'dont_miss_auth_token_v1';

  final String? baseUrl;
  final AgentHttpTransport? transport;

  String? _cachedToken;
  UserProfile? _cachedUser;

  ApiAuthService({
    this.baseUrl,
    this.transport,
  });

  String get effectiveBaseUrl =>
      baseUrl ?? StrandsAgentApiService.defaultBaseUrl;

  AgentHttpTransport get effectiveTransport =>
      transport ?? createAgentHttpTransport();

  String? get currentToken => _cachedToken;

  @override
  Future<UserProfile?> getCurrentUser() async {
    if (_cachedUser != null) return _cachedUser;

    final prefs = await SharedPreferences.getInstance();
    final rawUser = prefs.getString(_userKey);
    _cachedToken = prefs.getString(_tokenKey);

    if (rawUser == null || rawUser.isEmpty) return null;

    try {
      final map = jsonDecode(rawUser) as Map<String, dynamic>;
      _cachedUser = UserProfile.fromJson(map);
      return _cachedUser;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> isAuthenticated() async {
    final user = await getCurrentUser();
    return user != null && _cachedToken != null && _cachedToken!.isNotEmpty;
  }

  @override
  Future<UserProfile> signUp({
    required String name,
    required String phoneNumber,
    required String password,
  }) async {
    final uri = Uri.parse('$effectiveBaseUrl/auth/signup');
    final payload = {
      'name': name.trim(),
      'phone_number': phoneNumber.trim(),
      'password': password,
    };

    final response = await effectiveTransport.postJson(
      uri: uri,
      payload: payload,
      timeout: const Duration(seconds: 15),
    );

    final data = _parseResponse(response);
    if (response.statusCode == 200 && (data['success'] as bool? ?? false)) {
      final user = UserProfile(
        id: data['user_id'] as String? ?? '',
        name: data['name'] as String? ?? name.trim(),
        phoneNumber: data['phone_number'] as String? ?? phoneNumber.trim(),
        isVerified: data['is_verified'] as bool? ?? false,
        createdAt: DateTime.now(),
      );
      final token = data['token'] as String?;
      await _persistSession(user, token);
      return user;
    }

    final message = data['message'] as String? ??
        data['detail'] as String? ??
        'Sign up failed with status code ${response.statusCode}';
    throw AuthException(message);
  }

  @override
  Future<UserProfile> signIn({
    required String phoneNumber,
    required String password,
  }) async {
    final uri = Uri.parse('$effectiveBaseUrl/auth/signin');
    final payload = {
      'phone_number': phoneNumber.trim(),
      'password': password,
    };

    final response = await effectiveTransport.postJson(
      uri: uri,
      payload: payload,
      timeout: const Duration(seconds: 15),
    );

    final data = _parseResponse(response);
    if (response.statusCode == 200 && (data['success'] as bool? ?? false)) {
      final user = UserProfile(
        id: data['user_id'] as String? ?? '',
        name: data['name'] as String? ?? 'User',
        phoneNumber: data['phone_number'] as String? ?? phoneNumber.trim(),
        isVerified: data['is_verified'] as bool? ?? false,
        createdAt: DateTime.now(),
      );
      final token = data['token'] as String?;
      await _persistSession(user, token);
      return user;
    }

    final message = data['message'] as String? ??
        data['detail'] as String? ??
        'Sign in failed with status code ${response.statusCode}';
    throw AuthException(message);
  }

  @override
  Future<bool> verifyPhone({
    required String phoneNumber,
    required String code,
  }) async {
    final uri = Uri.parse('$effectiveBaseUrl/auth/verify-phone');
    final payload = {
      'phone_number': phoneNumber.trim(),
      'verification_code': code.trim(),
    };

    final response = await effectiveTransport.postJson(
      uri: uri,
      payload: payload,
      timeout: const Duration(seconds: 15),
    );

    final data = _parseResponse(response);
    if (response.statusCode == 200 && (data['success'] as bool? ?? false)) {
      final current = await getCurrentUser();
      final updated = (current ??
              UserProfile(
                id: data['user_id'] as String? ?? '',
                name: data['name'] as String? ?? 'User',
                phoneNumber:
                    data['phone_number'] as String? ?? phoneNumber.trim(),
                isVerified: true,
                createdAt: DateTime.now(),
              ))
          .copyWith(isVerified: true);

      final token = data['token'] as String? ?? _cachedToken;
      await _persistSession(updated, token);
      return true;
    }

    final message = data['message'] as String? ??
        data['detail'] as String? ??
        'Verification failed with status code ${response.statusCode}';
    throw AuthException(message);
  }

  @override
  Future<void> signOut() async {
    try {
      final uri = Uri.parse('$effectiveBaseUrl/auth/signout');
      final headers = <String, String>{};
      if (_cachedToken != null && _cachedToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $_cachedToken';
      }
      await effectiveTransport.postJson(
        uri: uri,
        payload: const {},
        timeout: const Duration(seconds: 5),
        headers: headers,
      );
    } catch (_) {
      // Do not block client signout on network issues
    } finally {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_userKey);
      await prefs.remove(_tokenKey);
      _cachedUser = null;
      _cachedToken = null;
    }
  }

  Future<void> _persistSession(UserProfile user, String? token) async {
    _cachedUser = user;
    _cachedToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
    if (token != null && token.isNotEmpty) {
      await prefs.setString(_tokenKey, token);
    }
  }

  Map<String, dynamic> _parseResponse(AgentHttpResponse response) {
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return {'detail': response.body};
    }
  }
}

/// Baseline local preference implementation for storing user profile state.
class LocalAuthService implements AuthService {
  static const String _userKey = 'dont_miss_auth_user_v1';

  @override
  Future<UserProfile?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_userKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return UserProfile.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> isAuthenticated() async {
    final user = await getCurrentUser();
    return user != null;
  }

  @override
  Future<UserProfile> signUp({
    required String name,
    required String phoneNumber,
    required String password,
  }) async {
    final user = UserProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name.trim(),
      phoneNumber: phoneNumber.trim(),
      isVerified: false,
      createdAt: DateTime.now(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
    return user;
  }

  @override
  Future<UserProfile> signIn({
    required String phoneNumber,
    required String password,
  }) async {
    final current = await getCurrentUser();
    if (current != null && current.phoneNumber == phoneNumber.trim()) {
      return current;
    }
    // Baseline local mock sign-in
    final user = UserProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: 'User',
      phoneNumber: phoneNumber.trim(),
      isVerified: false,
      createdAt: DateTime.now(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
    return user;
  }

  @override
  Future<bool> verifyPhone({
    required String phoneNumber,
    required String code,
  }) async {
    final current = await getCurrentUser();
    if (current != null && code.trim().isNotEmpty) {
      final updated = current.copyWith(isVerified: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_userKey, jsonEncode(updated.toJson()));
      return true;
    }
    return false;
  }

  @override
  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
  }
}
