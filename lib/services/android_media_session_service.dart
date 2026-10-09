import 'package:flutter/services.dart';

enum AndroidMediaPlaybackStatus {
  none,
  stopped,
  paused,
  playing,
  fastForwarding,
  rewinding,
  buffering,
  error,
  connecting,
  skippingToPrevious,
  skippingToNext,
  skippingToQueueItem,
  unknown,
}

class AndroidMediaSessionState {
  final bool available;
  final AndroidMediaPlaybackStatus playbackStatus;
  final String sourceAppId;
  final String title;
  final String artist;
  final String albumArtist;
  final String albumTitle;
  final int positionMs;
  final int estimatedPositionMs;
  final int durationMs;
  final double playbackRate;

  const AndroidMediaSessionState({
    required this.available,
    required this.playbackStatus,
    required this.sourceAppId,
    required this.title,
    required this.artist,
    required this.albumArtist,
    required this.albumTitle,
    required this.positionMs,
    required this.estimatedPositionMs,
    required this.durationMs,
    required this.playbackRate,
  });

  factory AndroidMediaSessionState.fromMap(Map<dynamic, dynamic> map) {
    return AndroidMediaSessionState(
      available: true,
      playbackStatus: AndroidMediaSessionService.statusFromString(
        map['state']?.toString() ?? 'NONE',
      ),
      sourceAppId: map['packageName']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      artist: map['artist']?.toString() ?? '',
      albumArtist: map['albumArtist']?.toString() ?? '',
      albumTitle: map['album']?.toString() ?? '',
      positionMs: _asInt(map['rawPositionMs']),
      estimatedPositionMs: _asInt(map['estimatedPositionMs']),
      durationMs: _asInt(map['durationMs']),
      playbackRate: _asDouble(map['playbackSpeed'], fallback: 1.0),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double _asDouble(dynamic value, {required double fallback}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool get isPlaying =>
      playbackStatus == AndroidMediaPlaybackStatus.playing ||
      playbackStatus == AndroidMediaPlaybackStatus.fastForwarding ||
      playbackStatus == AndroidMediaPlaybackStatus.rewinding;

  bool get isPaused => playbackStatus == AndroidMediaPlaybackStatus.paused;

  bool get isStopped =>
      playbackStatus == AndroidMediaPlaybackStatus.stopped ||
      playbackStatus == AndroidMediaPlaybackStatus.none;

  bool get hasMetadata =>
      title.trim().isNotEmpty ||
      artist.trim().isNotEmpty ||
      albumArtist.trim().isNotEmpty ||
      albumTitle.trim().isNotEmpty;
}

class AndroidMediaSessionService {
  static const MethodChannel _channel = MethodChannel(
    'lyriko/android_media_session',
  );

  Future<bool> hasNotificationAccess() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isNotificationAccessEnabled',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openNotificationAccessSettings() async {
    try {
      await _channel.invokeMethod<bool>('openNotificationAccessSettings');
    } catch (_) {}
  }

  Future<List<AndroidMediaSessionState>> getSessions() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getSessions');
      if (result == null) return const [];

      return result
          .whereType<Map>()
          .map((item) => AndroidMediaSessionState.fromMap(item))
          .toList(growable: false);
    } on PlatformException catch (error) {
      if (error.code == 'NOTIFICATION_ACCESS_REQUIRED') {
        return const [];
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  static AndroidMediaPlaybackStatus statusFromString(String value) {
    switch (value.toUpperCase()) {
      case 'STOPPED':
        return AndroidMediaPlaybackStatus.stopped;
      case 'PAUSED':
        return AndroidMediaPlaybackStatus.paused;
      case 'PLAYING':
        return AndroidMediaPlaybackStatus.playing;
      case 'FAST_FORWARDING':
        return AndroidMediaPlaybackStatus.fastForwarding;
      case 'REWINDING':
        return AndroidMediaPlaybackStatus.rewinding;
      case 'BUFFERING':
        return AndroidMediaPlaybackStatus.buffering;
      case 'ERROR':
        return AndroidMediaPlaybackStatus.error;
      case 'CONNECTING':
        return AndroidMediaPlaybackStatus.connecting;
      case 'SKIPPING_TO_PREVIOUS':
        return AndroidMediaPlaybackStatus.skippingToPrevious;
      case 'SKIPPING_TO_NEXT':
        return AndroidMediaPlaybackStatus.skippingToNext;
      case 'SKIPPING_TO_QUEUE_ITEM':
        return AndroidMediaPlaybackStatus.skippingToQueueItem;
      case 'NONE':
        return AndroidMediaPlaybackStatus.none;
      default:
        return AndroidMediaPlaybackStatus.unknown;
    }
  }
}
