import 'dart:io';
import 'package:flutter/services.dart';

class MacOSAudioRecognitionService {
  static const MethodChannel _channel = MethodChannel(
    'lyriko/macos_audio_recognition',
  );

  Future<void> start() async {
    if (!Platform.isMacOS) return;
    await _channel.invokeMethod<void>('start');
  }

  Future<Map<String, dynamic>> status() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('status');
    return result ?? <String, dynamic>{};
  }

  Future<void> stop() async {
    if (!Platform.isMacOS) return;
    await _channel.invokeMethod<void>('stop');
  }
}
