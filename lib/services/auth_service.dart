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
  String? get currentToken => null;
  String? get currentRefreshToken => null;
  Future<String?> refreshSession() async => null;
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
  static const String _refreshTokenKey = 'dont_miss_auth_refresh_token_v1';
  static const String _tasksCacheKey = 'dont_miss_saved_tasks_v1';
  static const String _deletedTaskIdsKey = 'dont_miss_deleted_task_ids_v1';
  static const Duration _authTimeout = Duration(seconds: 60);

  static ApiAuthService? _sharedInstance;
  static ApiAuthService get shared => _sharedInstance ??= ApiAuthService();
  static set shared(ApiAuthService instance) => _sharedInstance = instance;

  final String? baseUrl;
  final AgentHttpTransport? transport;

  String? _cachedToken;
  String? _cachedRefreshToken;
  UserProfile? _cachedUser;
  Future<String?>? _ongoingRefresh;

  ApiAuthService({
    this.baseUrl,
    this.transport,
  }) {
    _sharedInstance ??= this;
  }

  String get effectiveBaseUrl =>
      baseUrl ?? StrandsAgentApiService.defaultBaseUrl;

  AgentHttpTransport get effectiveTransport =>
      transport ?? createAgentHttpTransport();

  @override
  String? get currentToken => _cachedToken;

  @override
  String? get currentRefreshToken => _cachedRefreshToken;

  /// Checks whether a valid structural JWT string is expired according to its `exp` claim.
  /// Synthetic non-JSON test tokens return `false` so mocked session tests are unaffected.
  bool _isJwtExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final payload = jsonDecode(decoded);
      if (payload is! Map<String, dynamic>) return false;
      final exp = payload['exp'];
      if (exp is! int) return false;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= exp - 30;
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearStoredSession(SharedPreferences prefs) async {
    await prefs.remove(_userKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_refreshTokenKey);
    _cachedUser = null;
    _cachedToken = null;
    _cachedRefreshToken = null;
  }

  @override
  Future<UserProfile?> getCurrentUser() async {
    if (_cachedUser != null) return _cachedUser;

    final prefs = await SharedPreferences.getInstance();
    final rawUser = prefs.getString(_userKey);
    _cachedToken = prefs.getString(_tokenKey);
    _cachedRefreshToken = prefs.getString(_refreshTokenKey);

    if (rawUser == null || rawUser.isEmpty) return null;

    if (_cachedToken != null &&
        _cachedToken!.isNotEmpty &&
        _isJwtExpired(_cachedToken!)) {
      final refreshed = await refreshSession();
      if (refreshed == null || refreshed.isEmpty) {
        await _clearStoredSession(prefs);
        return null;
      }
    }

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
  Future<String?> refreshSession() async {
    if (_ongoingRefresh != null) {
      return _ongoingRefresh;
    }
    _ongoingRefresh = _executeRefresh();
    try {
      return await _ongoingRefresh;
    } finally {
      _ongoingRefresh = null;
    }
  }

  Future<String?> _executeRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    final rToken = _cachedRefreshToken ?? prefs.getString(_refreshTokenKey);
    if (rToken == null || rToken.isEmpty) {
      return null;
    }

    final uri = Uri.parse('$effectiveBaseUrl/auth/refresh');
    final payload = {'refresh_token': rToken};

    try {
      final response = await effectiveTransport.postJson(
        uri: uri,
        payload: payload,
        timeout: _authTimeout,
      );

      final data = _parseResponse(response);
      if (response.statusCode == 200 && (data['success'] as bool? ?? false)) {
        final newToken = data['token'] as String?;
        final newRefreshToken = (data['refresh_token'] as String?) ?? rToken;
        if (newToken != null && newToken.isNotEmpty) {
          _cachedToken = newToken;
          _cachedRefreshToken = newRefreshToken;
          await prefs.setString(_tokenKey, newToken);
          await prefs.setString(_refreshTokenKey, newRefreshToken);
          return newToken;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
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
      timeout: _authTimeout,
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
      final refreshToken = data['refresh_token'] as String?;
      await _persistSession(user, token, refreshToken: refreshToken);
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
      timeout: _authTimeout,
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
      final refreshToken = data['refresh_token'] as String?;
      await _persistSession(user, token, refreshToken: refreshToken);
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
      timeout: _authTimeout,
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
      final refreshToken = data['refresh_token'] as String? ?? _cachedRefreshToken;
      await _persistSession(updated, token, refreshToken: refreshToken);
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
      await _clearStoredSession(prefs);
      await prefs.remove(_tasksCacheKey);
      await prefs.remove(_deletedTaskIdsKey);
    }
  }

  Future<void> _persistSession(
    UserProfile user,
    String? token, {
    String? refreshToken,
  }) async {
    _cachedUser = user;
    _cachedToken = token;
    if (refreshToken != null) {
      _cachedRefreshToken = refreshToken;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
    if (token != null && token.isNotEmpty) {
      await prefs.setString(_tokenKey, token);
    }
    if (_cachedRefreshToken != null && _cachedRefreshToken!.isNotEmpty) {
      await prefs.setString(_refreshTokenKey, _cachedRefreshToken!);
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
  String? get currentToken => 'local_mock_access_token';

  @override
  String? get currentRefreshToken => 'local_mock_refresh_token';

  @override
  Future<String?> refreshSession() async => 'local_mock_access_token';

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
