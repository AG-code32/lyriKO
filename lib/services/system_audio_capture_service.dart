import 'package:flutter/services.dart';

class SystemAudioCaptureResult {
  final String filePath;
  final int bytes;
  final Duration duration;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  const SystemAudioCaptureResult({
    required this.filePath,
    required this.bytes,
    required this.duration,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
  });
}

class SystemAudioCaptureService {
  static const MethodChannel _channel =
      MethodChannel(
    'lyrics_app/system_audio',
  );

  Future<void>
      startContinuousCapture() async {
    await _channel.invokeMethod<void>(
      'startContinuousCapture',
    );
  }

  Future<SystemAudioCaptureResult>
      snapshotContinuousCapture({
    Duration last =
        const Duration(seconds: 2),
  }) async {
    final result =
        await _channel.invokeMapMethod<
            String,
            dynamic>(
      'snapshotContinuousCapture',
      {
        'durationMs':
            last.inMilliseconds,
      },
    );

    if (result == null) {
      throw StateError(
        'Windows returned no audio snapshot.',
      );
    }

    return SystemAudioCaptureResult(
      filePath:
          result['filePath']
              .toString(),

      bytes:
          (result['bytes'] as num)
              .toInt(),

      duration:
          Duration(
        milliseconds:
            (result['durationMs']
                    as num)
                .toInt(),
      ),

      sampleRate:
          (result['sampleRate']
                  as num)
              .toInt(),

      channels:
          (result['channels']
                  as num)
              .toInt(),

      bitsPerSample:
          (result['bitsPerSample']
                  as num)
              .toInt(),
    );
  }

  Future<void>
      stopContinuousCapture() async {
    await _channel.invokeMethod<void>(
      'stopContinuousCapture',
    );
  }

  Future<SystemAudioCaptureResult> capture({
    required Duration duration,
  }) async {
    await startContinuousCapture();

    try {
      await Future.delayed(
        duration,
      );

      return await snapshotContinuousCapture(
        last: duration,
      );
    } finally {
      await stopContinuousCapture();
    }
  }
}