import 'priority.dart';
import 'recurrence.dart';

/// Immutable model representing a single reminder / task in "Don't Miss".
class Task {
  final String id;
  final String title;
  final String description;
  final DateTime dueDate;
  final int dueHour;
  final int dueMinute;
  final Priority priority;
  final Recurrence recurrence;
  final String? url;
  final List<String> channels;
  final bool isNotificationEnabled;
  final bool isCompleted;
  final DateTime createdAt;

  const Task({
    required this.id,
    required this.title,
    this.description = '',
    required this.dueDate,
    required this.dueHour,
    required this.dueMinute,
    this.priority = Priority.medium,
    this.recurrence = Recurrence.none,
    this.url,
    this.channels = const ['local', 'whatsapp'],
    this.isNotificationEnabled = true,
    this.isCompleted = false,
    required this.createdAt,
  });

  /// Combines [dueDate], [dueHour], and [dueMinute] into a single [DateTime].
  DateTime get fullDueDateTime {
    return DateTime(
      dueDate.year,
      dueDate.month,
      dueDate.day,
      dueHour,
      dueMinute,
    );
  }

  /// Checks if this task has passed its due date & time relative to [referenceTime] and is not completed.
  bool isOverdueAt(DateTime referenceTime) {
    return !isCompleted && fullDueDateTime.isBefore(referenceTime);
  }

  /// Checks if this task has passed its due date & time and is not completed.
  bool get isOverdue => isOverdueAt(DateTime.now());

  /// Checks if this task is due on the specified calendar [day] and is not completed.
  bool isDueOnDay(DateTime day) {
    return !isCompleted &&
        dueDate.year == day.year &&
        dueDate.month == day.month &&
        dueDate.day == day.day;
  }

  /// Checks if this task is due on today's calendar date and is not completed.
  bool get isDueToday => isDueOnDay(DateTime.now());

  /// Checks if this task repeats on a schedule.
  bool get isRecurring => recurrence != Recurrence.none;

  /// Generates a deterministic positive 31-bit integer identifier for notification scheduling.
  /// Uses 32-bit FNV-1a hashing masked to positive signed 32-bit bounds (0 to 0x7FFFFFFF)
  /// ensuring collision resistance across a 2.14-billion ID space without platform-dependent hash skew.
  int get notificationId {
    var hash = 0x811c9dc5;
    for (var i = 0; i < id.length; i++) {
      hash ^= id.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }

  /// Creates a copy of this task with the given fields replaced.
  Task copyWith({
    String? id,
    String? title,
    String? description,
    DateTime? dueDate,
    int? dueHour,
    int? dueMinute,
    Priority? priority,
    Recurrence? recurrence,
    String? url,
    List<String>? channels,
    bool? isNotificationEnabled,
    bool? isCompleted,
    DateTime? createdAt,
  }) {
    return Task(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      dueDate: dueDate ?? this.dueDate,
      dueHour: dueHour ?? this.dueHour,
      dueMinute: dueMinute ?? this.dueMinute,
      priority: priority ?? this.priority,
      recurrence: recurrence ?? this.recurrence,
      url: url ?? this.url,
      channels: channels ?? this.channels,
      isNotificationEnabled: isNotificationEnabled ?? this.isNotificationEnabled,
      isCompleted: isCompleted ?? this.isCompleted,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Converts the Task instance to a JSON Map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'dueDate': dueDate.toIso8601String(),
      'dueHour': dueHour,
      'dueMinute': dueMinute,
      'priority': priority.name,
      'recurrence': recurrence.name,
      'url': url,
      'channels': channels,
      'isNotificationEnabled': isNotificationEnabled,
      'isCompleted': isCompleted,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  /// Creates a Task instance from a JSON Map.
  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id'] as String,
      title: json['title'] as String,
      description: (json['description'] as String?) ?? '',
      dueDate: DateTime.parse(json['dueDate'] as String),
      dueHour: json['dueHour'] as int? ?? 12,
      dueMinute: json['dueMinute'] as int? ?? 0,
      priority: Priority.fromString(json['priority'] as String?),
      recurrence: Recurrence.fromString(json['recurrence'] as String?),
      url: json['url'] as String?,
      channels: json['channels'] != null
          ? List<String>.from(json['channels'] as List)
          : const ['local', 'whatsapp'],
      isNotificationEnabled: json['isNotificationEnabled'] as bool? ?? true,
      isCompleted: json['isCompleted'] as bool? ?? false,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }
}
