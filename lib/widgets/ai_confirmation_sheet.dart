import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/constants/app_colors.dart';
import '../core/utils/date_time_utils.dart';
import '../models/ai_reminder_draft.dart';
import '../models/recurrence.dart';
import '../providers/task_provider.dart';
import '../screens/add_edit_task_screen.dart';
import '../services/action_dispatch_service.dart';
import '../services/ai_reminder_service.dart';
import 'priority_badge.dart';

/// Modal bottom sheet allowing users to describe reminders in natural language,
/// preview the extracted structured fields, and explicitly confirm or edit before saving.
class AiConfirmationSheet extends StatefulWidget {
  final AiReminderService aiService;
  final ActionDispatchService? actionDispatchService;

  const AiConfirmationSheet({
    super.key,
    this.aiService = const LocalAiReminderService(),
    this.actionDispatchService,
  });

  /// Static helper to display the sheet from any screen.
  static Future<void> show(
    BuildContext context, {
    AiReminderService? aiService,
    ActionDispatchService? actionDispatchService,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: AiConfirmationSheet(
          aiService: aiService ?? const LocalAiReminderService(),
          actionDispatchService: actionDispatchService,
        ),
      ),
    );
  }

  @override
  State<AiConfirmationSheet> createState() => _AiConfirmationSheetState();
}

class _AiConfirmationSheetState extends State<AiConfirmationSheet> {
  late final TextEditingController _promptController;
  bool _isProcessing = false;
  bool _isConfirming = false;
  String? _errorMessage;
  AiReminderDraft? _draft;

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _generateDraft() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a reminder prompt.';
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final draft = await widget.aiService.parsePrompt(prompt);
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _isProcessing = false;
      });
    } on AiParsingException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _isProcessing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not parse reminder. Please check your request.';
        _isProcessing = false;
      });
    }
  }

  Future<void> _confirmAndAdd() async {
    if (_draft == null || _isConfirming) return;

    setState(() {
      _isConfirming = true;
    });

    final draft = _draft!;
    final task = draft.toTask();
    final provider = Provider.of<TaskProvider>(context, listen: false);

    // 1. Local persistence and notification scheduling
    await provider.addTask(task);

    // 2. Cloud persistence and external action routing for all confirmed AI reminders
    final dispatchService = widget.actionDispatchService ??
        const BackendActionDispatchService();
    final cloudSuccess =
        await dispatchService.dispatchConfirmedAction(draft: draft);

    if (!mounted) return;
    Navigator.of(context).pop();

    if (cloudSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Scheduled reminder: "${task.title}"',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Scheduled locally: "${task.title}" (cloud sync offline)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _editInForm() {
    if (_draft == null || _isConfirming) return;
    final task = _draft!.toTask();

    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddEditTaskScreen(initialDraft: task),
      ),
    );
  }

  void _resetDraft() {
    if (_isConfirming) return;
    setState(() {
      _draft = null;
      _errorMessage = null;
      _isConfirming = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Sheet Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? AppColors.borderDark : AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColors.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI Reminder Assistant',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Type naturally; AI extracts schedule, priority & details.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (_draft == null) ...[
              // Prompt Input Field
              TextField(
                key: const Key('ai_prompt_input'),
                controller: _promptController,
                maxLines: 3,
                minLines: 2,
                decoration: InputDecoration(
                  hintText:
                      'e.g. Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare questions.',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  contentPadding: const EdgeInsets.all(16),
                  suffixIcon: IconButton(
                    tooltip: 'Voice Input (English)',
                    icon: const Icon(
                      Icons.mic_none_rounded,
                      color: AppColors.primary,
                    ),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'English speech-to-text input prepared. Connects directly to prompt field.',
                          ),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Example Prompt Suggestions
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _buildPromptChip(
                    'Amazon interview tomorrow at 9 PM',
                  ),
                  _buildPromptChip(
                    'Doctor appointment today at 10:30 AM',
                  ),
                  _buildPromptChip(
                    'Pay electric bill tomorrow at 15:00',
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Error Message
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.priorityHighBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, color: AppColors.error, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: AppColors.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Generate Button
              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _generateDraft,
                icon: _isProcessing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(
                  _isProcessing ? 'Analyzing...' : 'Generate Reminder Draft',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ] else ...[
              // Structured Reminder Preview Card
              _buildDraftPreview(isDark),
              const SizedBox(height: 20),

              // Confirm & Add (Primary Action)
              ElevatedButton.icon(
                onPressed: _isConfirming ? null : _confirmAndAdd,
                icon: _isConfirming
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle_outline_rounded, size: 18),
                label: Text(
                  _isConfirming ? 'Confirming & Syncing...' : 'Confirm & Add',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 10),

              // Secondary Actions: Edit in Form & Discard
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isConfirming ? null : _editInForm,
                      icon: const Icon(Icons.edit_note_rounded, size: 18),
                      label: const Text('Edit in Form'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _isConfirming ? null : _resetDraft,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Try Another'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPromptChip(String text) {
    return ActionChip(
      label: Text(
        text,
        style: const TextStyle(fontSize: 11),
      ),
      onPressed: () {
        _promptController.text = text;
      },
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildDraftPreview(bool isDark) {
    final draft = _draft!;
    final dateStr = DateTimeUtils.formatDate(draft.dueDate);
    final timeStr = DateTimeUtils.formatTime(draft.dueHour, draft.dueMinute);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PriorityBadge(priority: draft.priority),
              if (draft.recurrence != Recurrence.none) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.secondary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.repeat_rounded,
                        size: 12,
                        color: AppColors.secondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        draft.recurrence.label,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppColors.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (draft.channels.contains('whatsapp')) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF25D366).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 12,
                        color: Color(0xFF25D366),
                      ),
                      SizedBox(width: 4),
                      Text(
                        'WhatsApp',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF25D366),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),

          // Title
          Text(
            draft.title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (draft.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              draft.description,
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
              ),
            ),
          ],
          const SizedBox(height: 12),

          // Date & Time Row
          Row(
            children: [
              const Icon(
                Icons.alarm_rounded,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '$dateStr at $timeStr',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),

          // AI Insight / Reasoning
          if (draft.reasoning != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('💡 ', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Text(
                      draft.reasoning!,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondaryLight,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
