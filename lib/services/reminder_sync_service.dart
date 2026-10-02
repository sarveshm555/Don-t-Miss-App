import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/priority.dart';
import '../models/recurrence.dart';
import '../models/task.dart';
import 'agent_http_transport.dart';
import 'ai_agent_api_service.dart';

class SyncException implements Exception {
  final String message;
  final int? statusCode;
  const SyncException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

class SyncResult {
  final List<Task> mergedTasks;
  final bool success;
  final int uploadedCount;
  final int downloadedCount;
  final int updatedCount;
  final int deletedCount;
  final String? errorMessage;

  const SyncResult({
    required this.mergedTasks,
    required this.success,
    this.uploadedCount = 0,
    this.downloadedCount = 0,
    this.updatedCount = 0,
    this.deletedCount = 0,
    this.errorMessage,
  });
}

/// Dedicated cloud synchronization service for two-way synchronization
/// between local SharedPreferences storage and Supabase PostgreSQL via FastAPI.
class ReminderSyncService {
  static const String _deletedIdsKey = 'dont_miss_deleted_task_ids_v1';
  static const Duration _defaultTimeout = Duration(seconds: 15);

  final String? baseUrl;
  final AgentHttpTransport? transport;

  ReminderSyncService({
    this.baseUrl,
    this.transport,
  });

  String get effectiveBaseUrl =>
      baseUrl ?? StrandsAgentApiService.defaultBaseUrl;

  AgentHttpTransport get effectiveTransport =>
      transport ?? createAgentHttpTransport();

  /// Parse a cloud backend JSON map into a Flutter [Task] model.
  static Task parseCloudReminder(Map<String, dynamic> json) {
    DateTime dueDate;
    try {
      final rawDate = json['due_date'] as String?;
      if (rawDate != null && rawDate.isNotEmpty) {
        dueDate = DateTime.parse(rawDate);
      } else {
        dueDate = DateTime.now();
      }
    } catch (_) {
      dueDate = DateTime.now();
    }

    DateTime createdAt;
    try {
      final rawCreated = json['created_at'] as String?;
      createdAt = rawCreated != null ? DateTime.parse(rawCreated) : DateTime.now();
    } catch (_) {
      createdAt = DateTime.now();
    }

    DateTime? updatedAt;
    try {
      final rawUpdated = json['updated_at'] as String?;
      updatedAt = rawUpdated != null ? DateTime.parse(rawUpdated) : createdAt;
    } catch (_) {
      updatedAt = createdAt;
    }

    final status = (json['status'] as String?)?.toUpperCase();
    final isCompleted = status == 'COMPLETED';

    DateTime? completedAt;
    try {
      final rawCompleted = (json['completed_at'] ?? json['completedAt']) as String?;
      if (rawCompleted != null && rawCompleted.isNotEmpty) {
        completedAt = DateTime.parse(rawCompleted);
      } else if (isCompleted) {
        completedAt = updatedAt;
      }
    } catch (_) {
      completedAt = isCompleted ? updatedAt : null;
    }

    return Task(
      id: json['id'] as String,
      title: json['title'] as String,
      description: (json['description'] as String?) ?? '',
      dueDate: dueDate,
      dueHour: (json['due_hour'] as int?) ?? 12,
      dueMinute: (json['due_minute'] as int?) ?? 0,
      priority: Priority.fromString(json['priority'] as String?),
      recurrence: Recurrence.fromString(json['recurrence'] as String?),
      url: json['url'] as String?,
      channels: (json['channels'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['local', 'whatsapp'],
      isNotificationEnabled: true,
      isCompleted: isCompleted,
      completedAt: completedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// Convert a Flutter [Task] model into a JSON payload for the cloud API.
  static Map<String, dynamic> taskToCloudPayload(Task task) {
    final year = task.dueDate.year.toString().padLeft(4, '0');
    final month = task.dueDate.month.toString().padLeft(2, '0');
    final day = task.dueDate.day.toString().padLeft(2, '0');

    return {
      'id': task.id,
      'title': task.title,
      'description': task.description,
      'due_date': '$year-$month-$day',
      'due_hour': task.dueHour,
      'due_minute': task.dueMinute,
      'priority': task.priority.name,
      'recurrence': task.recurrence.name,
      'url': task.url,
      'channels': task.channels,
      'status': task.isCompleted ? 'COMPLETED' : 'CONFIRMED',
      'completed_at': task.completedAt?.toIso8601String(),
    };
  }

  /// Retrieve cloud reminders belonging strictly to the authenticated user.
  Future<List<Task>> fetchCloudReminders(String authToken) async {
    final uri = Uri.parse('$effectiveBaseUrl/reminders');
    final response = await effectiveTransport.get(
      uri: uri,
      timeout: _defaultTimeout,
      headers: {
        'Authorization': 'Bearer $authToken',
      },
    );

    if (response.statusCode == 200) {
      final List<dynamic> list = jsonDecode(response.body) as List<dynamic>;
      return list
          .map((item) => parseCloudReminder(item as Map<String, dynamic>))
          .toList();
    } else if (response.statusCode == 401) {
      throw const SyncException('Authentication session expired.', 401);
    } else {
      throw SyncException(
        'Failed to fetch cloud reminders (${response.statusCode}): ${response.body}',
        response.statusCode,
      );
    }
  }

  /// Upload a local reminder to the cloud backend.
  Future<Task?> createCloudReminder(Task task, String authToken) async {
    final uri = Uri.parse('$effectiveBaseUrl/reminders');
    final payload = taskToCloudPayload(task);

    final response = await effectiveTransport.postJson(
      uri: uri,
      payload: payload,
      timeout: _defaultTimeout,
      headers: {
        'Authorization': 'Bearer $authToken',
      },
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return parseCloudReminder(data);
    } else if (response.statusCode == 401) {
      throw const SyncException('Authentication session expired.', 401);
    } else {
      throw SyncException(
        'Failed to upload reminder (${response.statusCode}): ${response.body}',
        response.statusCode,
      );
    }
  }

  /// Update an existing cloud reminder.
  Future<Task?> updateCloudReminder(Task task, String authToken) async {
    final uri = Uri.parse('$effectiveBaseUrl/reminders/${task.id}');
    final payload = taskToCloudPayload(task);

    final response = await effectiveTransport.putJson(
      uri: uri,
      payload: payload,
      timeout: _defaultTimeout,
      headers: {
        'Authorization': 'Bearer $authToken',
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return parseCloudReminder(data);
    } else if (response.statusCode == 401) {
      throw const SyncException('Authentication session expired.', 401);
    } else if (response.statusCode == 404) {
      // Cloud record missing; recreate it
      return createCloudReminder(task, authToken);
    } else {
      throw SyncException(
        'Failed to update reminder (${response.statusCode}): ${response.body}',
        response.statusCode,
      );
    }
  }

  /// Delete a reminder from the cloud backend.
  Future<bool> deleteCloudReminder(String taskId, String authToken) async {
    final uri = Uri.parse('$effectiveBaseUrl/reminders/$taskId');
    final response = await effectiveTransport.delete(
      uri: uri,
      timeout: _defaultTimeout,
      headers: {
        'Authorization': 'Bearer $authToken',
      },
    );

    if (response.statusCode == 200 || response.statusCode == 404) {
      return true;
    } else if (response.statusCode == 401) {
      throw const SyncException('Authentication session expired.', 401);
    } else {
      throw SyncException(
        'Failed to delete cloud reminder (${response.statusCode})',
        response.statusCode,
      );
    }
  }

  /// Record an intentional local deletion tombstone for offline-safe deletion sync.
  Future<void> recordLocalDeletion(String taskId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deleted = prefs.getStringList(_deletedIdsKey) ?? [];
      if (!deleted.contains(taskId)) {
        deleted.add(taskId);
        await prefs.setStringList(_deletedIdsKey, deleted);
      }
    } catch (_) {}
  }

  /// Clear a deletion tombstone once successfully propagated to the cloud.
  Future<void> clearLocalDeletion(String taskId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deleted = prefs.getStringList(_deletedIdsKey) ?? [];
      if (deleted.contains(taskId)) {
        deleted.remove(taskId);
        await prefs.setStringList(_deletedIdsKey, deleted);
      }
    } catch (_) {}
  }

  /// Retrieve all recorded local deletion tombstones.
  Future<Set<String>> getDeletedTaskIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_deletedIdsKey) ?? [];
      return list.toSet();
    } catch (_) {
      return {};
    }
  }

  /// Execute a two-way synchronization between local tasks and cloud backend.
  /// 
  /// Strategy:
  /// 1. Download cloud reminders for the authenticated user.
  /// 2. If a cloud reminder matches a local deletion tombstone, delete it in cloud.
  /// 3. If a reminder exists in both, compare [updatedAt] timestamps; newer version wins.
  ///    If local data has no [updatedAt], [createdAt] is used as documented fallback.
  /// 4. If a reminder exists only in cloud and not tombstoned, add it locally.
  /// 5. If a reminder exists only locally, upload it to cloud.
  /// 6. On network or server failure, return original local tasks unmodified.
  Future<SyncResult> sync(List<Task> localTasks, String authToken) async {
    int uploaded = 0;
    int downloaded = 0;
    int updated = 0;
    int deletedCount = 0;

    final List<Task> cloudReminders;
    try {
      cloudReminders = await fetchCloudReminders(authToken);
    } catch (e) {
      return SyncResult(
        mergedTasks: localTasks,
        success: false,
        errorMessage: e.toString(),
      );
    }

    final deletedIds = await getDeletedTaskIds();
    final Map<String, Task> localMap = {for (var t in localTasks) t.id: t};
    final Map<String, Task> cloudMap = {for (var t in cloudReminders) t.id: t};
    final Map<String, Task> resultMap = {};

    // 1. Process cloud reminders
    for (final cloudTask in cloudReminders) {
      if (deletedIds.contains(cloudTask.id)) {
        // Intentionally deleted locally -> propagate deletion to cloud
        try {
          await deleteCloudReminder(cloudTask.id, authToken);
          await clearLocalDeletion(cloudTask.id);
          deletedCount++;
        } catch (_) {}
        continue;
      }

      if (localMap.containsKey(cloudTask.id)) {
        // Exists in both -> compare timestamps
        final localTask = localMap[cloudTask.id]!;
        final localTime = localTask.updatedAt ?? localTask.createdAt;
        final cloudTime = cloudTask.updatedAt ?? cloudTask.createdAt;

        if (cloudTime.isAfter(localTime)) {
          // Cloud is newer -> cloud wins locally
          resultMap[cloudTask.id] = cloudTask;
          downloaded++;
        } else if (localTime.isAfter(cloudTime)) {
          // Local is newer -> local wins, update cloud
          resultMap[localTask.id] = localTask;
          try {
            await updateCloudReminder(localTask, authToken);
            updated++;
          } catch (_) {}
        } else {
          // Timestamps identical -> keep local
          resultMap[localTask.id] = localTask;
        }
      } else {
        // Cloud only -> add locally
        resultMap[cloudTask.id] = cloudTask;
        downloaded++;
      }
    }

    // 2. Process local-only reminders
    for (final localTask in localTasks) {
      if (!cloudMap.containsKey(localTask.id) && !deletedIds.contains(localTask.id)) {
        // Local only and not deleted -> upload to cloud
        try {
          final uploadedTask = await createCloudReminder(localTask, authToken);
          resultMap[localTask.id] = uploadedTask ?? localTask;
          uploaded++;
        } catch (_) {
          // Keep local reminder even if upload fails
          resultMap[localTask.id] = localTask;
        }
      }
    }

    return SyncResult(
      mergedTasks: resultMap.values.toList(),
      success: true,
      uploadedCount: uploaded,
      downloadedCount: downloaded,
      updatedCount: updated,
      deletedCount: deletedCount,
    );
  }
}
