import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../models/recurrence.dart';
import '../models/task.dart';

/// Central service for initializing, scheduling, and cancelling local notifications.
class NotificationService {
  NotificationService._internal({FlutterLocalNotificationsPlugin? plugin})
      : _notificationsPlugin = plugin ?? FlutterLocalNotificationsPlugin();

  static final NotificationService instance = NotificationService._internal();

  /// Test-accessible factory constructor
  factory NotificationService.withPlugin(FlutterLocalNotificationsPlugin plugin) {
    return NotificationService._internal(plugin: plugin);
  }

  final FlutterLocalNotificationsPlugin _notificationsPlugin;

  static const String channelId = 'dont_miss_reminders_channel';
  static const String channelName = "Don't Miss Reminders";
  static const String channelDescription =
      'Scheduled alerts for upcoming deadlines and tasks.';

  bool _isInitialized = false;
  String _activeIconName = 'ic_notification';
  String? _lastError;

  // Diagnostic and status properties exposed statically for easy monitoring without breaking interface
  static bool get isInitialized => instance._isInitialized;
  static String get activeIconName => instance._activeIconName;
  static String? get lastError => instance._lastError;
  static Future<List<PendingNotificationRequest>> getPendingNotificationRequests() =>
      instance._getPendingNotificationRequests();

  /// Initializes timezone database, detects device timezone, and configures the notification plugin.
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      tz_data.initializeTimeZones();
      try {
        final timeZoneInfo = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(timeZoneInfo.identifier));
      } catch (e) {
        developer.log('Could not configure local timezone from device: $e');
        debugPrint('[NotificationService] Timezone auto-detect warning: $e');
      }

      const DarwinInitializationSettings iosSettings =
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      // Attempt initialization with primary drawable icon ('ic_notification')
      AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings(_activeIconName);
      InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      bool initialized = false;
      try {
        final result = await _notificationsPlugin.initialize(
          initSettings,
          onDidReceiveNotificationResponse: (NotificationResponse response) {
            developer.log('Notification tapped with payload: ${response.payload}');
          },
        );
        initialized = result ?? false;
      } catch (iconError) {
        debugPrint('[NotificationService] Primary icon "$_activeIconName" failed: $iconError');
        // Graceful fallback to guaranteed launcher icon
        _activeIconName = '@mipmap/ic_launcher';
        androidSettings = AndroidInitializationSettings(_activeIconName);
        initSettings = InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        );
        final result = await _notificationsPlugin.initialize(
          initSettings,
          onDidReceiveNotificationResponse: (NotificationResponse response) {
            developer.log('Notification tapped with payload: ${response.payload}');
          },
        );
        initialized = result ?? false;
      }

      // Explicitly register notification channel for Android 8.0+ (Oreo)
      final androidImplementation = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidImplementation != null) {
        const channel = AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.max,
        );
        await androidImplementation.createNotificationChannel(channel);
        debugPrint('[NotificationService] Registered Android notification channel: $channelId');
      }

      _isInitialized = initialized;
      _lastError = null;
      debugPrint('[NotificationService] Initialized successfully with icon "$_activeIconName"');
    } catch (e) {
      _lastError = e.toString();
      developer.log('Failed to initialize NotificationService: $e');
      debugPrint('[NotificationService] Initialization error: $e');
    }
  }

  /// Requests notification permission (specifically required for Android 13+ / Tiramisu).
  Future<bool?> requestPermissions() async {
    final androidImplementation = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      return await androidImplementation.requestNotificationsPermission();
    }
    return false;
  }

  /// Schedules a notification for a task at its designated date and time,
  /// supporting one-time and recurring (daily, weekly, monthly) schedules.
  Future<void> scheduleTaskNotification(Task task) async {
    if (!task.isNotificationEnabled || task.isCompleted) return;

    if (!_isInitialized) {
      await init();
    }

    DateTime targetDateTime = task.fullDueDateTime;
    final now = DateTime.now();

    // Past / overdue handling for one-time reminders
    if (!task.isRecurring && targetDateTime.isBefore(now)) {
      final pastDuration = now.difference(targetDateTime);
      // If reminder was set for the current minute or finished saving within the last 2 minutes,
      // schedule it for immediate delivery in 5 seconds rather than dropping it silently.
      if (pastDuration <= const Duration(minutes: 2)) {
        targetDateTime = now.add(const Duration(seconds: 5));
        debugPrint('[NotificationService] Adjusted near-current reminder "${task.title}" to fire in 5 seconds.');
      } else {
        debugPrint('[NotificationService] Skipping reminder "${task.title}": overdue by ${pastDuration.inMinutes} minutes.');
        return;
      }
    }

    // Determine matching components for recurring alarms and advance start time if in past
    DateTimeComponents? matchDateTimeComponents;
    switch (task.recurrence) {
      case Recurrence.daily:
        matchDateTimeComponents = DateTimeComponents.time;
        while (targetDateTime.isBefore(now)) {
          targetDateTime = targetDateTime.add(const Duration(days: 1));
        }
        break;
      case Recurrence.weekly:
        matchDateTimeComponents = DateTimeComponents.dayOfWeekAndTime;
        while (targetDateTime.isBefore(now)) {
          targetDateTime = targetDateTime.add(const Duration(days: 7));
        }
        break;
      case Recurrence.monthly:
        matchDateTimeComponents = DateTimeComponents.dayOfMonthAndTime;
        while (targetDateTime.isBefore(now)) {
          final nextMonth = targetDateTime.month == 12 ? 1 : targetDateTime.month + 1;
          final nextYear = targetDateTime.month == 12 ? targetDateTime.year + 1 : targetDateTime.year;
          final daysInNextMonth = DateTime(nextYear, nextMonth + 1, 0).day;
          final targetDay = task.dueDate.day > daysInNextMonth ? daysInNextMonth : task.dueDate.day;
          targetDateTime = DateTime(nextYear, nextMonth, targetDay, task.dueHour, task.dueMinute);
        }
        break;
      case Recurrence.none:
        matchDateTimeComponents = null;
        break;
    }

    // Cleanly purge any existing notification/alarm for this ID before scheduling
    await cancelTaskNotification(task.notificationId);

    try {
      final scheduledDate = tz.TZDateTime.from(targetDateTime, tz.local);

      NotificationDetails buildDetails(String icon) {
        final androidDetails = AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.max,
          priority: Priority.high,
          icon: icon,
          styleInformation: BigTextStyleInformation(
            task.description.isNotEmpty ? task.description : 'Your reminder is due now!',
            contentTitle: task.title,
            summaryText: task.isRecurring
                ? "Priority: ${task.priority.label} • Repeat: ${task.recurrence.label}"
                : "Priority: ${task.priority.label}",
          ),
        );

        return NotificationDetails(
          android: androidDetails,
          iOS: const DarwinNotificationDetails(),
        );
      }

      NotificationDetails notificationDetails = buildDetails(_activeIconName);

      // Attempt exact alarm scheduling; gracefully fallback to inexact if restricted
      try {
        await _notificationsPlugin.zonedSchedule(
          task.notificationId,
          task.title,
          task.description.isNotEmpty
              ? task.description
              : 'Don\'t miss this: ${task.title}',
          scheduledDate,
          notificationDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: matchDateTimeComponents,
          payload: task.id,
        );
      } catch (scheduleError) {
        // If primary icon caused failure, retry with launcher icon fallback
        if (scheduleError.toString().contains('invalid_icon') && _activeIconName != '@mipmap/ic_launcher') {
          debugPrint('[NotificationService] Retrying schedule with fallback icon @mipmap/ic_launcher');
          _activeIconName = '@mipmap/ic_launcher';
          notificationDetails = buildDetails(_activeIconName);
        }

        debugPrint('[NotificationService] Retrying with inexact scheduling: $scheduleError');
        await _notificationsPlugin.zonedSchedule(
          task.notificationId,
          task.title,
          task.description.isNotEmpty
              ? task.description
              : 'Don\'t miss this: ${task.title}',
          scheduledDate,
          notificationDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: matchDateTimeComponents,
          payload: task.id,
        );
      }

      _lastError = null;
      debugPrint('[NotificationService] Notification scheduled for "${task.title}" at $scheduledDate (ID: ${task.notificationId})');
    } catch (e) {
      _lastError = e.toString();
      developer.log('Error scheduling notification for task "${task.title}": $e');
      debugPrint('[NotificationService] Error scheduling notification: $e');
    }
  }

  /// Internal query for pending requests
  Future<List<PendingNotificationRequest>> _getPendingNotificationRequests() async {
    try {
      return await _notificationsPlugin.pendingNotificationRequests();
    } catch (e) {
      debugPrint('[NotificationService] Error querying pending requests: $e');
      return [];
    }
  }

  /// Cancels a scheduled notification by task notificationId.
  Future<void> cancelTaskNotification(int notificationId) async {
    try {
      await _notificationsPlugin.cancel(notificationId);
      developer.log('Cancelled notification with ID: $notificationId');
    } catch (e) {
      developer.log('Error cancelling notification: $e');
      debugPrint('[NotificationService] Error cancelling notification: $e');
    }
  }

  /// Cancels all scheduled notifications.
  Future<void> cancelAllNotifications() async {
    try {
      await _notificationsPlugin.cancelAll();
      developer.log('Cancelled all notifications.');
    } catch (e) {
      developer.log('Error cancelling all notifications: $e');
      debugPrint('[NotificationService] Error cancelling all notifications: $e');
    }
  }
}
