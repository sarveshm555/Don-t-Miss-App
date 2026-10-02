import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../core/constants/app_colors.dart';
import '../core/utils/date_time_utils.dart';
import '../models/recurrence.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../widgets/empty_state_view.dart';
import '../widgets/priority_badge.dart';

/// Screen displaying the user's completed reminders history.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  String _formatCompletedDateTime(DateTime? dateTime) {
    if (dateTime == null) return 'Completed';
    final dateFormat = DateFormat('d MMM yyyy, h:mm a');
    return dateFormat.format(dateTime);
  }

  String _formatDueDateTime(Task task) {
    final dateStr = DateTimeUtils.formatShortDate(task.dueDate);
    final timeStr = DateTimeUtils.formatTime(task.dueHour, task.dueMinute);
    return '$dateStr at $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Reminder History',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Consumer<TaskProvider>(
        builder: (context, provider, _) {
          final historyTasks = provider.historyTasks;

          if (historyTasks.isEmpty) {
            return const EmptyStateView(
              key: Key('history_empty_state'),
              icon: Icons.history_rounded,
              title: 'No completed reminders yet',
              message: 'Reminders you mark as completed will appear here.',
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            itemCount: historyTasks.length,
            itemBuilder: (context, index) {
              final task = historyTasks[index];
              return _buildHistoryCard(context, task, provider, isDark);
            },
          );
        },
      ),
    );
  }

  Widget _buildHistoryCard(
    BuildContext context,
    Task task,
    TaskProvider provider,
    bool isDark,
  ) {
    return Card(
      key: Key('history_task_card_${task.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6.0),
      color: isDark ? const Color(0xFF161F2E) : const Color(0xFFF8FAFC),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Checkmark indicator, Title, and Priority
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Completed indicator (no strike-through on title)
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimaryLight,
                        ),
                      ),
                      if (task.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          task.description,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondaryLight,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                PriorityBadge(priority: task.priority),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),

            // Metadata Row: Original Due Date & Completed Date
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                // Original Due Date
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 14,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondaryLight,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Due: ${_formatDueDateTime(task)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondaryLight,
                      ),
                    ),
                  ],
                ),

                // Completed Date & Time
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.task_alt_rounded,
                      size: 14,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Completed: ${_formatCompletedDateTime(task.completedAt)}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),

                // Recurrence Badge if recurring
                if (task.recurrence != Recurrence.none)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        task.recurrence.icon,
                        size: 14,
                        color: Colors.blueAccent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Repeats ${task.recurrence.label}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.blueAccent,
                        ),
                      ),
                    ],
                  ),
              ],
            ),

            const SizedBox(height: 8),

            // Action row: Reopen / Uncomplete button
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: Key('reopen_task_${task.id}'),
                onPressed: () async {
                  await provider.toggleTaskStatus(task.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Restored "${task.title}" to active reminders'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.undo_rounded, size: 16),
                label: const Text('Move to Active'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
