import '../models/ai_reminder_draft.dart';
import '../models/priority.dart';
import '../models/recurrence.dart';

/// Exception thrown when the AI reminder parser cannot extract required scheduling details.
class AiParsingException implements Exception {
  final String message;
  const AiParsingException(this.message);

  @override
  String toString() => message;
}

/// Abstract contract defining the AI reminder parser capabilities.
/// Decoupled from any specific cloud provider so future AWS Bedrock + Strands Agent
/// integrations can substitute this service seamlessly without UI changes.
abstract class AiReminderService {
  Future<AiReminderDraft> parsePrompt(
    String prompt, {
    DateTime? referenceTime,
  });
}

/// Deterministic, offline rule-based foundation parser.
class LocalAiReminderService implements AiReminderService {
  const LocalAiReminderService();

  @override
  Future<AiReminderDraft> parsePrompt(
    String prompt, {
    DateTime? referenceTime,
  }) async {
    final cleanPrompt = prompt.trim();
    if (cleanPrompt.isEmpty) {
      throw const AiParsingException('Please enter a reminder request.');
    }

    final lower = cleanPrompt.toLowerCase();
    final now = referenceTime ?? DateTime.now();

    // 1. Determine Date (Today or Tomorrow)
    DateTime? dueDate;
    if (lower.contains('tomorrow')) {
      final nextDay = now.add(const Duration(days: 1));
      dueDate = DateTime(nextDay.year, nextDay.month, nextDay.day);
    } else if (lower.contains('today')) {
      dueDate = DateTime(now.year, now.month, now.day);
    }

    if (dueDate == null) {
      throw const AiParsingException(
        'Could not determine reminder date. Please specify "today" or "tomorrow".',
      );
    }

    // 2. Determine Time
    int? dueHour;
    int? dueMinute;

    // Pattern A: 12-hour format (e.g. "at 9 PM", "9:30 am", "10:15 pm")
    final time12Regex = RegExp(
      r'(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b',
      caseSensitive: false,
    );
    final match12 = time12Regex.firstMatch(lower);

    if (match12 != null) {
      int hour = int.parse(match12.group(1)!);
      final minute = match12.group(2) != null ? int.parse(match12.group(2)!) : 0;
      final period = match12.group(3)!.toLowerCase();

      if (period == 'pm' && hour < 12) {
        hour += 12;
      } else if (period == 'am' && hour == 12) {
        hour = 0;
      }
      dueHour = hour;
      dueMinute = minute;
    } else {
      // Pattern B: 24-hour format (e.g. "at 15:00", "09:30")
      final time24Regex = RegExp(
        r'(?:at\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\b',
        caseSensitive: false,
      );
      final match24 = time24Regex.firstMatch(lower);
      if (match24 != null) {
        dueHour = int.parse(match24.group(1)!);
        dueMinute = int.parse(match24.group(2)!);
      }
    }

    if (dueHour == null || dueMinute == null) {
      throw const AiParsingException(
        'Could not determine reminder time. Please specify a time such as "at 9 PM" or "at 15:00".',
      );
    }

    // 3. Extract Title and Description
    String title = '';
    String description = '';

    String workingPrompt = cleanPrompt;

    // Split at "because" for description if present
    final becauseIndex = workingPrompt.toLowerCase().indexOf('because');
    if (becauseIndex != -1) {
      description = workingPrompt.substring(becauseIndex + 7).trim();
      workingPrompt = workingPrompt.substring(0, becauseIndex).trim();
    }

    // Extract title from "about ..." or "to ..."
    final aboutIndex = workingPrompt.toLowerCase().indexOf('about');
    final toIndex = workingPrompt.toLowerCase().indexOf('to ');

    if (aboutIndex != -1) {
      title = workingPrompt.substring(aboutIndex + 5).trim();
    } else if (toIndex != -1) {
      title = workingPrompt.substring(toIndex + 2).trim();
    } else {
      // Fallback: strip leading "remind me", dates, and times
      var text = workingPrompt;
      text = text.replaceAll(RegExp(r'^remind\s+me\s+', caseSensitive: false), '');
      text = text.replaceAll(RegExp(r'\b(today|tomorrow)\b', caseSensitive: false), '');
      text = text.replaceAll(time12Regex, '');
      text = text.replaceAll(RegExp(r'(?:at\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\b', caseSensitive: false), '');
      text = text.replaceAll(RegExp(r'\s+', caseSensitive: false), ' ');
      title = text.trim();
    }

    // Clean up title: remove leading articles, trailing punctuation, recurrence words
    title = title.replaceAll(RegExp(r'^(my|the)\s+', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'\b(every\s+(day|week|month)|daily|weekly|monthly)\b', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'[.,;!]+$'), '').trim();

    if (title.isEmpty) {
      throw const AiParsingException(
        'Could not determine reminder title. Please specify what you want to be reminded about.',
      );
    }

    // Capitalize first letter
    title = title[0].toUpperCase() + title.substring(1);

    // 4. Infer Priority
    Priority priority = Priority.medium;
    String? priorityReason;

    final highPriorityKeywords = [
      'interview',
      'urgent',
      'asap',
      'important',
      'critical',
      'exam',
      'doctor',
      'hospital',
      'emergency',
      'flight',
    ];
    final lowPriorityKeywords = ['casual', 'low priority', 'when free', 'someday'];

    for (final kw in highPriorityKeywords) {
      if (lower.contains(kw)) {
        priority = Priority.high;
        priorityReason = 'High priority inferred from "$kw"';
        break;
      }
    }

    if (priority == Priority.medium) {
      for (final kw in lowPriorityKeywords) {
        if (lower.contains(kw)) {
          priority = Priority.low;
          priorityReason = 'Low priority inferred from "$kw"';
          break;
        }
      }
    }

    // 5. Infer Recurrence
    Recurrence recurrence = Recurrence.none;
    if (lower.contains('daily') || lower.contains('every day')) {
      recurrence = Recurrence.daily;
    } else if (lower.contains('weekly') || lower.contains('every week')) {
      recurrence = Recurrence.weekly;
    } else if (lower.contains('monthly') || lower.contains('every month')) {
      recurrence = Recurrence.monthly;
    }

    // 6. Synthesize Reasoning
    final timeStr =
        '${dueHour % 12 == 0 ? 12 : dueHour % 12}:${dueMinute.toString().padLeft(2, '0')} ${dueHour >= 12 ? 'PM' : 'AM'}';
    final dateStr = lower.contains('tomorrow') ? 'tomorrow' : 'today';
    final reasoning = priorityReason != null
        ? '$priorityReason. Scheduled for $dateStr at $timeStr.'
        : 'Scheduled for $dateStr at $timeStr with Medium priority.';

    return AiReminderDraft(
      title: title,
      description: description,
      dueDate: dueDate,
      dueHour: dueHour,
      dueMinute: dueMinute,
      priority: priority,
      recurrence: recurrence,
      reasoning: reasoning,
      rawPrompt: cleanPrompt,
    );
  }
}
