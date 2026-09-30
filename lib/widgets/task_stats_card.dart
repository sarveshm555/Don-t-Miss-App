import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

/// A dashboard overview banner summarizing pending, high priority, and completed task counts.
class TaskStatsCard extends StatelessWidget {
  final int totalCount;
  final int pendingCount;
  final int highPriorityCount;
  final int completedCount;

  const TaskStatsCard({
    super.key,
    required this.totalCount,
    required this.pendingCount,
    required this.highPriorityCount,
    required this.completedCount,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF312E81), const Color(0xFF1E1B4B)]
              : [AppColors.primary, const Color(0xFF4338CA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Focus Dashboard',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$totalCount Total',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildStatItem(
                context: context,
                label: 'Pending',
                count: pendingCount,
                icon: Icons.hourglass_top_rounded,
                iconColor: Colors.amberAccent,
              ),
              _buildDivider(),
              _buildStatItem(
                context: context,
                label: 'High Priority',
                count: highPriorityCount,
                icon: Icons.priority_high_rounded,
                iconColor: const Color(0xFFF87171),
              ),
              _buildDivider(),
              _buildStatItem(
                context: context,
                label: 'Done',
                count: completedCount,
                icon: Icons.check_circle_outline_rounded,
                iconColor: const Color(0xFF34D399),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 36,
      width: 1,
      color: Colors.white.withValues(alpha: 0.2),
    );
  }

  Widget _buildStatItem({
    required BuildContext context,
    required String label,
    required int count,
    required IconData icon,
    required Color iconColor,
  }) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
