import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../core/constants/app_colors.dart';
import '../core/utils/date_time_utils.dart';
import '../models/priority.dart';
import '../models/recurrence.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../services/notification_service.dart';

/// Form screen used to either create a new reminder or edit an existing one.
class AddEditTaskScreen extends StatefulWidget {
  final Task? taskToEdit;
  final Task? initialDraft;

  const AddEditTaskScreen({
    super.key,
    this.taskToEdit,
    this.initialDraft,
  });

  @override
  State<AddEditTaskScreen> createState() => _AddEditTaskScreenState();
}

class _AddEditTaskScreenState extends State<AddEditTaskScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  late TextEditingController _urlController;

  late DateTime _selectedDate;
  late TimeOfDay _selectedTime;
  late Priority _selectedPriority;
  late Recurrence _selectedRecurrence;
  late bool _isNotificationEnabled;

  bool get _isEditing => widget.taskToEdit != null;

  @override
  void initState() {
    super.initState();
    final task = widget.taskToEdit ?? widget.initialDraft;

    _titleController = TextEditingController(text: task?.title ?? '');
    _descriptionController =
        TextEditingController(text: task?.description ?? '');
    _urlController = TextEditingController(text: task?.url ?? '');

    final now = DateTime.now();
    _selectedDate = task?.dueDate ?? now;
    _selectedTime = task != null
        ? TimeOfDay(hour: task.dueHour, minute: task.dueMinute)
        : TimeOfDay(hour: (now.hour + 1) % 24, minute: 0);

    _selectedPriority = task?.priority ?? Priority.medium;
    _selectedRecurrence = task?.recurrence ?? Recurrence.none;
    _isNotificationEnabled = task?.isNotificationEnabled ?? true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final firstDate = DateTime(now.year - 1);
    final lastDate = DateTime(now.year + 10);

    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: firstDate,
      lastDate: lastDate,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppColors.primary,
                ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppColors.primary,
                ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedTime = picked;
      });
    }
  }

  Future<void> _saveTask() async {
    if (!_formKey.currentState!.validate()) return;

    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    final rawUrl = _urlController.text.trim();
    final url = rawUrl.isNotEmpty ? rawUrl : null;

    // Check if notification permission is granted if user requested notification
    if (_isNotificationEnabled) {
      await NotificationService.instance.requestPermissions();
    }

    if (!mounted) return;

    final taskProvider = Provider.of<TaskProvider>(context, listen: false);

    if (_isEditing) {
      final updatedTask = widget.taskToEdit!.copyWith(
        title: title,
        description: description,
        dueDate: _selectedDate,
        dueHour: _selectedTime.hour,
        dueMinute: _selectedTime.minute,
        priority: _selectedPriority,
        recurrence: _selectedRecurrence,
        url: url,
        isNotificationEnabled: _isNotificationEnabled,
      );
      await taskProvider.updateTask(updatedTask);
    } else {
      final newTask = Task(
        id: const Uuid().v4(),
        title: title,
        description: description,
        dueDate: _selectedDate,
        dueHour: _selectedTime.hour,
        dueMinute: _selectedTime.minute,
        priority: _selectedPriority,
        recurrence: _selectedRecurrence,
        url: url,
        isNotificationEnabled: _isNotificationEnabled,
        createdAt: DateTime.now(),
      );
      await taskProvider.addTask(newTask);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isEditing ? 'Reminder updated!' : 'Reminder created!',
          ),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Reminder' : 'New Reminder'),
        actions: [
          TextButton.icon(
            onPressed: _saveTask,
            icon: const Icon(Icons.check, size: 18),
            label: const Text(
              'Save',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            children: [
              // Title Field
              _buildSectionLabel('Task Title *'),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  hintText: 'e.g. Apply for NVIDIA Internship',
                  prefixIcon: Icon(Icons.task_alt_rounded, size: 20),
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter a reminder title';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Description Field
              _buildSectionLabel('Description / Note'),
              TextFormField(
                controller: _descriptionController,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'Add extra details, instructions, or notes...',
                  alignLabelWithHint: true,
                  prefixIcon: Padding(
                    padding: EdgeInsets.only(bottom: 40),
                    child: Icon(Icons.notes_rounded, size: 20),
                  ),
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 24),

              // Date & Time Selectors Row
              _buildSectionLabel('Schedule Date & Time'),
              Row(
                children: [
                  // Date Picker Button
                  Expanded(
                    child: InkWell(
                      onTap: _pickDate,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppColors.surfaceDark
                              : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? AppColors.borderDark
                                : AppColors.borderLight,
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_today_rounded,
                                size: 18, color: AppColors.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                DateTimeUtils.formatShortDate(_selectedDate),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Time Picker Button
                  Expanded(
                    child: InkWell(
                      onTap: _pickTime,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppColors.surfaceDark
                              : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? AppColors.borderDark
                                : AppColors.borderLight,
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.access_time_rounded,
                                size: 18, color: AppColors.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                DateTimeUtils.formatTime(
                                  _selectedTime.hour,
                                  _selectedTime.minute,
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Priority Selector
              _buildSectionLabel('Priority Level'),
              Row(
                children: Priority.values.map((priority) {
                  final isSelected = _selectedPriority == priority;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4.0),
                      child: ChoiceChip(
                        label: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                priority.icon,
                                size: 16,
                                color: isSelected
                                    ? Colors.white
                                    : priority.color,
                              ),
                              const SizedBox(width: 4),
                              Text(priority.label),
                            ],
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: priority.color,
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.white : null,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: isSelected
                                ? priority.color
                                : (isDark
                                    ? AppColors.borderDark
                                    : AppColors.borderLight),
                          ),
                        ),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _selectedPriority = priority;
                            });
                          }
                        },
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),

              // Repeat Selector
              _buildSectionLabel('Repeat'),
              Row(
                children: Recurrence.values.map((recurrence) {
                  final isSelected = _selectedRecurrence == recurrence;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3.0),
                      child: ChoiceChip(
                        label: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                recurrence.icon,
                                size: 15,
                                color: isSelected
                                    ? Colors.white
                                    : (isDark
                                        ? AppColors.textSecondaryDark
                                        : AppColors.textSecondaryLight),
                              ),
                              const SizedBox(width: 4),
                              Text(recurrence.label),
                            ],
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: AppColors.primary,
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.white : null,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: isSelected
                                ? AppColors.primary
                                : (isDark
                                    ? AppColors.borderDark
                                    : AppColors.borderLight),
                          ),
                        ),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _selectedRecurrence = recurrence;
                            });
                          }
                        },
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),

              // Optional URL
              _buildSectionLabel('Optional URL / Link'),
              TextFormField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/apply',
                  prefixIcon: Icon(Icons.link_rounded, size: 20),
                ),
              ),
              const SizedBox(height: 24),

              // Notification ON/OFF Toggle
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.surfaceDark : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark
                        ? AppColors.borderDark
                        : AppColors.borderLight,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _isNotificationEnabled
                            ? AppColors.primary.withValues(alpha: 0.12)
                            : Colors.grey.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isNotificationEnabled
                            ? Icons.notifications_active_rounded
                            : Icons.notifications_off_rounded,
                        color: _isNotificationEnabled
                            ? AppColors.primary
                            : Colors.grey,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Reminder Notification',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _isNotificationEnabled
                                ? 'Alert will trigger at the chosen time'
                                : 'No notification alert will be fired',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppColors.textSecondaryDark
                                  : AppColors.textSecondaryLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch.adaptive(
                      value: _isNotificationEnabled,
                      activeTrackColor: AppColors.primary,
                      onChanged: (val) {
                        setState(() {
                          _isNotificationEnabled = val;
                        });
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Submit Button
              ElevatedButton.icon(
                onPressed: _saveTask,
                icon: Icon(
                  _isEditing ? Icons.save_rounded : Icons.add_task_rounded,
                  size: 20,
                ),
                label: Text(_isEditing ? 'Save Changes' : 'Create Reminder'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
