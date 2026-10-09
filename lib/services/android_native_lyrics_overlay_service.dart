import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class AndroidNativeLyricsOverlayService {
  static const MethodChannel _channel = MethodChannel('lyriko/native_overlay');

  Future<bool> isPermissionGranted() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isOverlayPermissionGranted') ?? false;
  }

  Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('requestOverlayPermission');
  }

  Future<bool> show(Map<String, dynamic> state) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('showOverlay', {
          'stateJson': jsonEncode(state),
        }) ??
        false;
  }

  Future<void> update(Map<String, dynamic> state) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('updateOverlay', {
      'stateJson': jsonEncode(state),
    });
  }

  Future<void> setBackground(double percent) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setOverlayBackground', {
      'percent': percent.clamp(0.0, 100.0).toDouble(),
    });
  }

  Future<void> close() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('closeOverlay');
  }
}
