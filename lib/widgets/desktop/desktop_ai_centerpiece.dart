import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/date_time_utils.dart';
import '../../models/ai_reminder_draft.dart';
import '../../models/recurrence.dart';
import '../../services/ai_reminder_service.dart';
import '../priority_badge.dart';

/// Desktop AI reminder centerpiece allowing natural language input,
/// displaying structured proposals, and providing explicit confirmation controls.
class DesktopAiCenterpiece extends StatefulWidget {
  final AiReminderService aiService;
  final ValueChanged<AiReminderDraft> onConfirmDraft;
  final ValueChanged<AiReminderDraft> onEditDraft;

  const DesktopAiCenterpiece({
    super.key,
    required this.aiService,
    required this.onConfirmDraft,
    required this.onEditDraft,
  });

  @override
  State<DesktopAiCenterpiece> createState() => _DesktopAiCenterpieceState();
}

class _DesktopAiCenterpieceState extends State<DesktopAiCenterpiece> {
  late final TextEditingController _controller;
  bool _isProcessing = false;
  String? _errorMessage;
  AiReminderDraft? _draft;

  static const List<String> _promptSuggestions = [
    'Amazon interview tomorrow at 9 PM',
    'Doctor appointment this Friday at 3:30 PM',
    'Team sprint sync next Monday at 10 AM weekly',
    'Pay credit card bill on the 25th 11 AM monthly',
  ];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _generateDraft([String? customPrompt]) async {
    final prompt = (customPrompt ?? _controller.text).trim();
    if (prompt.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter what you want to remember.';
      });
      return;
    }

    if (customPrompt != null) {
      _controller.text = customPrompt;
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
        _errorMessage = 'Failed to interpret prompt: $e';
        _isProcessing = false;
      });
    }
  }

  void _clearDraft() {
    setState(() {
      _draft = null;
      _errorMessage = null;
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Header Banner
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "AI Personal Action Agent",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "AI proposes. Human decides. Application executes.",
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : AppColors.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_draft != null)
                  TextButton.icon(
                    onPressed: _clearDraft,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('New Prompt', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),

          // 2. Natural Language Input Area
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('desktop_ai_prompt_field'),
                    controller: _controller,
                    enabled: !_isProcessing,
                    onSubmitted: (_) => _generateDraft(),
                    decoration: InputDecoration(
                      hintText:
                          "Tell me what you want to remember (e.g. 'Amazon interview tomorrow at 9 PM')...",
                      hintStyle: TextStyle(
                        fontSize: 14,
                        color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                      ),
                      filled: true,
                      fillColor: isDark
                          ? const Color(0xFF0F172A)
                          : const Color(0xFFF8FAFC),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFCBD5E1),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFCBD5E1),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppColors.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  key: const Key('desktop_ai_propose_button'),
                  onPressed: _isProcessing ? null : () => _generateDraft(),
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.arrow_upward_rounded, size: 18),
                  label: Text(_isProcessing ? 'Thinking...' : 'Propose'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 3. Error Banner (if any)
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: AppColors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(fontSize: 12, color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 4. Quick Suggestion Pills (when no draft is active)
          if (_draft == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Text(
                      'Examples:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondaryLight,
                      ),
                    ),
                    const SizedBox(width: 8),
                    for (final suggestion in _promptSuggestions)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text(suggestion),
                          labelStyle: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF475569),
                          ),
                          backgroundColor: isDark
                              ? const Color(0xFF0F172A)
                              : const Color(0xFFF1F5F9),
                          side: BorderSide(
                            color: isDark
                                ? const Color(0xFF334155)
                                : const Color(0xFFE2E8F0),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          onPressed: () => _generateDraft(suggestion),
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // 5. Structured AI Proposal Card (Review & Confirm)
          if (_draft != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0F172A)
                      : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.35),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Proposal Top Badge
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.rate_review_rounded,
                                  size: 14, color: AppColors.primary),
                              SizedBox(width: 6),
                              Text(
                                'AI PROPOSAL — AWAITING HUMAN CONFIRMATION',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primary,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        PriorityBadge(priority: _draft!.priority),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Title
                    Text(
                      _draft!.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_draft!.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        _draft!.description.trim(),
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondaryLight,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),

                    // Structured Fields Row
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _buildFieldChip(
                          icon: Icons.calendar_today_rounded,
                          label: DateTimeUtils.getRelativeTimeDescription(
                            _draft!.dueDate,
                            _draft!.dueHour,
                            _draft!.dueMinute,
                          ),
                          isDark: isDark,
                        ),
                        if (_draft!.recurrence != Recurrence.none)
                          _buildFieldChip(
                            icon: Icons.repeat_rounded,
                            label: _draft!.recurrence.label,
                            isDark: isDark,
                          ),
                        if (_draft!.url != null && _draft!.url!.trim().isNotEmpty)
                          _buildFieldChip(
                            icon: Icons.link_rounded,
                            label: _draft!.url!.trim(),
                            isDark: isDark,
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 14),

                    // Action Buttons (Confirm, Edit, Dismiss)
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            final draft = _draft!;
                            _clearDraft();
                            widget.onConfirmDraft(draft);
                          },
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Confirm & Save'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: () {
                            final draft = _draft!;
                            _clearDraft();
                            widget.onEditDraft(draft);
                          },
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: const Text('Edit in Form'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _clearDraft,
                          child: const Text('Dismiss', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFieldChip({
    required IconData icon,
    required String label,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
