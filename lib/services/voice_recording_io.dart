import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
    Directory tempDir;
    try {
      // On Android, Directory.systemTemp points to /data/local/tmp (unwritable).
      // Use app-private temporary cache via path_provider.
      tempDir = await getTemporaryDirectory();
    } catch (_) {
      // Fallback for pure-Dart unit test environments without platform channels
      tempDir = Directory.systemTemp;
    }
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final cleanExt = extension.trim().isEmpty ? 'm4a' : extension.trim();
    final sep = Platform.pathSeparator;
    final base = tempDir.path.endsWith(sep)
        ? tempDir.path.substring(0, tempDir.path.length - 1)
        : tempDir.path;
    return '$base${sep}dont_miss_rec_$timestamp.$cleanExt';
  }

  @override
  Future<List<int>?> readAndCleanupBytes(String path) async {
    if (path.isEmpty) return null;
    final file = File(path);
    try {
      if (!await file.exists()) {
        debugPrint('Recorded audio file not found at $path');
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        return null;
      }
      return bytes;
    } catch (e) {
      debugPrint('Error reading recorded audio file: $e');
      rethrow;
    } finally {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Could not delete temporary audio file: $e');
      }
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
