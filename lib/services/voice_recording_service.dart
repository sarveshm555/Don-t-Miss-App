import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'voice_recording_platform.dart';

/// Abstract contract for recording audio input across Android and Web.
abstract class VoiceRecordingService {
  Future<bool> hasPermission();
  Future<void> startRecording();
  Future<List<int>?> stopRecording();
  Future<void> cancelRecording();
  Stream<Duration> get durationStream;
  bool get isRecording;
  String get recordedFilename;
  void dispose();
}

/// Production implementation of [VoiceRecordingService] powered by `package:record`.
///
/// Uses platform-adapted file/blob recording (`start` / `stop`) instead of streaming,
/// ensuring full compatibility with Android MediaRecorder/MediaMuxer and Web MediaRecorder.
class AppVoiceRecordingService implements VoiceRecordingService {
  final AudioRecorder _recorder;
  final VoiceRecordingPlatformHelper _platformHelper;
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  Timer? _timer;
  int _seconds = 0;
  bool _isRecording = false;
  String _currentRecordingPath = '';

  AppVoiceRecordingService({
    AudioRecorder? recorder,
    VoiceRecordingPlatformHelper? platformHelper,
  })  : _recorder = recorder ?? AudioRecorder(),
        _platformHelper = platformHelper ?? getVoiceRecordingPlatformHelper();

  @override
  bool get isRecording => _isRecording;

  @override
  String get recordedFilename => _platformHelper.getFilename();

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (e) {
      debugPrint('Error checking microphone permission: $e');
      return false;
    }
  }

  @override
  Future<void> startRecording() async {
    final permitted = await hasPermission();
    if (!permitted) {
      throw Exception('Microphone permission not granted');
    }

    // Cancel any previous in-flight session safely
    if (_isRecording) {
      await cancelRecording();
    }

    _seconds = 0;
    _durationController.add(Duration.zero);

    final ext = _platformHelper.getFilename().split('.').last;
    _currentRecordingPath = await _platformHelper.prepareRecordingPath(ext);
    final config = _platformHelper.getRecordConfig();

    // Use recorder.start (file/blob mode), which is supported on all Android hardware
    // and Web browsers, rather than startStream which fails on Android WAV.
    await _recorder.start(config, path: _currentRecordingPath);

    _isRecording = true;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      _seconds++;
      _durationController.add(Duration(seconds: _seconds));
    });
  }

  @override
  Future<List<int>?> stopRecording() async {
    if (!_isRecording) return null;
    _timer?.cancel();
    _timer = null;
    _isRecording = false;

    try {
      final outputPath = await _recorder.stop();
      final targetPath = (outputPath != null && outputPath.isNotEmpty)
          ? outputPath
          : _currentRecordingPath;

      final bytes = await _platformHelper.readAndCleanupBytes(targetPath);
      _currentRecordingPath = '';
      return bytes;
    } catch (e) {
      debugPrint('Error stopping voice recording: $e');
      _currentRecordingPath = '';
      return null;
    }
  }

  @override
  Future<void> cancelRecording() async {
    _timer?.cancel();
    _timer = null;
    _isRecording = false;

    try {
      await _recorder.cancel();
    } catch (_) {}

    try {
      await _platformHelper.cleanupPath(_currentRecordingPath);
    } catch (_) {}

    _currentRecordingPath = '';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _durationController.close();
    _recorder.dispose();
  }
}
