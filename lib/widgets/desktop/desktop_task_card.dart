import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/date_time_utils.dart';
import '../../models/recurrence.dart';
import '../../models/task.dart';
import '../../services/url_launcher_service.dart';
import '../priority_badge.dart';

/// Clean desktop reminder card with hover feedback and structured hierarchy.
class DesktopTaskCard extends StatefulWidget {
  final Task task;
  final ValueChanged<bool?> onToggleComplete;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const DesktopTaskCard({
    super.key,
    required this.task,
    required this.onToggleComplete,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<DesktopTaskCard> createState() => _DesktopTaskCardState();
}

class _DesktopTaskCardState extends State<DesktopTaskCard> {
  bool _isHovered = false;

  Future<void> _handleDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Reminder'),
        content: Text('Are you sure you want to delete "${widget.task.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final task = widget.task;
    final isOverdue = task.isOverdue;

    final cardBg = task.isCompleted
        ? (isDark ? const Color(0xFF131D2D) : const Color(0xFFF1F5F9))
        : (isDark
            ? (_isHovered ? const Color(0xFF1E293B) : const Color(0xFF161F30))
            : (_isHovered ? const Color(0xFFF8FAFC) : Colors.white));

    final borderColor = isOverdue && !task.isCompleted
        ? AppColors.error.withValues(alpha: 0.4)
        : (isDark
            ? (_isHovered ? const Color(0xFF475569) : const Color(0xFF334155))
            : (_isHovered ? const Color(0xFFCBD5E1) : const Color(0xFFE2E8F0)));

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: 1.2),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onEdit,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Completion Checkbox
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: Transform.scale(
                    scale: 1.05,
                    child: Checkbox(
                      value: task.isCompleted,
                      onChanged: widget.onToggleComplete,
                      activeColor: AppColors.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                ),

                // 2. Main Details (Title, Description, Metadata Badges)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title & Badges
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              task.title,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                decoration: task.isCompleted
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: task.isCompleted
                                    ? (isDark
                                        ? AppColors.textSecondaryDark
                                        : AppColors.textSecondaryLight)
                                    : (isDark
                                        ? AppColors.textPrimaryDark
                                        : AppColors.textPrimaryLight),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          PriorityBadge(priority: task.priority),
                        ],
                      ),

                      // Description
                      if (task.description.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          task.description.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondaryLight,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),

                      // Metadata Tags Row (Date, Recurrence, URL, Notifications)
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          // Due Date Badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isOverdue && !task.isCompleted
                                  ? AppColors.error.withValues(alpha: 0.12)
                                  : (isDark
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFF1F5F9)),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.calendar_today_rounded,
                                  size: 12,
                                  color: isOverdue && !task.isCompleted
                                      ? AppColors.error
                                      : (isDark
                                          ? const Color(0xFF38BDF8)
                                          : AppColors.primary),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  DateTimeUtils.getRelativeTimeDescription(
                                      task.dueDate, task.dueHour, task.dueMinute),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: isOverdue && !task.isCompleted
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                    color: isOverdue && !task.isCompleted
                                        ? AppColors.error
                                        : (isDark
                                            ? Colors.white
                                            : AppColors.textPrimaryLight),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Recurrence
                          if (task.recurrence != Recurrence.none)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF0F172A)
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.repeat_rounded,
                                      size: 12,
                                      color: isDark
                                          ? AppColors.textSecondaryDark
                                          : AppColors.textSecondaryLight),
                                  const SizedBox(width: 4),
                                  Text(
                                    task.recurrence.label,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? AppColors.textSecondaryDark
                                          : AppColors.textSecondaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          // Notification bell indicator
                          if (task.isNotificationEnabled)
                            Tooltip(
                              message: 'Device alarm scheduled',
                              child: Icon(
                                Icons.notifications_active_rounded,
                                size: 14,
                                color: isDark
                                    ? const Color(0xFF38BDF8)
                                    : AppColors.primary,
                              ),
                            ),

                          // URL Link Launcher
                          if (task.url != null && task.url!.trim().isNotEmpty)
                            InkWell(
                              onTap: () => UrlLauncherService.launchLink(task.url!),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppColors.primary
                                      .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.link_rounded,
                                        size: 12, color: AppColors.primary),
                                    SizedBox(width: 4),
                                    Text(
                                      'Open Link',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 12),

                // 3. Quick Action Buttons (Edit & Delete)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: 'Edit reminder',
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondaryLight,
                      onPressed: widget.onEdit,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Delete reminder',
                      color: AppColors.error,
                      onPressed: () => _handleDelete(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
