import 'dart:io';

import 'package:flutter/services.dart';

import 'lyriko_server_client.dart';

class MacOSAudioRecognitionService {
  static const MethodChannel _channel =
      MethodChannel('lyriko/macos_audio_recognition');

  Future<void> start() async {
    if (!Platform.isMacOS) return;
    final client = LyrikoServerClient();
    final serverUrl = await client.getBaseUrl();
    final token = await client.getAuthToken();
    if (serverUrl.isEmpty || token.isEmpty) {
      throw StateError('Configure the server URL and token in Server Settings.');
    }
    await _channel.invokeMethod<void>('start', <String, String>{
      'serverUrl': serverUrl,
      'token': token,
    });
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
