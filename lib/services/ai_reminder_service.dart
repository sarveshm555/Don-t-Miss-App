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

  Future<List<AiReminderDraft>> parseMultiPrompt(
    String prompt, {
    DateTime? referenceTime,
    String? timezone,
    String? authToken,
  }) {
    return parsePrompt(prompt, referenceTime: referenceTime).then((d) => [d]);
  }

  Future<String> transcribeAudio(
    List<int> audioBytes, {
    String filename = 'audio.m4a',
    String? language,
    String? authToken,
  }) {
    throw UnimplementedError('transcribeAudio not implemented for this service');
  }
}

/// Deterministic, offline rule-based foundation parser.
class LocalAiReminderService implements AiReminderService {
  const LocalAiReminderService();

  @override
  Future<List<AiReminderDraft>> parseMultiPrompt(
    String prompt, {
    DateTime? referenceTime,
    String? timezone,
    String? authToken,
  }) async {
    final draft = await parsePrompt(prompt, referenceTime: referenceTime);
    return [draft];
  }

  @override
  Future<String> transcribeAudio(
    List<int> audioBytes, {
    String filename = 'audio.wav',
    String? language,
    String? authToken,
  }) async {
    return 'Voice transcription not supported in offline local mode';
  }

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

    // Pattern A: 12-hour format (e.g. "at 9 PM", "9:30 am", "7:30 AM", "12 PM", "6:45 PM")
    final time12Regex = RegExp(
      r'(?:at\s+)?\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b',
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
      // Pattern B: 24-hour format (e.g. "at 15:00", "09:30", "18:45")
      final time24Regex = RegExp(
        r'(?:at\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\b',
        caseSensitive: false,
      );
      final match24 = time24Regex.firstMatch(lower);
      if (match24 != null) {
        dueHour = int.parse(match24.group(1)!);
        dueMinute = int.parse(match24.group(2)!);
      } else {
        // Pattern C: Named periods of day
        if (lower.contains('morning') || lower.contains('in the morning')) {
          dueHour = 9;
          dueMinute = 0;
        } else if (lower.contains('afternoon') || lower.contains('in the afternoon')) {
          dueHour = 14;
          dueMinute = 0;
        } else if (lower.contains('evening') || lower.contains('in the evening')) {
          dueHour = 18;
          dueMinute = 0;
        } else if (lower.contains('night') || lower.contains('tonight') || lower.contains('at night')) {
          dueHour = 21;
          dueMinute = 0;
        } else if (lower.contains('noon') || lower.contains('at noon')) {
          dueHour = 12;
          dueMinute = 0;
        } else if (lower.contains('midnight') || lower.contains('at midnight')) {
          dueHour = 0;
          dueMinute = 0;
        } else {
          // Default time when no explicit time was provided: 09:00 AM
          dueHour = 9;
          dueMinute = 0;
        }
      }
    }

    // 3. Extract Title and Description
    String title = '';
    String description = '';

    String workingPrompt = cleanPrompt;

    // A. Strip conversational prefix
    workingPrompt = workingPrompt.replaceFirst(
      RegExp(
        r"^(?:please\s+)?(?:remind\s+me|set\s+(?:a\s+)?reminder|create\s+(?:a\s+)?reminder|don'?t\s+forget|remember)\s+(?:to\s+|for\s+|about\s+)?",
        caseSensitive: false,
      ),
      '',
    );

    // B. Strip temporal lead-in or phrases
    workingPrompt = workingPrompt.replaceAll(
      RegExp(r'\b(?:at\s+)?(?:\d{1,2}(?::\d{2})?\s*(?:am|pm)|[01]?\d|2[0-3]:[0-5]\d)\b', caseSensitive: false),
      '',
    );
    workingPrompt = workingPrompt.replaceAll(RegExp(r'\b(?:today|tomorrow)\b', caseSensitive: false), '');
    workingPrompt = workingPrompt.replaceAll(RegExp(r'\b(?:in\s+the\s+)?(?:morning|afternoon|evening|night|tonight|noon|midnight)\b', caseSensitive: false), '');
    workingPrompt = workingPrompt.replaceAll(RegExp(r'^\s*[,;:-]+\s*'), '').trim();

    // C. Check for secondary clauses / details / notes / mentions
    final secondaryClausePatterns = [
      RegExp(r'\s+and\s+mention\s+', caseSensitive: false),
      RegExp(r'\s*,\s*mentioning\s+', caseSensitive: false),
      RegExp(r'\s*,\s*mention\s+', caseSensitive: false),
      RegExp(r'\s+and\s+remember\s+(?:to\s+)?', caseSensitive: false),
      RegExp(r'\s*,\s*remember\s+(?:to\s+)?', caseSensitive: false),
      RegExp(r'\s+and\s+ask\s+(?:about\s+)?', caseSensitive: false),
      RegExp(r'\s+and\s+tell\s+', caseSensitive: false),
      RegExp(r'\s+and\s+bring\s+', caseSensitive: false),
      RegExp(r'\s+and\s+include\s+', caseSensitive: false),
      RegExp(r'\s+and\s+attach\s+', caseSensitive: false),
      RegExp(r'\s+and\s+prepare\s+', caseSensitive: false),
      RegExp(r'\s+and\s+check\s+', caseSensitive: false),
      RegExp(r"\s+and\s+don'?t\s+forget\s+(?:to\s+)?", caseSensitive: false),
      RegExp(r'\s+because\s+', caseSensitive: false),
      RegExp(r'\s*[-–—]\s*notes?:\s*', caseSensitive: false),
      RegExp(r'\s*;\s*', caseSensitive: false),
      RegExp(r'\s+with\s+details?\s+', caseSensitive: false),
      RegExp(r'\s+with\s+note\s+', caseSensitive: false),
    ];

    Match? bestSplitMatch;
    String splitKeyword = '';

    for (final pattern in secondaryClausePatterns) {
      final match = pattern.firstMatch(workingPrompt);
      if (match != null && (bestSplitMatch == null || match.start < bestSplitMatch.start)) {
        bestSplitMatch = match;
        splitKeyword = match.group(0)!;
      }
    }

    if (bestSplitMatch != null) {
      title = workingPrompt.substring(0, bestSplitMatch.start).trim();
      var rawDesc = workingPrompt.substring(bestSplitMatch.end).trim();

      // Determine description text with proper action phrasing
      final splitLower = splitKeyword.toLowerCase();
      if (splitLower.contains('because')) {
        description = rawDesc;
      } else if (splitLower.contains('mention')) {
        description = rawDesc.toLowerCase().startsWith('mention') ? rawDesc : 'Mention $rawDesc';
      } else if (splitLower.contains('ask')) {
        description = rawDesc.toLowerCase().startsWith('ask') ? rawDesc : 'Ask $rawDesc';
      } else if (splitLower.contains('tell')) {
        description = rawDesc.toLowerCase().startsWith('tell') ? rawDesc : 'Tell $rawDesc';
      } else if (splitLower.contains('bring')) {
        description = rawDesc.toLowerCase().startsWith('bring') ? rawDesc : 'Bring $rawDesc';
      } else if (splitLower.contains('include')) {
        description = rawDesc.toLowerCase().startsWith('include') ? rawDesc : 'Include $rawDesc';
      } else if (splitLower.contains('attach')) {
        description = rawDesc.toLowerCase().startsWith('attach') ? rawDesc : 'Attach $rawDesc';
      } else if (splitLower.contains('prepare')) {
        description = rawDesc.toLowerCase().startsWith('prepare') ? rawDesc : 'Prepare $rawDesc';
      } else if (splitLower.contains('check')) {
        description = rawDesc.toLowerCase().startsWith('check') ? rawDesc : 'Check $rawDesc';
      } else if (splitLower.contains('remember')) {
        description = rawDesc.toLowerCase().startsWith('remember') ? rawDesc : 'Remember to $rawDesc';
      } else {
        description = rawDesc;
      }
    } else {
      title = workingPrompt.trim();
    }

    // Strip leading "to " or "about " from title if present at the start of title
    title = title.replaceFirst(RegExp(r'^(?:to|about)\s+', caseSensitive: false), '').trim();
    title = title.replaceFirst(RegExp(r'^(?:my|the)\s+', caseSensitive: false), '').trim();

    // Clean up title: remove leading punctuation, recurrence words
    title = title.replaceAll(RegExp(r'\b(every\s+(day|week|month)|daily|weekly|monthly)\b', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'^[,\s;:-]+|[.,;!]+$'), '').trim();
    title = title.replaceAll(RegExp(r'\s{2,}'), ' ');

    if (title.isEmpty) {
      throw const AiParsingException(
        'Could not determine reminder title. Please specify what you want to be reminded about.',
      );
    }

    // Capitalize first letter of title
    title = title[0].toUpperCase() + title.substring(1);

    // Capitalize description if present
    if (description.isNotEmpty) {
      description = description.replaceAll(RegExp(r'^[,\s;:-]+|[.,;!]+$'), '').trim();
      if (description.isNotEmpty) {
        description = description[0].toUpperCase() + description.substring(1);
      }
    }

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
