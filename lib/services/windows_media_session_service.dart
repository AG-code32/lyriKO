import 'package:flutter/services.dart';

enum WindowsMediaPlaybackStatus {
  unavailable,
  closed,
  opened,
  changing,
  stopped,
  playing,
  paused,
  unknown,
}

class WindowsMediaSessionState {
  final bool available;
  final WindowsMediaPlaybackStatus playbackStatus;
  final String sourceAppId;

  /// Position reported by Windows at [lastUpdatedTimeMs].
  final int positionMs;
  final int lastUpdatedTimeMs;
  final double playbackRate;

  final int startTimeMs;
  final int endTimeMs;

  final String title;
  final String artist;
  final String albumArtist;
  final String albumTitle;
  final String playbackType;
  final int trackNumber;
  final List<String> genres;

  const WindowsMediaSessionState({
    required this.available,
    required this.playbackStatus,
    required this.sourceAppId,
    required this.positionMs,
    required this.lastUpdatedTimeMs,
    required this.playbackRate,
    required this.startTimeMs,
    required this.endTimeMs,
    required this.title,
    required this.artist,
    required this.albumArtist,
    required this.albumTitle,
    required this.playbackType,
    required this.trackNumber,
    required this.genres,
  });

  factory WindowsMediaSessionState.fromMap(Map<dynamic, dynamic> map) {
    final rawGenres = map['genres'];
    final genres = rawGenres is List
        ? rawGenres.map((value) => value.toString()).toList()
        : <String>[];

    return WindowsMediaSessionState(
      available: map['available'] == true,
      playbackStatus: WindowsMediaSessionService.playbackStatusFromString(
        map['playbackStatus']?.toString() ?? 'unavailable',
      ),
      sourceAppId: map['sourceAppId']?.toString() ?? '',
      positionMs: _asInt(map['positionMs']),
      lastUpdatedTimeMs: _asInt(map['lastUpdatedTimeMs']),
      playbackRate: _asDouble(map['playbackRate'], fallback: 1.0),
      startTimeMs: _asInt(map['startTimeMs']),
      endTimeMs: _asInt(map['endTimeMs']),
      title: map['title']?.toString() ?? '',
      artist: map['artist']?.toString() ?? '',
      albumArtist: map['albumArtist']?.toString() ?? '',
      albumTitle: map['albumTitle']?.toString() ?? '',
      playbackType: map['playbackType']?.toString() ?? 'unknown',
      trackNumber: _asInt(map['trackNumber']),
      genres: genres,
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double _asDouble(
    dynamic value, {
    required double fallback,
  }) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool get isPlaying =>
      available && playbackStatus == WindowsMediaPlaybackStatus.playing;

  bool get isPaused =>
      available && playbackStatus == WindowsMediaPlaybackStatus.paused;

  bool get isStopped =>
      available && playbackStatus == WindowsMediaPlaybackStatus.stopped;

  bool get isActive => isPlaying || isPaused || isStopped;

  bool get hasMetadata =>
      title.trim().isNotEmpty ||
      artist.trim().isNotEmpty ||
      albumArtist.trim().isNotEmpty ||
      albumTitle.trim().isNotEmpty;

  int get durationMs {
    final value = endTimeMs - startTimeMs;
    return value < 0 ? 0 : value;
  }

  /// Returns the best estimate of the media position *now*.
  ///
  /// Windows' Position belongs to LastUpdatedTime. While playing we advance
  /// that stale position by the elapsed wall-clock time multiplied by the
  /// published playback rate. While paused/stopped, the raw position is used.
  int estimatedPositionMs({int? nowUnixMs}) {
    if (!isPlaying) {
      return _clampTimeline(positionMs);
    }

    final updatedAt = lastUpdatedTimeMs;
    if (updatedAt <= 0) {
      return _clampTimeline(positionMs);
    }

    final now = nowUnixMs ?? DateTime.now().millisecondsSinceEpoch;
    var elapsedMs = now - updatedAt;

    // Protect against a bad/unsupported timestamp rather than creating a huge
    // jump. A valid Media Session timestamp should be close to "now".
    if (elapsedMs < 0 || elapsedMs > 30000) {
      elapsedMs = 0;
    }

    final rate = playbackRate.isFinite && playbackRate > 0
        ? playbackRate
        : 1.0;

    final estimated = positionMs + (elapsedMs * rate).round();
    return _clampTimeline(estimated);
  }

  int _clampTimeline(int value) {
    var result = value;

    if (result < startTimeMs) {
      result = startTimeMs;
    }

    if (endTimeMs > startTimeMs && result > endTimeMs) {
      result = endTimeMs;
    }

    return result;
  }

  @override
  String toString() {
    return 'WindowsMediaSessionState('
        'available: $available, '
        'status: $playbackStatus, '
        'app: $sourceAppId, '
        'title: $title, '
        'artist: $artist, '
        'albumArtist: $albumArtist, '
        'album: $albumTitle, '
        'positionMs: $positionMs, '
        'estimatedPositionMs: ${estimatedPositionMs()}, '
        'lastUpdatedTimeMs: $lastUpdatedTimeMs, '
        'playbackRate: $playbackRate, '
        'durationMs: $durationMs)';
  }
}

class WindowsMediaSessionService {
  static const MethodChannel _channel = MethodChannel('lyriko/media_session');

  bool _initialized = false;

  Future<bool> initialize() async {
    if (_initialized) return true;

    try {
      final result = await _channel.invokeMethod<bool>('initialize');
      _initialized = result == true;
      return _initialized;
    } catch (_) {
      return false;
    }
  }

  Future<WindowsMediaSessionState> getState() async {
    if (!await _ensureInitialized()) return _unavailable();

    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>('getState');
      if (result == null) return _unavailable();
      return WindowsMediaSessionState.fromMap(result);
    } catch (_) {
      return _unavailable();
    }
  }

  Future<List<WindowsMediaSessionState>> getSessions() async {
    if (!await _ensureInitialized()) return const [];

    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getSessions');
      if (result == null) return const [];

      return result
          .whereType<Map>()
          .map((item) => WindowsMediaSessionState.fromMap(item))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _ensureInitialized() async {
    if (_initialized) return true;
    return initialize();
  }

  static WindowsMediaPlaybackStatus playbackStatusFromString(String value) {
    switch (value.toLowerCase()) {
      case 'closed':
        return WindowsMediaPlaybackStatus.closed;
      case 'opened':
        return WindowsMediaPlaybackStatus.opened;
      case 'changing':
        return WindowsMediaPlaybackStatus.changing;
      case 'stopped':
        return WindowsMediaPlaybackStatus.stopped;
      case 'playing':
        return WindowsMediaPlaybackStatus.playing;
      case 'paused':
        return WindowsMediaPlaybackStatus.paused;
      case 'unavailable':
        return WindowsMediaPlaybackStatus.unavailable;
      default:
        return WindowsMediaPlaybackStatus.unknown;
    }
  }

  WindowsMediaSessionState _unavailable() {
    return const WindowsMediaSessionState(
      available: false,
      playbackStatus: WindowsMediaPlaybackStatus.unavailable,
      sourceAppId: '',
      positionMs: 0,
      lastUpdatedTimeMs: 0,
      playbackRate: 1.0,
      startTimeMs: 0,
      endTimeMs: 0,
      title: '',
      artist: '',
      albumArtist: '',
      albumTitle: '',
      playbackType: 'unknown',
      trackNumber: 0,
      genres: [],
    );
  }
}
