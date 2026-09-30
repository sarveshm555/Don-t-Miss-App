import 'package:flutter/material.dart';
import '../models/priority.dart';

/// A sleek badge widget displaying task priority with matching color and icon.
class PriorityBadge extends StatelessWidget {
  final Priority priority;
  final bool compact;

  const PriorityBadge({
    super.key,
    required this.priority,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: priority.backgroundColor,
          shape: BoxShape.circle,
        ),
        child: Icon(
          priority.icon,
          size: 14,
          color: priority.color,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: priority.backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: priority.color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            priority.icon,
            size: 14,
            color: priority.color,
          ),
          const SizedBox(width: 4),
          Text(
            priority.label,
            style: TextStyle(
              color: priority.color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
