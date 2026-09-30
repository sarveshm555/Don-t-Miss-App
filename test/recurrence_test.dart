import 'package:flutter_test/flutter_test.dart';
import 'package:dont_miss/models/priority.dart';
import 'package:dont_miss/models/recurrence.dart';
import 'package:dont_miss/models/task.dart';

void main() {
  group('Recurrence Model Tests', () {
    test('Recurrence enum labels and properties', () {
      expect(Recurrence.none.label, 'None');
      expect(Recurrence.daily.label, 'Daily');
      expect(Recurrence.weekly.label, 'Weekly');
      expect(Recurrence.monthly.label, 'Monthly');
    });

    test('Recurrence.fromString parser handles all cases', () {
      expect(Recurrence.fromString(null), Recurrence.none);
      expect(Recurrence.fromString(''), Recurrence.none);
      expect(Recurrence.fromString('none'), Recurrence.none);
      expect(Recurrence.fromString('None'), Recurrence.none);
      expect(Recurrence.fromString('daily'), Recurrence.daily);
      expect(Recurrence.fromString('Daily'), Recurrence.daily);
      expect(Recurrence.fromString('weekly'), Recurrence.weekly);
      expect(Recurrence.fromString('Weekly'), Recurrence.weekly);
      expect(Recurrence.fromString('monthly'), Recurrence.monthly);
      expect(Recurrence.fromString('Monthly'), Recurrence.monthly);
      expect(Recurrence.fromString('other'), Recurrence.none);
    });
  });

  group('Task Model Recurrence & Backward Compatibility Tests', () {
    final now = DateTime(2026, 9, 18, 12, 0);

    test('Default task has Recurrence.none and isRecurring is false', () {
      final task = Task(
        id: 'one-time-1',
        title: 'One-time Task',
        dueDate: DateTime(2026, 9, 20),
        dueHour: 10,
        dueMinute: 0,
        createdAt: now,
      );

      expect(task.recurrence, Recurrence.none);
      expect(task.isRecurring, isFalse);
    });

    test('Daily recurring task', () {
      final task = Task(
        id: 'daily-1',
        title: 'Daily Task',
        dueDate: DateTime(2026, 9, 20),
        dueHour: 9,
        dueMinute: 30,
        recurrence: Recurrence.daily,
        createdAt: now,
      );

      expect(task.recurrence, Recurrence.daily);
      expect(task.isRecurring, isTrue);
    });

    test('Weekly recurring task', () {
      final task = Task(
        id: 'weekly-1',
        title: 'Weekly Task',
        dueDate: DateTime(2026, 9, 20),
        dueHour: 15,
        dueMinute: 0,
        recurrence: Recurrence.weekly,
        createdAt: now,
      );

      expect(task.recurrence, Recurrence.weekly);
      expect(task.isRecurring, isTrue);
    });

    test('Monthly recurring task', () {
      final task = Task(
        id: 'monthly-1',
        title: 'Monthly Task',
        dueDate: DateTime(2026, 9, 20),
        dueHour: 18,
        dueMinute: 0,
        recurrence: Recurrence.monthly,
        createdAt: now,
      );

      expect(task.recurrence, Recurrence.monthly);
      expect(task.isRecurring, isTrue);
    });

    test('Serialization and deserialization round-trip preserves recurrence', () {
      final task = Task(
        id: 'test-123',
        title: 'Weekly Team Review',
        description: 'Review roadmap & AWS deployment',
        dueDate: DateTime(2026, 9, 25),
        dueHour: 18,
        dueMinute: 45,
        priority: Priority.high,
        recurrence: Recurrence.weekly,
        url: 'https://aws.amazon.com',
        isNotificationEnabled: true,
        isCompleted: false,
        createdAt: now,
      );

      final json = task.toJson();
      expect(json['recurrence'], 'weekly');

      final deserialized = Task.fromJson(json);
      expect(deserialized.id, task.id);
      expect(deserialized.title, task.title);
      expect(deserialized.recurrence, Recurrence.weekly);
      expect(deserialized.isRecurring, isTrue);
      expect(deserialized.priority, Priority.high);
    });

    test('BACKWARD COMPATIBILITY: legacy JSON without recurrence defaults to none', () {
      final legacyJson = <String, dynamic>{
        'id': 'legacy-task-1',
        'title': 'Legacy One-Time Reminder',
        'description': 'Saved before recurrence was introduced',
        'dueDate': '2026-09-20T00:00:00.000',
        'dueHour': 14,
        'dueMinute': 0,
        'priority': 'medium',
        'url': null,
        'isNotificationEnabled': true,
        'isCompleted': false,
        'createdAt': '2026-09-18T12:00:00.000',
      };

      final task = Task.fromJson(legacyJson);

      expect(task.id, 'legacy-task-1');
      expect(task.title, 'Legacy One-Time Reminder');
      expect(task.recurrence, Recurrence.none);
      expect(task.isRecurring, isFalse);
    });

    test('copyWith properly updates recurrence', () {
      final original = Task(
        id: 'copy-1',
        title: 'Original',
        dueDate: DateTime(2026, 9, 20),
        dueHour: 12,
        dueMinute: 0,
        recurrence: Recurrence.none,
        createdAt: now,
      );

      final modified = original.copyWith(recurrence: Recurrence.daily);
      expect(modified.recurrence, Recurrence.daily);
      expect(modified.isRecurring, isTrue);

      final backToNone = modified.copyWith(recurrence: Recurrence.none);
      expect(backToNone.recurrence, Recurrence.none);
      expect(backToNone.isRecurring, isFalse);
    });
  });

  group('Notification ID Reliability Tests', () {
    test('notificationId is deterministic and positive 31-bit integer', () {
      final taskA = Task(
        id: '3fa85f64-5717-4562-b3fc-2c963f66afa6',
        title: 'Task A',
        dueDate: DateTime(2026, 9, 20),
        dueHour: 10,
        dueMinute: 0,
        createdAt: DateTime(2026, 9, 19),
      );

      final id1 = taskA.notificationId;
      final id2 = taskA.notificationId;

      expect(id1, id2);
      expect(id1 >= 0, isTrue);
      expect(id1 <= 0x7FFFFFFF, isTrue);
    });

    test('Different task IDs produce distinct notification IDs without collisions', () {
      final ids = <int>{};
      final testUuids = [
        'e0344d18-5a2d-4c31-9f93-c3c6f8516d29',
        '8b76615b-9759-4089-9a74-d4b8f36c5356',
        '804daeb0-3bd8-49e0-82d2-8b63cfcb0019',
        '336b135c-897c-40ad-be00-1c3905cf7eb5',
        '6cb9ba37-33a8-4bbd-9781-64d852a41d63',
      ];

      for (final uuid in testUuids) {
        final task = Task(
          id: uuid,
          title: 'Task $uuid',
          dueDate: DateTime(2026, 9, 20),
          dueHour: 12,
          dueMinute: 0,
          createdAt: DateTime(2026, 9, 19),
        );
        expect(task.notificationId >= 0, isTrue);
        expect(task.notificationId <= 0x7FFFFFFF, isTrue);
        ids.add(task.notificationId);
      }

      expect(ids.length, testUuids.length);
    });
  });
}
