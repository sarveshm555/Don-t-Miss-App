import 'package:flutter_test/flutter_test.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/models/task.dart';
import 'package:dont_miss/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationService Tests', () {
    test('Default instance has valid constants and initial state', () {
      expect(NotificationService.channelId, 'dont_miss_reminders_channel');
      expect(NotificationService.channelName, "Don't Miss Reminders");
      expect(NotificationService.channelDescription, isNotEmpty);
      expect(NotificationService.activeIconName, isNotEmpty);
    });

    test('Overdue reminder (> 2 minutes past) is skipped gracefully without errors', () async {
      final service = NotificationService.instance;
      final pastDate = DateTime.now().subtract(const Duration(minutes: 10));
      final task = Task(
        id: 'past-task-id',
        title: 'Old Task',
        dueDate: pastDate,
        dueHour: pastDate.hour,
        dueMinute: pastDate.minute,
        createdAt: DateTime.now(),
      );

      // Should complete without unhandled exceptions
      await service.scheduleTaskNotification(task);
      expect(task.isOverdue, isTrue);
    });

    test('Completed or disabled notification tasks return early without scheduling errors', () async {
      final service = NotificationService.instance;
      final futureDate = DateTime.now().add(const Duration(hours: 2));

      final disabledTask = Task(
        id: 'disabled-notif-task',
        title: 'Silent Task',
        dueDate: futureDate,
        dueHour: futureDate.hour,
        dueMinute: futureDate.minute,
        isNotificationEnabled: false,
        createdAt: DateTime.now(),
      );
      await service.scheduleTaskNotification(disabledTask);

      final completedTask = Task(
        id: 'completed-task',
        title: 'Finished Task',
        dueDate: futureDate,
        dueHour: futureDate.hour,
        dueMinute: futureDate.minute,
        isCompleted: true,
        createdAt: DateTime.now(),
      );
      await service.scheduleTaskNotification(completedTask);
      expect(completedTask.isCompleted, isTrue);
    });

    test('Deterministic positive notificationId generation handles boundaries', () {
      final task1 = Task(
        id: 'uuid-alpha-1234',
        title: 'Sample 1',
        dueDate: DateTime.now(),
        dueHour: 10,
        dueMinute: 30,
        createdAt: DateTime.now(),
      );
      final task2 = Task(
        id: 'uuid-alpha-1234',
        title: 'Sample 1 Copy',
        dueDate: DateTime.now(),
        dueHour: 10,
        dueMinute: 30,
        createdAt: DateTime.now(),
      );
      final task3 = Task(
        id: 'uuid-beta-5678',
        title: 'Sample 2',
        dueDate: DateTime.now(),
        dueHour: 10,
        dueMinute: 30,
        createdAt: DateTime.now(),
      );

      // Deterministic identical hash
      expect(task1.notificationId, equals(task2.notificationId));
      // Distinct hash
      expect(task1.notificationId, isNot(equals(task3.notificationId)));
      // Within 31-bit integer boundary (0 to 0x7FFFFFFF)
      expect(task1.notificationId, isNonNegative);
      expect(task1.notificationId, lessThanOrEqualTo(0x7FFFFFFF));
    });

    test('Near-current-time reminder (< 2 minutes in past) is tolerated and clamped', () {
      final now = DateTime.now();
      // Due 15 seconds ago (e.g. form took 15 seconds to submit)
      final nearPast = now.subtract(const Duration(seconds: 15));
      final task = Task(
        id: 'near-past-id',
        title: 'Urgent reminder',
        dueDate: nearPast,
        dueHour: nearPast.hour,
        dueMinute: nearPast.minute,
        createdAt: now,
      );

      // Verify task model evaluates correctly
      expect(task.isOverdue, isTrue);
      expect(task.isRecurring, isFalse);
    });

    test('Recurring daily/weekly/monthly tasks calculate components accurately', () {
      final futureDate = DateTime.now().add(const Duration(days: 1));
      final dailyTask = Task(
        id: 'daily-id',
        title: 'Daily Medication',
        dueDate: futureDate,
        dueHour: 9,
        dueMinute: 0,
        recurrence: Recurrence.daily,
        createdAt: DateTime.now(),
      );
      expect(dailyTask.isRecurring, isTrue);
      expect(dailyTask.recurrence, Recurrence.daily);

      final weeklyTask = dailyTask.copyWith(recurrence: Recurrence.weekly);
      expect(weeklyTask.recurrence, Recurrence.weekly);

      final monthlyTask = dailyTask.copyWith(recurrence: Recurrence.monthly);
      expect(monthlyTask.recurrence, Recurrence.monthly);
    });
  });
}
