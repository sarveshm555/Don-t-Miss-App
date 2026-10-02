import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../core/constants/app_colors.dart';
import '../models/ai_reminder_draft.dart';
import '../models/task.dart';
import '../providers/auth_provider.dart';
import '../providers/task_provider.dart';
import '../services/action_dispatch_service.dart';
import '../services/ai_reminder_service.dart';
import '../widgets/ai_confirmation_sheet.dart';
import '../widgets/desktop/desktop_ai_centerpiece.dart';
import '../widgets/desktop/desktop_sidebar.dart';
import '../widgets/desktop/desktop_task_card.dart';
import '../widgets/empty_state_view.dart';
import '../widgets/priority_badge.dart';
import '../widgets/task_card.dart';
import '../widgets/task_stats_card.dart';
import 'add_edit_task_screen.dart';
import 'history_screen.dart';
import 'profile_screen.dart';

/// The main dashboard view displaying task statistics, filters, search, and list.
/// Supports desktop-first layout on wide screens with graceful mobile fallback.
class HomeScreen extends StatefulWidget {
  final AiReminderService? aiService;
  final ActionDispatchService? actionDispatchService;

  const HomeScreen({
    super.key,
    this.aiService,
    this.actionDispatchService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _searchController;
  int _selectedNavIndex = 0;

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

  Future<void> _handleConfirmAiDraft(
      BuildContext context, AiReminderDraft draft, TaskProvider provider) async {
    final auth = context.read<AuthProvider>();
    final task = draft.toTask();
    await provider.addTask(task);

    if (widget.actionDispatchService != null) {
      try {
        await widget.actionDispatchService!.dispatchConfirmedAction(
          draft: draft,
          reminderId: task.id,
          userId: auth.currentUser?.id,
          userPhoneNumber: auth.currentUser?.phoneNumber,
          authToken: auth.token,
        );
      } catch (_) {}
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Reminder "${task.title}" confirmed & saved.'),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _handleEditAiDraft(BuildContext context, AiReminderDraft draft) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddEditTaskScreen(
          initialAiDraft: draft,
          actionDispatchService: widget.actionDispatchService,
        ),
      ),
    );
  }

  Future<void> _handleSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<AuthProvider>().signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 850;

    return Consumer<TaskProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (isDesktop) {
          return _buildDesktopLayout(context, provider);
        }

        return _buildMobileLayout(context, provider);
      },
    );
  }

  // =========================================================================
  // DESKTOP LAYOUT (>= 850px)
  // =========================================================================

  Widget _buildDesktopLayout(BuildContext context, TaskProvider provider) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0B1120) : const Color(0xFFF8FAFC),
      body: Row(
        children: [
          // 1. Fixed Left Sidebar
          DesktopSidebar(
            selectedIndex: _selectedNavIndex,
            onItemSelected: (idx) => setState(() => _selectedNavIndex = idx),
            pendingCount: provider.pendingCount,
            historyCount: provider.completedCount,
            onNewReminder: () => _navigateToCreateTask(context),
            onOpenAi: () => _openAiAssistant(context),
            onSignOut: () => _handleSignOut(context),
          ),

          // 2. Main Content Area
          Expanded(
            child: Column(
              children: [
                // Top Header Bar
                _buildDesktopTopBar(context, provider, isDark),

                // Main Scrollable Area
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 36, vertical: 24),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1140),
                        child: _buildDesktopContent(context, provider, isDark),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopTopBar(
      BuildContext context, TaskProvider provider, bool isDark) {
    String pageTitle = 'Dashboard';
    String pageSubtitle = 'AI proposes. Human decides. Application executes.';

    if (_selectedNavIndex == 1) {
      pageTitle = 'Active Reminders';
      pageSubtitle = 'Manage your scheduled tasks, deadlines, and notifications.';
    } else if (_selectedNavIndex == 2) {
      pageTitle = 'Reminder History';
      pageSubtitle =
          'Archived completed reminders with original timestamps & recurrence.';
    } else if (_selectedNavIndex == 3) {
      pageTitle = 'User Profile';
      pageSubtitle = 'Account settings, statistics, and cloud synchronization.';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // Title & Description
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pageTitle,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  pageSubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : AppColors.textSecondaryLight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),

          // Search Field
          SizedBox(
            width: 300,
            height: 40,
            child: TextField(
              controller: _searchController,
              onChanged: provider.setSearchQuery,
              decoration: InputDecoration(
                hintText: 'Search tasks, deadlines, keywords...',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                ),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: provider.searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () => _clearSearch(provider),
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                filled: true,
                fillColor: isDark
                    ? const Color(0xFF1E293B)
                    : const Color(0xFFF1F5F9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // AI Sparkle Assistant
          IconButton(
            icon: const Icon(Icons.auto_awesome_rounded),
            tooltip: 'AI Reminder Assistant',
            color: AppColors.primary,
            onPressed: () => _openAiAssistant(context),
          ),

          // History Button (Accessible by test finder)
          IconButton(
            key: const Key('home_history_action_button'),
            icon: const Icon(Icons.history_rounded),
            tooltip: 'Reminder History',
            color: AppColors.primary,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
          ),

          // Account Menu Button (Accessible by test finder)
          const _AccountActionButton(),
        ],
      ),
    );
  }

  Widget _buildDesktopContent(
      BuildContext context, TaskProvider provider, bool isDark) {
    if (_selectedNavIndex == 2) {
      return _buildDesktopHistoryView(context, provider, isDark);
    }

    if (_selectedNavIndex == 3) {
      return _buildDesktopProfileView(context, isDark);
    }

    // Default: Dashboard (0) or Active Reminders (1)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Prominent AI Reminder Centerpiece
        DesktopAiCenterpiece(
          aiService: widget.aiService ?? const LocalAiReminderService(),
          onConfirmDraft: (draft) =>
              _handleConfirmAiDraft(context, draft, provider),
          onEditDraft: (draft) => _handleEditAiDraft(context, draft),
        ),
        const SizedBox(height: 24),

        // 2. Stats Metric Cards (on Dashboard)
        if (_selectedNavIndex == 0) ...[
          _buildDesktopStatsRow(provider, isDark),
          const SizedBox(height: 24),
        ],

        // 3. Section Header & Filter Choice Chips
        Row(
          children: [
            const Text(
              'Reminders',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterChip(
                      context: context,
                      label: 'All (${provider.totalCount})',
                      filter: TaskFilter.all,
                      selectedFilter: provider.selectedFilter,
                      onSelected: () => provider.setFilter(TaskFilter.all),
                    ),
                    const SizedBox(width: 8),
                    _buildFilterChip(
                      context: context,
                      label: 'Pending (${provider.pendingCount})',
                      filter: TaskFilter.pending,
                      selectedFilter: provider.selectedFilter,
                      onSelected: () => provider.setFilter(TaskFilter.pending),
                    ),
                    const SizedBox(width: 8),
                    _buildFilterChip(
                      context: context,
                      label: 'Today (${provider.todayCount})',
                      filter: TaskFilter.today,
                      selectedFilter: provider.selectedFilter,
                      onSelected: () => provider.setFilter(TaskFilter.today),
                    ),
                    const SizedBox(width: 8),
                    _buildFilterChip(
                      context: context,
                      label: 'Overdue (${provider.overdueCount})',
                      filter: TaskFilter.overdue,
                      selectedFilter: provider.selectedFilter,
                      isUrgent: provider.overdueCount > 0,
                      onSelected: () => provider.setFilter(TaskFilter.overdue),
                    ),
                    const SizedBox(width: 8),
                    _buildFilterChip(
                      context: context,
                      label: 'High Priority (${provider.highPriorityCount})',
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
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 4. Reminders List or Empty State
        if (provider.filteredTasks.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 40),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF161F30) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              ),
            ),
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
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: provider.filteredTasks.length,
            itemBuilder: (context, index) {
              final task = provider.filteredTasks[index];
              return DesktopTaskCard(
                key: ValueKey(task.id),
                task: task,
                onToggleComplete: (_) => provider.toggleTaskStatus(task.id),
                onEdit: () => _navigateToEditTask(context, task),
                onDelete: () => provider.deleteTask(task.id),
              );
            },
          ),
      ],
    );
  }

  Widget _buildDesktopStatsRow(TaskProvider provider, bool isDark) {
    return Row(
      children: [
        Expanded(
          child: _buildStatTile(
            label: 'Total Reminders',
            value: provider.totalCount.toString(),
            icon: Icons.list_alt_rounded,
            color: AppColors.primary,
            isDark: isDark,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatTile(
            label: 'Pending',
            value: provider.pendingCount.toString(),
            icon: Icons.pending_actions_rounded,
            color: const Color(0xFF38BDF8),
            isDark: isDark,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatTile(
            label: 'Due Today',
            value: provider.todayCount.toString(),
            icon: Icons.today_rounded,
            color: AppColors.primaryLight,
            isDark: isDark,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatTile(
            label: 'Overdue',
            value: provider.overdueCount.toString(),
            icon: Icons.warning_amber_rounded,
            color: AppColors.error,
            isDark: isDark,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatTile(
            label: 'High Priority',
            value: provider.highPriorityCount.toString(),
            icon: Icons.priority_high_rounded,
            color: AppColors.priorityMedium,
            isDark: isDark,
          ),
        ),
      ],
    );
  }

  Widget _buildStatTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondaryLight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopHistoryView(
      BuildContext context, TaskProvider provider, bool isDark) {
    final historyTasks = provider.historyTasks;

    if (historyTasks.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 40),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF161F30) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          ),
        ),
        child: const EmptyStateView(
          key: Key('history_empty_state'),
          icon: Icons.history_rounded,
          title: 'No completed reminders yet',
          message: 'Reminders you mark as completed will appear here.',
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Completed Reminders (${historyTasks.length})',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 14),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: historyTasks.length,
          itemBuilder: (context, index) {
            final task = historyTasks[index];
            final completedDateStr = task.completedAt != null
                ? DateFormat('d MMM yyyy, h:mm a').format(task.completedAt!)
                : 'Completed';

            return Container(
              key: Key('history_task_card_${task.id}'),
              margin: const EdgeInsets.symmetric(vertical: 5),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF161F30) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: AppColors.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                task.title,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            PriorityBadge(priority: task.priority),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.done_all_rounded,
                                size: 12,
                                color: isDark
                                    ? AppColors.textSecondaryDark
                                    : AppColors.textSecondaryLight),
                            const SizedBox(width: 4),
                            Text(
                              completedDateStr,
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? AppColors.textSecondaryDark
                                    : AppColors.textSecondaryLight,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    key: Key('history_task_reopen_button_${task.id}'),
                    icon: const Icon(Icons.replay_rounded, size: 18),
                    tooltip: 'Move back to active',
                    color: AppColors.primary,
                    onPressed: () => provider.toggleTaskStatus(task.id),
                  ),
                  IconButton(
                    key: Key('history_task_delete_button_${task.id}'),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Delete permanently',
                    color: AppColors.error,
                    onPressed: () => provider.deleteTask(task.id),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildDesktopProfileView(BuildContext context, bool isDark) {
    final auth = context.watch<AuthProvider>();
    final taskProvider = context.watch<TaskProvider>();
    final user = auth.currentUser;
    final userName = (user?.name != null && user!.name.trim().isNotEmpty)
        ? user.name.trim()
        : 'User';
    final userPhone =
        (user?.phoneNumber != null && user!.phoneNumber.trim().isNotEmpty)
            ? user.phoneNumber.trim()
            : 'No phone number';
    final joinDate = user?.createdAt != null
        ? DateFormat('d MMMM yyyy').format(user!.createdAt)
        : null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // User Card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF161F30) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: AppColors.primary.withValues(alpha: 0.15),
                    child: Text(
                      userName.isNotEmpty ? userName[0].toUpperCase() : 'U',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userName,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          userPhone,
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondaryLight,
                          ),
                        ),
                        if (joinDate != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Member since $joinDate',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppColors.textSecondaryDark
                                  : AppColors.textSecondaryLight,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Statistics Grid
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF161F30) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Productivity Statistics',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildProfileStat(
                          label: 'Total Tracked',
                          value: (taskProvider.pendingCount +
                                  taskProvider.completedCount)
                              .toString(),
                          isDark: isDark,
                        ),
                      ),
                      Expanded(
                        child: _buildProfileStat(
                          label: 'Active Tasks',
                          value: taskProvider.pendingCount.toString(),
                          isDark: isDark,
                        ),
                      ),
                      Expanded(
                        child: _buildProfileStat(
                          label: 'Completed',
                          value: taskProvider.completedCount.toString(),
                          isDark: isDark,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Sign Out Button
            ElevatedButton.icon(
              onPressed: () => _handleSignOut(context),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Sign Out'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileStat({
    required String label,
    required String value,
    required bool isDark,
  }) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isDark
                ? AppColors.textSecondaryDark
                : AppColors.textSecondaryLight,
          ),
        ),
      ],
    );
  }

  // =========================================================================
  // MOBILE LAYOUT (< 850px)
  // =========================================================================

  Widget _buildMobileLayout(BuildContext context, TaskProvider provider) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_logo.png',
                width: 36,
                height: 36,
                fit: BoxFit.contain,
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
          IconButton(
            key: const Key('home_history_action_button'),
            icon: const Icon(Icons.history_rounded),
            tooltip: 'Reminder History',
            color: AppColors.primary,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
          ),
          const _AccountActionButton(),
          const SizedBox(width: 4),
        ],
      ),
      body: CustomScrollView(
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
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

/// Displays user profile details and provides sign-out action in the app bar.
class _AccountActionButton extends StatelessWidget {
  const _AccountActionButton();

  @override
  Widget build(BuildContext context) {
    AuthProvider? auth;
    try {
      auth = Provider.of<AuthProvider>(context);
    } catch (_) {
      auth = null;
    }

    if (auth == null) {
      return const SizedBox.shrink();
    }

    final user = auth.currentUser;
    final userName = (user?.name != null && user!.name.trim().isNotEmpty)
        ? user.name.trim()
        : 'User';
    final userPhone =
        (user?.phoneNumber != null && user!.phoneNumber.trim().isNotEmpty)
            ? user.phoneNumber.trim()
            : '';

    return PopupMenuButton<String>(
      key: const Key('home_account_menu_button'),
      icon: const Icon(Icons.account_circle_outlined, color: AppColors.primary),
      tooltip: 'Account',
      onSelected: (value) async {
        if (value == 'profile') {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ProfileScreen()),
          );
        } else if (value == 'history') {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HistoryScreen()),
          );
        } else if (value == 'sign_out') {
          await context.read<AuthProvider>().signOut();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                userName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: AppColors.textPrimaryLight,
                ),
              ),
              if (userPhone.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  userPhone,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
              ],
              const Divider(),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'profile',
          child: Row(
            children: [
              Icon(Icons.person_outline_rounded, color: AppColors.primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Profile',
                style: TextStyle(
                  color: AppColors.textPrimaryLight,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'history',
          child: Row(
            children: [
              Icon(Icons.history_rounded, color: AppColors.primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Reminder History',
                style: TextStyle(
                  color: AppColors.textPrimaryLight,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'sign_out',
          child: Row(
            children: [
              Icon(Icons.logout, color: AppColors.error, size: 20),
              SizedBox(width: 8),
              Text(
                'Sign Out',
                style: TextStyle(
                  color: AppColors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
