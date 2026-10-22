// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'voice_recording_platform.dart';

VoiceRecordingPlatformHelper createVoiceRecordingPlatformHelper() =>
    WebVoiceRecordingPlatformHelper();

class WebVoiceRecordingPlatformHelper implements VoiceRecordingPlatformHelper {
  @override
  RecordConfig getRecordConfig() {
    // AudioEncoder.wav on Web is handled by MicRecorderDelegate in record_web
    // and returns a standard WAV Blob URL supported across desktop browsers.
    return const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
    );
  }

  @override
  String getFilename() => 'recording.wav';

  @override
  Future<String> prepareRecordingPath(String extension) async {
    // In browser web platform, path parameter is ignored; output is returned as blob url.
    return '';
  }

  @override
  Future<List<int>?> readAndCleanupBytes(String path) async {
    if (path.isEmpty) return null;
    try {
      final request = await html.HttpRequest.request(
        path,
        responseType: 'arraybuffer',
      );
      final byteBuffer = request.response as ByteBuffer;
      final bytes = Uint8List.view(byteBuffer);
      try {
        html.Url.revokeObjectUrl(path);
      } catch (_) {}
      return bytes;
    } catch (e) {
      debugPrint('Error reading Web audio blob: $e');
      return null;
    }
  }

  @override
  Future<void> cleanupPath(String path) async {
    if (path.isEmpty) return;
    try {
      html.Url.revokeObjectUrl(path);
    } catch (_) {}
  }
}
