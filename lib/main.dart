import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/constants/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/task_provider.dart';
import 'screens/home_screen.dart';
import 'services/ai_agent_api_service.dart';
import 'services/ai_reminder_service.dart';
import 'services/notification_service.dart';

void main() async {
  // Ensure Flutter engine bindings are initialized prior to plugins
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize notification channels and timezone configurations
  await NotificationService.instance.init();

  runApp(const DontMissApp());
}

/// Root widget of the "Don't Miss" reminder application.
class DontMissApp extends StatelessWidget {
  const DontMissApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => TaskProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => AuthProvider(),
        ),
      ],
      child: MaterialApp(
        title: "Don't Miss",
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.system,
        home: const HomeScreen(
          aiService: StrandsAgentApiService(
            fallbackService: LocalAiReminderService(),
          ),
        ),
      ),
    );
  }
}
