import 'package:record/record.dart';

import 'voice_recording_stub.dart'
    if (dart.library.io) 'voice_recording_io.dart'
    if (dart.library.html) 'voice_recording_web.dart';

/// Platform-specific abstraction for managing audio output paths and bytes
/// without leaking dart:io or dart:html into shared application code.
abstract class VoiceRecordingPlatformHelper {
  /// Prepares an output path or empty string suitable for [AudioRecorder.start].
  Future<String> prepareRecordingPath(String extension);

  /// Reads recorded audio bytes and cleans up temporary resources.
  Future<List<int>?> readAndCleanupBytes(String path);

  /// Cleans up temporary resources if recording was cancelled or discarded.
  Future<void> cleanupPath(String path);

  /// Default recording configuration for the current platform.
  RecordConfig getRecordConfig();

  /// Output audio filename for Whisper transcription.
  String getFilename();
}

VoiceRecordingPlatformHelper getVoiceRecordingPlatformHelper() =>
    createVoiceRecordingPlatformHelper();
