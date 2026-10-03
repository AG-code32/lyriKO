import 'package:flutter/services.dart';

class SystemAudioCaptureResult {
  final String filePath;
  final int bytes;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  const SystemAudioCaptureResult({
    required this.filePath,
    required this.bytes,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
  });

  factory SystemAudioCaptureResult.fromMap(
    Map<dynamic, dynamic> map,
  ) {
    return SystemAudioCaptureResult(
      filePath: map['filePath'] as String,
      bytes: map['bytes'] as int,
      sampleRate: map['sampleRate'] as int,
      channels: map['channels'] as int,
      bitsPerSample: map['bitsPerSample'] as int,
    );
  }
}

class SystemAudioCaptureService {
  static const MethodChannel _channel =
      MethodChannel('lyrics_app/system_audio');

  Future<SystemAudioCaptureResult> capture({
    Duration duration = const Duration(seconds: 6),
  }) async {
    final result =
        await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'captureSystemAudio',
      {
        'durationMs': duration.inMilliseconds,
      },
    );

    if (result == null) {
      throw StateError(
        'Windows returned an empty capture result.',
      );
    }

    return SystemAudioCaptureResult.fromMap(result);
  }
}