import 'package:flutter/foundation.dart';
import '../models/user_profile.dart';
import '../services/auth_service.dart';

/// State management provider for authentication and user verification.
class AuthProvider extends ChangeNotifier {
  final AuthService _authService;

  UserProfile? _currentUser;
  bool _isLoading = true;
  String? _errorMessage;

  AuthProvider({AuthService? authService})
      : _authService = authService ?? ApiAuthService() {
    loadUser();
  }

  UserProfile? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  bool get isVerified => _currentUser?.isVerified ?? false;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get token => _authService is ApiAuthService
      ? (_authService as ApiAuthService).currentToken
      : null;

  Future<void> loadUser() async {
    _isLoading = true;
    notifyListeners();
    try {
      _currentUser = await _authService.getCurrentUser();
    } catch (_) {
      _currentUser = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signUp({
    required String name,
    required String phoneNumber,
    required String password,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _currentUser = await _authService.signUp(
        name: name,
        phoneNumber: phoneNumber,
        password: password,
      );
      return true;
    } catch (e) {
      _errorMessage = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signIn({
    required String phoneNumber,
    required String password,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _currentUser = await _authService.signIn(
        phoneNumber: phoneNumber,
        password: password,
      );
      return true;
    } catch (e) {
      _errorMessage = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> verifyPhone(String code) async {
    if (_currentUser == null) return false;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final success = await _authService.verifyPhone(
        phoneNumber: _currentUser!.phoneNumber,
        code: code,
      );
      if (success) {
        _currentUser = _currentUser!.copyWith(isVerified: true);
      }
      return success;
    } catch (e) {
      _errorMessage = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    await _authService.signOut();
    _currentUser = null;
    notifyListeners();
  }
}
