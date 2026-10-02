import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/constants/app_colors.dart';
import '../providers/auth_provider.dart';
import '../screens/home_screen.dart';
import '../screens/sign_in_screen.dart';
import '../services/ai_agent_api_service.dart';
import '../services/ai_reminder_service.dart';

/// Top-level authentication gate widget.
///
/// Observes [AuthProvider] to conditionally display:
/// - A loading spinner while authentication status is being resolved
/// - [HomeScreen] if the user is authenticated
/// - [SignInScreen] if the user is unauthenticated
class AuthGate extends StatelessWidget {
  final AiReminderService? aiService;

  const AuthGate({
    super.key,
    this.aiService = const StrandsAgentApiService(
      fallbackService: LocalAiReminderService(),
    ),
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (auth.isLoading) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/images/app_logo.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(
                    key: Key('auth_gate_loading_indicator'),
                    color: AppColors.primary,
                  ),
                ],
              ),
            ),
          );
        }

        if (auth.isAuthenticated) {
          return HomeScreen(aiService: aiService);
        }

        return const SignInScreen();
      },
    );
  }
}
