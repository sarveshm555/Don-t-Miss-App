import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/constants/app_colors.dart';
import '../core/utils/date_time_utils.dart';
import '../models/ai_reminder_draft.dart';
import '../models/priority.dart';
import '../models/recurrence.dart';
import '../providers/auth_provider.dart';
import '../providers/task_provider.dart';
import '../screens/add_edit_task_screen.dart';
import '../services/action_dispatch_service.dart';
import '../services/ai_reminder_service.dart';
import '../services/voice_recording_service.dart';
import 'priority_badge.dart';

/// States representing the voice interaction workflow.
enum VoiceState {
  idle,
  recording,
  transcribing,
  transcriptionReady,
  error,
}

/// Modal bottom sheet allowing users to describe reminders in natural language
/// or via voice recording, preview one or multiple extracted structured drafts,
/// edit or remove individual reminders, and confirm them to be saved and scheduled.
class AiConfirmationSheet extends StatefulWidget {
  final AiReminderService aiService;
  final ActionDispatchService? actionDispatchService;
  final VoiceRecordingService? voiceRecordingService;

  const AiConfirmationSheet({
    super.key,
    this.aiService = const LocalAiReminderService(),
    this.actionDispatchService,
    this.voiceRecordingService,
  });

  /// Static helper to display the sheet from any screen.
  static Future<void> show(
    BuildContext context, {
    AiReminderService? aiService,
    ActionDispatchService? actionDispatchService,
    VoiceRecordingService? voiceRecordingService,
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
          voiceRecordingService: voiceRecordingService,
        ),
      ),
    );
  }

  @override
  State<AiConfirmationSheet> createState() => _AiConfirmationSheetState();
}

class _AiConfirmationSheetState extends State<AiConfirmationSheet> {
  late final TextEditingController _promptController;
  late final VoiceRecordingService _voiceRecorder;
  bool _ownsVoiceRecorder = false;

  bool _isProcessing = false;
  bool _isConfirming = false;
  bool _isRecording = false;
  VoiceState _voiceState = VoiceState.idle;
  Duration _recordingDuration = Duration.zero;
  StreamSubscription<Duration>? _durationSub;

  String? _errorMessage;
  List<AiReminderDraft> _drafts = [];
  final Set<String> _selectedDraftIds = {};

  AiReminderDraft? get _singleDraft =>
      _drafts.length == 1 ? _drafts.first : null;

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
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
    _promptController.dispose();
    if (_ownsVoiceRecorder) {
      _voiceRecorder.dispose();
    }
    super.dispose();
  }

  Future<void> _startVoiceRecording() async {
    if (_voiceState == VoiceState.recording ||
        _voiceState == VoiceState.transcribing ||
        _isProcessing) {
      return;
    }
    setState(() {
      _errorMessage = null;
      _voiceState = VoiceState.idle;
    });
    try {
      final hasPerm = await _voiceRecorder.hasPermission();
      if (!hasPerm) {
        setState(() {
          _voiceState = VoiceState.error;
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
        _voiceState = VoiceState.recording;
        _recordingDuration = Duration.zero;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _voiceState = VoiceState.error;
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
        _voiceState = VoiceState.idle;
        _recordingDuration = Duration.zero;
      });
    }
  }

  Future<void> _stopAndTranscribeVoiceRecording() async {
    if (_voiceState == VoiceState.transcribing) return;
    _durationSub?.cancel();
    setState(() {
      _isRecording = false;
      _isProcessing = true;
      _voiceState = VoiceState.transcribing;
      _errorMessage = null;
    });

    try {
      AuthProvider? auth;
      try {
        auth = Provider.of<AuthProvider>(context, listen: false);
      } catch (_) {}

      final audioBytes = await _voiceRecorder.stopRecording();
      if (!mounted) return;
      if (audioBytes == null || audioBytes.isEmpty) {
        setState(() {
          _isProcessing = false;
          _voiceState = VoiceState.error;
          _errorMessage = 'No audio recorded. Please try again.';
        });
        return;
      }

      final transcribedText = await widget.aiService.transcribeAudio(
        audioBytes,
        filename: _voiceRecorder.recordedFilename,
        language: 'en',
        authToken: auth?.token,
      );

      if (!mounted) return;
      setState(() {
        _promptController.text = transcribedText;
        _isProcessing = false;
        _voiceState = VoiceState.transcriptionReady;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _voiceState = VoiceState.error;
          _errorMessage = e is AiParsingException
              ? e.message
              : 'Voice transcription error: $e';
        });
      }
    }
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
      AuthProvider? auth;
      try {
        auth = Provider.of<AuthProvider>(context, listen: false);
      } catch (_) {}

      final drafts = await widget.aiService.parseMultiPrompt(
        prompt,
        authToken: auth?.token,
      );

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
        _errorMessage = 'Could not parse reminder. Please check your request.';
        _isProcessing = false;
      });
    }
  }

  Future<void> _confirmAndAddSingle() async {
    final draft = _singleDraft;
    if (draft == null || _isConfirming) return;

    setState(() {
      _isConfirming = true;
    });

    final task = draft.toTask();
    final provider = Provider.of<TaskProvider>(context, listen: false);

    AuthProvider? auth;
    try {
      auth = Provider.of<AuthProvider>(context, listen: false);
    } catch (_) {}

    final currentUser = auth?.currentUser;
    final authToken = auth?.token;

    // 1. Local persistence and notification scheduling
    await provider.addTask(task);

    // 2. Cloud persistence and action dispatch
    final dispatchService = widget.actionDispatchService ??
        const BackendActionDispatchService();

    final cloudSuccess = await dispatchService.dispatchConfirmedAction(
      draft: draft,
      reminderId: task.id,
      userId: currentUser?.id,
      userPhoneNumber: currentUser?.phoneNumber,
      authToken: authToken,
    );

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

  Future<void> _confirmSelectedBatch() async {
    if (_selectedDraftIds.isEmpty || _isConfirming) return;

    setState(() {
      _isConfirming = true;
    });

    final selectedDrafts = _drafts
        .where((d) =>
            _selectedDraftIds.contains(d.draftId) ||
            (d.id != null && _selectedDraftIds.contains(d.id)))
        .toList();
    final tasks = selectedDrafts.map((d) => d.toTask()).toList();
    final provider = Provider.of<TaskProvider>(context, listen: false);

    AuthProvider? auth;
    try {
      auth = Provider.of<AuthProvider>(context, listen: false);
    } catch (_) {}

    final authToken = auth?.token;

    // 1. Local batch persistence & notification scheduling
    await provider.addTasksBatch(tasks);

    // 2. Cloud persistence
    final dispatchService = widget.actionDispatchService ??
        const BackendActionDispatchService();

    BatchConfirmResult? batchResult;
    if (authToken != null && authToken.isNotEmpty) {
      try {
        batchResult = await dispatchService.dispatchBatchConfirmedActions(
          drafts: selectedDrafts,
          authToken: authToken,
        );
      } catch (_) {}
    }

    if (!mounted) return;
    Navigator.of(context).pop();

    final scheduledCount = tasks.length;
    final cloudCount = batchResult?.createdReminderIds.length ?? 0;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                cloudCount > 0
                    ? 'Confirmed & scheduled $scheduledCount reminders ($cloudCount synced to cloud).'
                    : 'Confirmed & scheduled $scheduledCount reminders locally.',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _editInForm() {
    final draft = _singleDraft;
    if (draft == null || _isConfirming) return;
    final task = draft.toTask();

    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddEditTaskScreen(
          initialDraft: task,
          initialAiDraft: draft,
          actionDispatchService: widget.actionDispatchService,
        ),
      ),
    );
  }

  void _resetDrafts() {
    if (_isConfirming) return;
    setState(() {
      _drafts.clear();
      _selectedDraftIds.clear();
      _errorMessage = null;
      _isConfirming = false;
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

  Future<void> _editIndividualDraft(AiReminderDraft draft) async {
    final titleCtrl = TextEditingController(text: draft.title);
    final descriptionCtrl = TextEditingController(text: draft.description);
    DateTime dueDate = draft.dueDate;
    TimeOfDay dueTime =
        TimeOfDay(hour: draft.dueHour, minute: draft.dueMinute);
    Priority priority = draft.priority;

    final updated = await showDialog<AiReminderDraft>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit Reminder', style: TextStyle(fontSize: 18)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Description / Context (Optional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_rounded),
                  title: Text(DateTimeUtils.formatDate(dueDate)),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: dueDate,
                      firstDate: DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) {
                      setDialogState(() => dueDate = picked);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.access_time_rounded),
                  title: Text(dueTime.format(ctx)),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: ctx,
                      initialTime: dueTime,
                    );
                    if (picked != null) {
                      setDialogState(() => dueTime = picked);
                    }
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<Priority>(
                  initialValue: priority,
                  decoration: const InputDecoration(
                    labelText: 'Priority',
                    border: OutlineInputBorder(),
                  ),
                  items: Priority.values.map((p) {
                    return DropdownMenuItem(
                      value: p,
                      child: Text(p.label),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => priority = val);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final trimmed = titleCtrl.text.trim();
                if (trimmed.isEmpty) return;
                Navigator.pop(
                  ctx,
                  draft.copyWith(
                    title: trimmed,
                    description: descriptionCtrl.text.trim(),
                    dueDate: dueDate,
                    dueHour: dueTime.hour,
                    dueMinute: dueTime.minute,
                    priority: priority,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (updated != null && mounted) {
      setState(() {
        final index = _drafts.indexWhere((d) =>
            (draft.id != null && d.id == draft.id) || d.draftId == draft.draftId);
        if (index != -1) {
          _drafts[index] = updated;
        }
      });
    }
  }

  String _formatTimer(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
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
                        'Type or speak multi-task reminders; AI extracts and organizes each.',
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

            if (_drafts.isEmpty) ...[
              // Prompt Input Field with Voice Controls
              if (_voiceState == VoiceState.recording || _isRecording) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.priorityHighBg,
                    borderRadius: BorderRadius.circular(16),
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
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Recording... ${_formatTimer(_recordingDuration)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppColors.error,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        key: const Key('cancel_recording_button'),
                        tooltip: 'Cancel Recording',
                        icon: const Icon(Icons.close_rounded, color: Colors.grey),
                        onPressed: _cancelVoiceRecording,
                      ),
                      IconButton(
                        key: const Key('stop_recording_button'),
                        tooltip: 'Stop & Transcribe',
                        icon: const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.primary,
                          size: 28,
                        ),
                        onPressed: _stopAndTranscribeVoiceRecording,
                      ),
                    ],
                  ),
                ),
              ] else if (_voiceState == VoiceState.transcribing) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                  ),
                  child: const Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: AppColors.primary,
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Transcribing your audio with AI...',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                if (_voiceState == VoiceState.transcriptionReady) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppColors.success.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mic_none_rounded, color: AppColors.success, size: 16),
                        SizedBox(width: 6),
                        Text(
                          'Voice transcribed! You can edit or generate drafts.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.success,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                TextField(
                  key: const Key('ai_prompt_input'),
                  controller: _promptController,
                  maxLines: 3,
                  minLines: 2,
                  onChanged: (_) {
                    if (_voiceState != VoiceState.idle) {
                      setState(() => _voiceState = VoiceState.idle);
                    }
                  },
                  decoration: InputDecoration(
                    hintText:
                        'e.g. Remind me tomorrow at 9 PM about Amazon interview, and grocery shopping Saturday at 10 AM',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    contentPadding: const EdgeInsets.all(16),
                    suffixIcon: IconButton(
                      key: const Key('voice_record_button'),
                      tooltip: 'Voice Input (English)',
                      icon: const Icon(
                        Icons.mic_none_rounded,
                        color: AppColors.primary,
                      ),
                      onPressed: _startVoiceRecording,
                    ),
                  ),
                ),
              ],
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
                    'Gemini hackathon today 10 AM and friends birthday tomorrow 9 AM',
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Error Message
              if (_errorMessage != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.priorityHighBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          color: AppColors.error, size: 16),
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
                key: const Key('generate_draft_button'),
                onPressed: (_isProcessing ||
                        _voiceState == VoiceState.recording ||
                        _voiceState == VoiceState.transcribing)
                    ? null
                    : _generateDraft,
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
            ] else if (_drafts.length == 1) ...[
              // Single Reminder Draft View (Exact backward compatibility)
              _buildDraftPreview(_drafts.first, isDark),
              const SizedBox(height: 20),

              // Confirm & Add (Primary Action)
              ElevatedButton.icon(
                onPressed: _isConfirming ? null : _confirmAndAddSingle,
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
                      onPressed: _isConfirming ? null : _resetDrafts,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Try Another'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Multi-Reminder Batch Checklist View
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

              // List of extracted reminder cards
              ..._drafts.map((draft) {
                final isSelected = _selectedDraftIds.contains(draft.id);
                return _buildMultiDraftCard(draft, isSelected, isDark);
              }),

              const SizedBox(height: 20),

              // Batch Confirm Button
              ElevatedButton.icon(
                key: const Key('confirm_batch_button'),
                onPressed: _selectedDraftIds.isEmpty || _isConfirming
                    ? null
                    : _confirmSelectedBatch,
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
                  _isConfirming
                      ? 'Confirming Batch...'
                      : 'Confirm Selected (${_selectedDraftIds.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 10),

              // Discard / Reset
              Center(
                child: TextButton.icon(
                  onPressed: _isConfirming ? null : _resetDrafts,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Discard & Try Another'),
                ),
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

  Widget _buildDraftPreview(AiReminderDraft draft, bool isDark) {
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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

  Widget _buildMultiDraftCard(
      AiReminderDraft draft, bool isSelected, bool isDark) {
    final dateStr = DateTimeUtils.formatDate(draft.dueDate);
    final timeStr = DateTimeUtils.formatTime(draft.dueHour, draft.dueMinute);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected
              ? AppColors.primary
              : (isDark ? AppColors.borderDark : AppColors.borderLight),
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: Checkbox(
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
            title: Text(
              draft.title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                decoration: isSelected ? null : TextDecoration.lineThrough,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const SizedBox(height: 6),
                Row(
                  children: [
                    PriorityBadge(priority: draft.priority),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.alarm_rounded,
                      size: 14,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondaryLight,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$dateStr $timeStr',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit reminder',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => _editIndividualDraft(draft),
                ),
                IconButton(
                  tooltip: 'Remove reminder',
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppColors.error),
                  onPressed: () => _removeDraft(draft.draftId),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
