import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'voice_recording_platform.dart';

VoiceRecordingPlatformHelper createVoiceRecordingPlatformHelper() =>
    IoVoiceRecordingPlatformHelper();

class IoVoiceRecordingPlatformHelper implements VoiceRecordingPlatformHelper {
  @override
  RecordConfig getRecordConfig() {
    // AAC-LC (.m4a) is hardware accelerated on 100% of Android devices via MediaMuxer,
    // producing compact files that upload quickly and transcribe accurately in Whisper.
    return const RecordConfig(
      encoder: AudioEncoder.aacLc,
      sampleRate: 16000,
      bitRate: 64000,
      numChannels: 1,
    );
  }

  @override
  String getFilename() => 'recording.m4a';

  @override
  Future<String> prepareRecordingPath(String extension) async {
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${tempDir.path}/dont_miss_rec_$timestamp.$extension');
    return file.path;
  }

  @override
  Future<List<int>?> readAndCleanupBytes(String path) async {
    if (path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) {
        debugPrint('Recorded audio file not found at $path');
        return null;
      }
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (e) {
        debugPrint('Could not delete temporary audio file: $e');
      }
      return bytes;
    } catch (e) {
      debugPrint('Error reading recorded audio file: $e');
      return null;
    }
  }

  @override
  Future<void> cleanupPath(String path) async {
    if (path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
