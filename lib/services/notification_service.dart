import 'dart:developer' as developer;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../models/recurrence.dart';
import '../models/task.dart';

/// Central service for initializing, scheduling, and cancelling local notifications.
class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const String channelId = 'dont_miss_reminders_channel';
  static const String channelName = "Don't Miss Reminders";
  static const String channelDescription =
      'Scheduled alerts for upcoming deadlines and tasks.';

  bool _isInitialized = false;

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
      }

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('ic_notification');

      const DarwinInitializationSettings iosSettings =
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          developer.log('Notification tapped with payload: ${response.payload}');
        },
      );

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
      }

      _isInitialized = true;
    } catch (e) {
      developer.log('Failed to initialize NotificationService: $e');
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

    DateTime targetDateTime = task.fullDueDateTime;
    final now = DateTime.now();

    // If one-time and deadline is in the past, skip scheduling
    if (!task.isRecurring && targetDateTime.isBefore(now)) {
      developer.log('Skipping notification for task "${task.title}": time is in the past.');
      return;
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

      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.max,
        priority: Priority.high,
        icon: 'ic_notification',
        styleInformation: BigTextStyleInformation(
          task.description.isNotEmpty ? task.description : 'Your reminder is due now!',
          contentTitle: task.title,
          summaryText: task.isRecurring
              ? "Priority: ${task.priority.label} • Repeat: ${task.recurrence.label}"
              : "Priority: ${task.priority.label}",
        ),
      );

      final notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(),
      );

      // Attempt exact alarm scheduling; gracefully fallback to inexact if exact alarms are restricted
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
      } catch (exactScheduleError) {
        developer.log(
            'Exact alarm scheduling unavailable, falling back to inexact: $exactScheduleError');
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

      developer.log('Notification scheduled for "${task.title}" at $scheduledDate (ID: ${task.notificationId}, Repeat: ${task.recurrence.name})');
    } catch (e) {
      developer.log('Error scheduling notification for task "${task.title}": $e');
    }
  }

  /// Cancels a scheduled notification by task notificationId.
  Future<void> cancelTaskNotification(int notificationId) async {
    try {
      await _notificationsPlugin.cancel(notificationId);
      developer.log('Cancelled notification with ID: $notificationId');
    } catch (e) {
      developer.log('Error cancelling notification: $e');
    }
  }

  /// Cancels all scheduled notifications.
  Future<void> cancelAllNotifications() async {
    try {
      await _notificationsPlugin.cancelAll();
      developer.log('Cancelled all notifications.');
    } catch (e) {
      developer.log('Error cancelling all notifications: $e');
    }
  }
}
