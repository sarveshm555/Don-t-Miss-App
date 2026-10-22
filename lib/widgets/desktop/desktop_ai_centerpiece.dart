import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/date_time_utils.dart';
import '../../models/ai_reminder_draft.dart';
import '../../models/recurrence.dart';
import '../../services/ai_reminder_service.dart';
import '../../services/voice_recording_service.dart';
import '../priority_badge.dart';

/// Desktop AI reminder centerpiece allowing natural language & voice input,
/// displaying structured proposals, and providing explicit confirmation controls.
class DesktopAiCenterpiece extends StatefulWidget {
  final AiReminderService aiService;
  final ValueChanged<AiReminderDraft> onConfirmDraft;
  final ValueChanged<AiReminderDraft> onEditDraft;
  final ValueChanged<List<AiReminderDraft>>? onConfirmBatchDrafts;
  final VoiceRecordingService? voiceRecordingService;

  const DesktopAiCenterpiece({
    super.key,
    required this.aiService,
    required this.onConfirmDraft,
    required this.onEditDraft,
    this.onConfirmBatchDrafts,
    this.voiceRecordingService,
  });

  @override
  State<DesktopAiCenterpiece> createState() => _DesktopAiCenterpieceState();
}

class _DesktopAiCenterpieceState extends State<DesktopAiCenterpiece> {
  late final TextEditingController _controller;
  late final VoiceRecordingService _voiceRecorder;
  bool _ownsVoiceRecorder = false;

  bool _isProcessing = false;
  bool _isRecording = false;
  Duration _recordingDuration = Duration.zero;
  StreamSubscription<Duration>? _durationSub;

  String? _errorMessage;
  List<AiReminderDraft> _drafts = [];
  final Set<String> _selectedDraftIds = {};

  AiReminderDraft? get _draft =>
      _drafts.length == 1 ? _drafts.first : null;

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
    if (widget.voiceRecordingService != null) {
      _voiceRecorder = widget.voiceRecordingService!;
      _ownsVoiceRecorder = false;
    } else {
      _voiceRecorder = AppVoiceRecordingService();
      _ownsVoiceRecorder = true;
    }
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _controller.dispose();
    if (_ownsVoiceRecorder) {
      _voiceRecorder.dispose();
    }
    super.dispose();
  }

  Future<void> _startVoiceRecording() async {
    setState(() => _errorMessage = null);
    try {
      final hasPerm = await _voiceRecorder.hasPermission();
      if (!hasPerm) {
        setState(() {
          _errorMessage =
              'Microphone access is required for voice input. Please grant microphone permission.';
        });
        return;
      }

      await _voiceRecorder.startRecording();
      _durationSub?.cancel();
      _durationSub = _voiceRecorder.durationStream.listen((duration) {
        if (mounted) {
          setState(() => _recordingDuration = duration);
        }
      });

      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _errorMessage = 'Could not start voice recording: $e';
        });
      }
    }
  }

  Future<void> _cancelVoiceRecording() async {
    _durationSub?.cancel();
    await _voiceRecorder.cancelRecording();
    if (mounted) {
      setState(() {
        _isRecording = false;
        _recordingDuration = Duration.zero;
      });
    }
  }

  Future<void> _stopAndTranscribeVoiceRecording() async {
    _durationSub?.cancel();
    setState(() {
      _isRecording = false;
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final audioBytes = await _voiceRecorder.stopRecording();
      if (audioBytes == null || audioBytes.isEmpty) {
        if (mounted) {
          setState(() {
            _isProcessing = false;
            _errorMessage = 'No audio recorded. Please try again.';
          });
        }
        return;
      }

      final transcribedText = await widget.aiService.transcribeAudio(
        audioBytes,
        filename: _voiceRecorder.recordedFilename,
        language: 'en',
      );

      if (!mounted) return;
      setState(() {
        _controller.text = transcribedText;
        _isProcessing = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _errorMessage = 'Voice transcription error: $e';
        });
      }
    }
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
      final drafts = await widget.aiService.parseMultiPrompt(prompt);
      if (!mounted) return;
      setState(() {
        _drafts = List.from(drafts);
        _selectedDraftIds
          ..clear()
          ..addAll(drafts.map((d) => d.draftId));
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
      _drafts.clear();
      _selectedDraftIds.clear();
      _errorMessage = null;
      _controller.clear();
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedDraftIds.length == _drafts.length) {
        _selectedDraftIds.clear();
      } else {
        _selectedDraftIds
          ..clear()
          ..addAll(_drafts.map((d) => d.draftId));
      }
    });
  }

  void _removeDraft(String draftId) {
    setState(() {
      _drafts.removeWhere((d) => d.draftId == draftId);
      _selectedDraftIds.remove(draftId);
    });
  }

  void _confirmBatch() {
    final selected = _drafts
        .where((d) =>
            _selectedDraftIds.contains(d.draftId) ||
            (d.id != null && _selectedDraftIds.contains(d.id)))
        .toList();
    if (selected.isEmpty) return;

    if (widget.onConfirmBatchDrafts != null) {
      widget.onConfirmBatchDrafts!(selected);
    } else {
      for (final draft in selected) {
        widget.onConfirmDraft(draft);
      }
    }
    _clearDraft();
  }

  String _formatTimer(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
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
                if (_drafts.isNotEmpty)
                  TextButton.icon(
                    onPressed: _clearDraft,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('New Prompt', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),

          // 2. Natural Language & Voice Input Area
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _isRecording
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.priorityHighBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.error.withValues(alpha: 0.5),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.fiber_manual_record_rounded,
                          color: AppColors.error,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Listening... ${_formatTimer(_recordingDuration)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColors.error,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Cancel',
                          icon: const Icon(Icons.close_rounded, size: 20, color: Colors.grey),
                          onPressed: _cancelVoiceRecording,
                        ),
                        IconButton(
                          tooltip: 'Stop & Transcribe',
                          icon: const Icon(
                            Icons.check_circle_rounded,
                            color: AppColors.primary,
                            size: 26,
                          ),
                          onPressed: _stopAndTranscribeVoiceRecording,
                        ),
                      ],
                    ),
                  )
                : Row(
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
                                "Tell me what you want to remember (or use the mic to speak)...",
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
                            suffixIcon: IconButton(
                              key: const Key('desktop_ai_mic_button'),
                              tooltip: 'Voice Input (English)',
                              icon: const Icon(
                                Icons.mic_none_rounded,
                                color: AppColors.primary,
                              ),
                              onPressed: _startVoiceRecording,
                            ),
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
          if (_drafts.isEmpty)
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

          // 5. Single Structured AI Proposal Card (Review & Confirm)
          if (_drafts.length == 1) ...[
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
          ] else if (_drafts.length > 1) ...[
            // Multi-Draft Checklist View
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Extracted Reminders (${_selectedDraftIds.length}/${_drafts.length} selected)',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton(
                        onPressed: _toggleSelectAll,
                        child: Text(
                          _selectedDraftIds.length == _drafts.length
                              ? 'Deselect All'
                              : 'Select All',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final draft in _drafts) ...[
                    _buildDesktopMultiDraftCard(draft, isDark),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        key: const Key('desktop_ai_confirm_batch_button'),
                        onPressed: _selectedDraftIds.isEmpty ? null : _confirmBatch,
                        icon: const Icon(Icons.check_circle_outline_rounded, size: 16),
                        label: Text('Confirm Selected (${_selectedDraftIds.length})'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: _clearDraft,
                        child: const Text('Discard All'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDesktopMultiDraftCard(AiReminderDraft draft, bool isDark) {
    final isSelected = _selectedDraftIds.contains(draft.draftId) ||
        (draft.id != null && _selectedDraftIds.contains(draft.id));
    final dateStr = DateTimeUtils.formatDate(draft.dueDate);
    final timeStr = DateTimeUtils.formatTime(draft.dueHour, draft.dueMinute);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected
              ? AppColors.primary
              : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
        ),
      ),
      child: Row(
        children: [
          Checkbox(
            value: isSelected,
            onChanged: (val) {
              setState(() {
                if (val == true) {
                  _selectedDraftIds.add(draft.draftId);
                } else {
                  _selectedDraftIds.remove(draft.draftId);
                }
              });
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  draft.title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    decoration: isSelected ? null : TextDecoration.lineThrough,
                  ),
                ),
                if (draft.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    draft.description,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondaryLight,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: [
                    PriorityBadge(priority: draft.priority),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.alarm_rounded,
                      size: 13,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondaryLight,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$dateStr $timeStr',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.error),
            onPressed: () => _removeDraft(draft.draftId),
          ),
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
