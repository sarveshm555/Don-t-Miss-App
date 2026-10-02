import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dont_miss/models/user_profile.dart';
import 'package:dont_miss/providers/auth_provider.dart';
import 'package:dont_miss/providers/task_provider.dart';
import 'package:dont_miss/repositories/task_repository.dart';
import 'package:dont_miss/screens/home_screen.dart';
import 'package:dont_miss/screens/sign_in_screen.dart';
import 'package:dont_miss/screens/sign_up_screen.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/services/auth_service.dart';
import 'package:dont_miss/services/notification_service.dart';
import 'package:dont_miss/widgets/auth_gate.dart';

class FakeTaskRepository implements TaskRepository {
  @override
  Future<List<Task>> getAllTasks() async => [];
  @override
  Future<void> saveAllTasks(List<Task> tasks) async {}
}

class FakeNotificationService implements NotificationService {
  @override
  Future<void> init() async {}
  @override
  Future<bool?> requestPermissions() async => true;
  @override
  Future<void> scheduleTaskNotification(Task task) async {}
  @override
  Future<void> cancelTaskNotification(int notificationId) async {}
  @override
  Future<void> cancelAllNotifications() async {}
}

class FakeAuthService implements AuthService {
  UserProfile? currentUser;
  Completer<UserProfile?>? pendingCurrentUserCompleter;
  String? failSignUpError;
  String? failSignInError;

  @override
  Future<UserProfile?> getCurrentUser() async {
    if (pendingCurrentUserCompleter != null) {
      return pendingCurrentUserCompleter!.future;
    }
    return currentUser;
  }

  @override
  Future<bool> isAuthenticated() async => currentUser != null;

  @override
  Future<UserProfile> signIn({
    required String phoneNumber,
    required String password,
  }) async {
    if (failSignInError != null) {
      throw AuthException(failSignInError!);
    }
    final user = UserProfile(
      id: 'usr-test-signin',
      name: 'Bob Johnson',
      phoneNumber: phoneNumber,
      createdAt: DateTime.now(),
    );
    currentUser = user;
    return user;
  }

  @override
  Future<UserProfile> signUp({
    required String name,
    required String phoneNumber,
    required String password,
  }) async {
    if (failSignUpError != null) {
      throw AuthException(failSignUpError!);
    }
    final user = UserProfile(
      id: 'usr-test-signup',
      name: name,
      phoneNumber: phoneNumber,
      createdAt: DateTime.now(),
    );
    currentUser = user;
    return user;
  }

  @override
  Future<bool> verifyPhone({
    required String phoneNumber,
    required String code,
  }) async => true;

  @override
  Future<void> signOut() async {
    currentUser = null;
  }
}

void main() {
  late FakeAuthService authService;
  late AuthProvider authProvider;
  late TaskProvider taskProvider;

  setUp(() {
    authService = FakeAuthService();
    authProvider = AuthProvider(authService: authService);
    taskProvider = TaskProvider(
      repository: FakeTaskRepository(),
      notificationService: FakeNotificationService(),
    );
  });

  Widget buildTestApp({Widget? home}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<TaskProvider>.value(value: taskProvider),
      ],
      child: MaterialApp(
        home: home ?? const AuthGate(),
      ),
    );
  }

  group('AuthGate Routing Tests', () {
    testWidgets('Displays loading indicator when auth is loading', (tester) async {
      final completer = Completer<UserProfile?>();
      final delayedAuthService = FakeAuthService()
        ..pendingCurrentUserCompleter = completer;
      final delayedAuthProvider = AuthProvider(authService: delayedAuthService);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: delayedAuthProvider),
            ChangeNotifierProvider<TaskProvider>.value(value: taskProvider),
          ],
          child: const MaterialApp(home: AuthGate()),
        ),
      );

      // Loading state should show the progress indicator
      expect(find.byKey(const Key('auth_gate_loading_indicator')), findsOneWidget);

      // Complete future to unblock
      completer.complete(null);
      await tester.pumpAndSettle();

      // Once resolved with null user, routes to SignInScreen
      expect(find.byType(SignInScreen), findsOneWidget);
    });

    testWidgets('Routes unauthenticated user to SignInScreen', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.text("Welcome to Don't Miss"), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('Routes authenticated user to HomeScreen', (tester) async {
      authService.currentUser = UserProfile(
        id: 'usr-logged-in',
        name: 'Alice Wonderland',
        phoneNumber: '+15551234567',
        createdAt: DateTime.now(),
      );
      await authProvider.loadUser();

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
    });
  });

  group('SignInScreen Widget Tests', () {
    testWidgets('Shows validation errors on empty fields', (tester) async {
      await tester.pumpWidget(buildTestApp(home: const SignInScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sign_in_submit_button')));
      await tester.pumpAndSettle();

      expect(find.text('Please enter your phone number'), findsOneWidget);
      expect(find.text('Please enter your password'), findsOneWidget);
    });

    testWidgets('Shows validation errors on invalid phone number or short password', (tester) async {
      await tester.pumpWidget(buildTestApp(home: const SignInScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('sign_in_phone_field')), '123');
      await tester.enterText(find.byKey(const Key('sign_in_password_field')), 'abc');
      await tester.tap(find.byKey(const Key('sign_in_submit_button')));
      await tester.pumpAndSettle();

      expect(find.text('Please enter a valid phone number'), findsOneWidget);
      expect(find.text('Password must be at least 6 characters'), findsOneWidget);
    });

    testWidgets('Toggles password obscurity when visibility button is tapped', (tester) async {
      await tester.pumpWidget(buildTestApp(home: const SignInScreen()));
      await tester.pumpAndSettle();

      final passwordFinder = find.byKey(const Key('sign_in_password_field'));
      TextField textField = tester.widget(find.descendant(of: passwordFinder, matching: find.byType(TextField)));
      expect(textField.obscureText, isTrue);

      await tester.tap(find.byKey(const Key('sign_in_password_visibility_toggle')));
      await tester.pumpAndSettle();

      textField = tester.widget(find.descendant(of: passwordFinder, matching: find.byType(TextField)));
      expect(textField.obscureText, isFalse);
    });

    testWidgets('Successful SignIn authenticates and transitions AuthGate to HomeScreen', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.byType(SignInScreen), findsOneWidget);

      await tester.enterText(find.byKey(const Key('sign_in_phone_field')), '+15559876543');
      await tester.enterText(find.byKey(const Key('sign_in_password_field')), 'ValidPassword123');
      await tester.tap(find.byKey(const Key('sign_in_submit_button')));
      await tester.pumpAndSettle();

      expect(authProvider.isAuthenticated, isTrue);
      expect(authProvider.currentUser?.phoneNumber, '+15559876543');
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
    });

    testWidgets('Failed SignIn displays readable error in SnackBar', (tester) async {
      authService.failSignInError = 'Invalid phone number or password';

      await tester.pumpWidget(buildTestApp(home: const SignInScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('sign_in_phone_field')), '+15559876543');
      await tester.enterText(find.byKey(const Key('sign_in_password_field')), 'WrongPassword');
      await tester.tap(find.byKey(const Key('sign_in_submit_button')));
      await tester.pumpAndSettle();

      expect(authProvider.isAuthenticated, isFalse);
      expect(find.text('Invalid phone number or password'), findsOneWidget);
    });

    testWidgets('Navigates from SignInScreen to SignUpScreen and back', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.byType(SignInScreen), findsOneWidget);

      // Tap Sign Up link
      await tester.tap(find.byKey(const Key('sign_in_to_sign_up_button')));
      await tester.pumpAndSettle();

      expect(find.byType(SignUpScreen), findsOneWidget);
      expect(find.text('Create Account'), findsOneWidget);

      // Tap Sign In link to go back
      await tester.tap(find.byKey(const Key('sign_up_to_sign_in_button')));
      await tester.pumpAndSettle();

      expect(find.byType(SignInScreen), findsOneWidget);
    });
  });

  group('SignUpScreen Widget Tests', () {
    testWidgets('Shows validation errors on empty fields', (tester) async {
      await tester.pumpWidget(buildTestApp(home: const SignUpScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sign_up_submit_button')));
      await tester.pumpAndSettle();

      expect(find.text('Please enter your full name'), findsOneWidget);
      expect(find.text('Please enter your phone number'), findsOneWidget);
      expect(find.text('Please enter a password'), findsOneWidget);
      expect(find.text('Please confirm your password'), findsOneWidget);
    });

    testWidgets('Shows validation error when passwords do not match', (tester) async {
      await tester.pumpWidget(buildTestApp(home: const SignUpScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('sign_up_name_field')), 'David Miller');
      await tester.enterText(find.byKey(const Key('sign_up_phone_field')), '+15554443322');
      await tester.enterText(find.byKey(const Key('sign_up_password_field')), 'Password123');
      await tester.enterText(find.byKey(const Key('sign_up_confirm_password_field')), 'Password999');
      await tester.tap(find.byKey(const Key('sign_up_submit_button')));
      await tester.pumpAndSettle();

      expect(find.text('Passwords do not match'), findsOneWidget);
    });

    testWidgets('Successful SignUp sets authenticated user and transitions to HomeScreen', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Go to SignUpScreen from SignInScreen
      await tester.tap(find.byKey(const Key('sign_in_to_sign_up_button')));
      await tester.pumpAndSettle();

      expect(find.byType(SignUpScreen), findsOneWidget);

      await tester.enterText(find.byKey(const Key('sign_up_name_field')), 'Sarah Connor');
      await tester.enterText(find.byKey(const Key('sign_up_phone_field')), '+15557778899');
      await tester.enterText(find.byKey(const Key('sign_up_password_field')), 'Pass123456');
      await tester.enterText(find.byKey(const Key('sign_up_confirm_password_field')), 'Pass123456');
      await tester.tap(find.byKey(const Key('sign_up_submit_button')));
      await tester.pumpAndSettle();

      expect(authProvider.isAuthenticated, isTrue);
      expect(authProvider.currentUser?.name, 'Sarah Connor');
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('Failed SignUp displays readable error in SnackBar', (tester) async {
      authService.failSignUpError = 'Phone number already registered';

      await tester.pumpWidget(buildTestApp(home: const SignUpScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('sign_up_name_field')), 'Sarah Connor');
      await tester.enterText(find.byKey(const Key('sign_up_phone_field')), '+15557778899');
      await tester.enterText(find.byKey(const Key('sign_up_password_field')), 'Pass123456');
      await tester.enterText(find.byKey(const Key('sign_up_confirm_password_field')), 'Pass123456');
      await tester.tap(find.byKey(const Key('sign_up_submit_button')));
      await tester.pumpAndSettle();

      expect(authProvider.isAuthenticated, isFalse);
      expect(find.text('Phone number already registered'), findsOneWidget);
    });
  });

  group('HomeScreen Account & SignOut Tests', () {
    testWidgets('Displays user information and signs out correctly', (tester) async {
      authService.currentUser = UserProfile(
        id: 'usr-logged-in-2',
        name: 'Bruce Wayne',
        phoneNumber: '+15550001122',
        createdAt: DateTime.now(),
      );
      await authProvider.loadUser();

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);

      // Find account menu button in AppBar
      final accountMenuFinder = find.byKey(const Key('home_account_menu_button'));
      expect(accountMenuFinder, findsOneWidget);

      // Open menu
      await tester.tap(accountMenuFinder);
      await tester.pumpAndSettle();

      // Verify name, phone, and Sign Out item
      expect(find.text('Bruce Wayne'), findsOneWidget);
      expect(find.text('+15550001122'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);

      // Tap Sign Out
      await tester.tap(find.text('Sign Out'));
      await tester.pumpAndSettle();

      // AuthGate switches back to SignInScreen
      expect(authProvider.isAuthenticated, isFalse);
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });
  });
}
