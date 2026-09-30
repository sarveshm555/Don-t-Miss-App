import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/constants/app_colors.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../services/ai_reminder_service.dart';
import '../widgets/ai_confirmation_sheet.dart';
import '../widgets/empty_state_view.dart';
import '../widgets/task_card.dart';
import '../widgets/task_stats_card.dart';
import 'add_edit_task_screen.dart';

/// The main dashboard view displaying task statistics, filters, search, and list.
class HomeScreen extends StatefulWidget {
  final AiReminderService? aiService;

  const HomeScreen({
    super.key,
    this.aiService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch(TaskProvider provider) {
    _searchController.clear();
    provider.clearSearch();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.alarm_on_rounded,
                color: AppColors.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Don't Miss",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  "Stay on top of what matters",
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome_rounded),
            tooltip: 'AI Reminder Assistant',
            color: AppColors.primary,
            onPressed: () => _openAiAssistant(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Consumer<TaskProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          return CustomScrollView(
            slivers: [
              // Dashboard Stats Card
              SliverToBoxAdapter(
                child: TaskStatsCard(
                  totalCount: provider.totalCount,
                  pendingCount: provider.pendingCount,
                  highPriorityCount: provider.highPriorityCount,
                  completedCount: provider.completedCount,
                ),
              ),

              // Search Bar & Filter Chips Header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 8.0),
                  child: Column(
                    children: [
                      // Search TextField
                      TextField(
                        controller: _searchController,
                        onChanged: provider.setSearchQuery,
                        decoration: InputDecoration(
                          hintText: 'Search tasks, deadlines, keywords...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: provider.searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () => _clearSearch(provider),
                                )
                              : null,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Filter Choice Chips
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildFilterChip(
                              context: context,
                              label: 'All (${provider.totalCount})',
                              filter: TaskFilter.all,
                              selectedFilter: provider.selectedFilter,
                              onSelected: () =>
                                  provider.setFilter(TaskFilter.all),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Pending (${provider.pendingCount})',
                              filter: TaskFilter.pending,
                              selectedFilter: provider.selectedFilter,
                              onSelected: () =>
                                  provider.setFilter(TaskFilter.pending),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Today (${provider.todayCount})',
                              filter: TaskFilter.today,
                              selectedFilter: provider.selectedFilter,
                              onSelected: () =>
                                  provider.setFilter(TaskFilter.today),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Overdue (${provider.overdueCount})',
                              filter: TaskFilter.overdue,
                              selectedFilter: provider.selectedFilter,
                              isUrgent: provider.overdueCount > 0,
                              onSelected: () =>
                                  provider.setFilter(TaskFilter.overdue),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label:
                                  'High Priority (${provider.highPriorityCount})',
                              filter: TaskFilter.highPriority,
                              selectedFilter: provider.selectedFilter,
                              onSelected: () =>
                                  provider.setFilter(TaskFilter.highPriority),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Completed (${provider.completedCount})',
                              filter: TaskFilter.completed,
                              selectedFilter: provider.selectedFilter,
                              onSelected: () =>
                                  provider.setFilter(TaskFilter.completed),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Tasks List or Empty State
              if (provider.filteredTasks.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyStateView(
                    title: provider.searchQuery.isNotEmpty
                        ? 'No matching reminders'
                        : _getEmptyStateTitle(provider.selectedFilter),
                    message: provider.searchQuery.isNotEmpty
                        ? 'Try searching with different keywords.'
                        : _getEmptyStateMessage(provider.selectedFilter),
                    actionLabel: provider.searchQuery.isNotEmpty
                        ? 'Clear Search'
                        : 'Add Reminder',
                    actionIcon: provider.searchQuery.isNotEmpty
                        ? Icons.clear_rounded
                        : Icons.add,
                    onActionPressed: provider.searchQuery.isNotEmpty
                        ? () => _clearSearch(provider)
                        : () => _navigateToCreateTask(context),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 90, top: 4),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final task = provider.filteredTasks[index];
                        return TaskCard(
                          task: task,
                          onToggleComplete: (_) =>
                              provider.toggleTaskStatus(task.id),
                          onEdit: () => _navigateToEditTask(context, task),
                          onDelete: () => provider.deleteTask(task.id),
                        );
                      },
                      childCount: provider.filteredTasks.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _navigateToCreateTask(context),
        icon: const Icon(Icons.add_alert_rounded),
        label: const Text(
          'New Reminder',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  String _getEmptyStateTitle(TaskFilter filter) {
    switch (filter) {
      case TaskFilter.all:
        return 'All caught up!';
      case TaskFilter.pending:
        return 'No pending reminders';
      case TaskFilter.today:
        return 'Nothing due today';
      case TaskFilter.overdue:
        return 'No overdue reminders';
      case TaskFilter.highPriority:
        return 'No high priority reminders';
      case TaskFilter.completed:
        return 'No completed reminders';
    }
  }

  String _getEmptyStateMessage(TaskFilter filter) {
    switch (filter) {
      case TaskFilter.all:
        return 'No reminders in this view. Tap the button below to add one.';
      case TaskFilter.pending:
        return 'You have no pending reminders to complete.';
      case TaskFilter.today:
        return 'You have no reminders scheduled for today.';
      case TaskFilter.overdue:
        return 'Great job! None of your reminders are overdue.';
      case TaskFilter.highPriority:
        return 'No pending high-priority reminders at the moment.';
      case TaskFilter.completed:
        return 'Completed reminders will appear here.';
    }
  }

  Widget _buildFilterChip({
    required BuildContext context,
    required String label,
    required TaskFilter filter,
    required TaskFilter selectedFilter,
    required VoidCallback onSelected,
    bool isUrgent = false,
  }) {
    final isSelected = filter == selectedFilter;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Color activeColor = isUrgent ? AppColors.error : AppColors.primary;
    final Color unselectedBorder = isUrgent
        ? AppColors.error.withValues(alpha: 0.5)
        : (isDark ? AppColors.borderDark : AppColors.borderLight);
    final Color unselectedTextColor = isUrgent
        ? (isDark ? const Color(0xFFF87171) : AppColors.error)
        : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight);
    final Color? backgroundColor = (!isSelected && isUrgent)
        ? (isDark
            ? AppColors.error.withValues(alpha: 0.15)
            : AppColors.priorityHighBg)
        : null;

    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      selectedColor: activeColor,
      backgroundColor: backgroundColor,
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : unselectedTextColor,
        fontWeight: (isSelected || isUrgent) ? FontWeight.bold : FontWeight.w500,
        fontSize: 12,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isSelected ? activeColor : unselectedBorder,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    );
  }

  void _navigateToCreateTask(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const AddEditTaskScreen(),
      ),
    );
  }

  void _navigateToEditTask(BuildContext context, Task task) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddEditTaskScreen(taskToEdit: task),
      ),
    );
  }

  void _openAiAssistant(BuildContext context) {
    AiConfirmationSheet.show(
      context,
      aiService: widget.aiService,
    );
  }
}
