import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:window_manager/window_manager.dart';

import '../services/android_media_session_service.dart';
import '../services/android_native_lyrics_overlay_service.dart';
import '../services/fingerprint_match_service.dart';
import '../services/synced_lyrics_service.dart';
import '../services/system_audio_capture_service.dart';
import '../services/windows_media_session_service.dart';
import 'lyrics_edit_screen.dart';

class SyncedLyricsScreen extends StatefulWidget {
  final int initialPositionMs;
  final String lockedTrackName;
  final String jsonPath;
  /// true: Discover microphone; false: Listen internal audio.
  final bool useMicrophone;

  /// When Home found a Windows Media Session, it passes the owning app here.
  /// Example: chrome.exe or Spotify.exe.
  final String? mediaSourceAppId;

  const SyncedLyricsScreen({
    super.key,
    required this.initialPositionMs,
    required this.lockedTrackName,
    required this.jsonPath,
    this.useMicrophone = false,
    this.mediaSourceAppId,
  });

  @override
  State<SyncedLyricsScreen> createState() => _SyncedLyricsScreenState();
}

class _SyncedLyricsScreenState extends State<SyncedLyricsScreen> with WidgetsBindingObserver {
  final SyncedLyricsService _lyricsService = SyncedLyricsService();
  final WindowsMediaSessionService _mediaService =
      WindowsMediaSessionService();
  final AndroidMediaSessionService _androidMediaService =
      AndroidMediaSessionService();
  final AndroidNativeLyricsOverlayService _androidOverlayService =
      AndroidNativeLyricsOverlayService();
  final FingerprintMatchService _fingerprintService = FingerprintMatchService();
  final SystemAudioCaptureService _captureService = SystemAudioCaptureService();
  final ItemScrollController _scrollController = ItemScrollController();

  SyncedLyricsSong? _song;
  late String _currentJsonPath;
  DateTime? _iosLastTrackSwitch;

  Timer? _uiTimer;
  Timer? _mediaTimer;
  Timer? _fallbackTimer;

  static const MethodChannel _iosAudioChannel =
      MethodChannel('lyriko/ios_audio_probe');
  bool _iosAudioSeen = false;
  int _iosLastMatchSequence = 0;
  static const int _iosHardSeekThresholdMs = 2000;
  static const int _iosMinCorrectionMs = 450;
  bool _iosPollBusy = false;
  static const int _iosQuietTimeoutMs = 1500;
  // Discover: allow brief quiet passages, but stop the lyric clock shortly
  // after the audible music disappears. Listen keeps its old 1500ms policy.
  static const int _iosMicQuietTimeoutMs = 800;
  static const int _iosMicBufferTimeoutMs = 1500;

  final Stopwatch _localClock = Stopwatch();
  final Stopwatch _fallbackCaptureClock = Stopwatch();

  int _anchorPositionMs = 0;
  int _currentPositionMs = 0;
  int _activeLineIndex = -1;
  int _lastScrolledIndex = -1;

  bool _clockRunning = false;
  bool _openingEditor = false;
  bool _overlayModeActive = false;
  bool _mediaPollBusy = false;
  bool _fallbackBusy = false;
  bool _fallbackStarted = false;
  bool _fallbackPaused = false;
  bool _androidOverlayStarted = false;
  int _lastAndroidOverlayBroadcastAtMs = 0;

  int? _lastMediaRawPositionMs;
  bool? _lastMediaPlaying;
  DateTime? _lastMediaSeenAt;

  int? _lastFallbackMeasuredMs;
  int _fallbackStagnantMeasurements = 0;

  String _trackingLabel = 'STARTING';
  Color _trackingColor = Colors.white54;
  double _backgroundOpacityPercent = 20.0;
  String? _error;

  static const Duration _mediaPollInterval = Duration(milliseconds: 500);
  static const Duration _mediaLostGrace = Duration(seconds: 2);

  static const int _mediaHardSeekThresholdMs = 900;
  static const int _mediaRawChangeThresholdMs = 120;
  static const double _mediaSoftCorrectionFactor = 0.45;

  static const int _fallbackMinimumAlignedHashes = 5;
  static const double _fallbackMinimumRatio = 0.50;
  static const int _fallbackStagnantToleranceMs = 350;
  static const int _fallbackStagnantBeforePause = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentJsonPath = widget.jsonPath;

    _anchorPositionMs = widget.initialPositionMs;
    _currentPositionMs = widget.initialPositionMs;

    _enterLyricsOverlayMode();
    _load();
  }

  Future<void> _enterLyricsOverlayMode() async {
    if (!Platform.isWindows) {
      return;
    }

    try {
      await windowManager.setBackgroundColor(
        Colors.transparent,
      );

      await windowManager.setAsFrameless();

      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(const Size(360, 240));

      await windowManager.setAlwaysOnTop(
        true,
      );

      _overlayModeActive = true;
    } catch (e) {
      debugPrint(
        'Could not enable lyrics overlay mode: $e',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (!Platform.isAndroid || state != AppLifecycleState.resumed) {
      return;
    }

    final song = _song;
    if (song == null) return;

    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        unawaited(
          _startAndroidFloatingOverlay(
            song,
            requestIfNeeded: false,
          ),
        );
      }
    });
  }

  Future<void> _ensureAndroidFloatingOverlay(SyncedLyricsSong song) async {
    if (!Platform.isAndroid) return;

    await _startAndroidFloatingOverlay(
      song,
      requestIfNeeded: true,
    );
  }

  Future<void> _startAndroidFloatingOverlay(
    SyncedLyricsSong song, {
    required bool requestIfNeeded,
  }) async {
    if (!Platform.isAndroid) return;

    try {
      var granted = await _androidOverlayService.isPermissionGranted();

      if (!granted && requestIfNeeded) {
        await _androidOverlayService.requestPermission();
        return;
      }

      if (!granted) {
        if (mounted && requestIfNeeded) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Enable “Display over other apps” for Lyriko, then return to the app.',
              ),
            ),
          );
        }
        return;
      }

      final state = _buildAndroidOverlayState(song);
      final started = await _androidOverlayService.show(state);

      _androidOverlayStarted = started;

      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The native floating lyrics overlay could not start.',
            ),
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('Could not start native Android lyrics overlay: $e');
      debugPrintStack(stackTrace: stack);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Floating lyrics error: $e',
            ),
          ),
        );
      }
    }
  }

  Future<void> _forceOpenAndroidOverlay() async {
    final song = _song;
    if (!Platform.isAndroid || song == null) return;

    await _startAndroidFloatingOverlay(
      song,
      requestIfNeeded: true,
    );
  }

  Map<String, dynamic> _buildAndroidOverlayState(
    SyncedLyricsSong song,
  ) {
    return {
      'title': song.title,
      'artist': song.artist,
      'positionMs': _currentPositionMs,
      'playing': _clockRunning,
      'tracking': _trackingLabel,
      'lines': song.lines
          .map(
            (line) => {
              'text': line.text,
              'startMs': line.startMs,
              'endMs': line.endMs,
            },
          )
          .toList(),
    };
  }

  Future<void> _broadcastAndroidOverlay(
    SyncedLyricsSong song, {
    bool force = false,
  }) async {
    if (!Platform.isAndroid || !_androidOverlayStarted) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastAndroidOverlayBroadcastAtMs < 220) {
      return;
    }

    _lastAndroidOverlayBroadcastAtMs = now;

    try {
      await _androidOverlayService.update(
        _buildAndroidOverlayState(song),
      );
    } catch (e) {
      debugPrint(
        'Could not update native Android lyrics overlay: $e',
      );
    }
  }

  Future<void> _restoreNormalWindowMode() async {
    if (!Platform.isWindows || !_overlayModeActive) {
      return;
    }

    _overlayModeActive = false;

    try {
      await windowManager.setAlwaysOnTop(
        false,
      );

      await windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );

      await windowManager.setBackgroundColor(
        const Color(
          0xFF080808,
        ),
      );
    } catch (e) {
      debugPrint(
        'Could not restore normal window mode: $e',
      );
    }
  }

  Future<void> _load() async {
    try {
      final song = await _lyricsService.loadSong(_currentJsonPath);

      final safePosition = _clampPosition(widget.initialPositionMs, song);
      final active = _lyricsService.findActiveLineIndex(song, safePosition);

      if (!mounted) return;

      setState(() {
        _song = song;
        _anchorPositionMs = safePosition;
        _currentPositionMs = safePosition;
        _activeLineIndex = active;
        _error = null;
      });

      // iOS does not expose third-party player's pause/seek state.
      // Wait for captured audio before advancing the local lyric clock.
      _setAnchor(safePosition, running: !Platform.isIOS, forceScroll: false);
      if (Platform.isIOS) {
        _setTrackingStatus('WAIT AUDIO', Colors.white54);
      }

      if (Platform.isWindows) {
        await _mediaService.initialize();
      }

      _startUiTimer();
      _startMediaTimer();
      _scheduleInitialScroll();

      // Poll immediately rather than waiting for the first timer tick.
      await _pollMediaSession();

      if (Platform.isAndroid) {
        await _ensureAndroidFloatingOverlay(song);
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
      });
    }
  }

  void _startUiTimer() {
    _uiTimer?.cancel();

    _uiTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => _updateVisualPosition(),
    );
  }

  void _startMediaTimer() {
    _mediaTimer?.cancel();

    _mediaTimer = Timer.periodic(
      _mediaPollInterval,
      (_) => _pollMediaSession(),
    );
  }

  void _updateVisualPosition() {
    final song = _song;

    if (song == null || !mounted || _openingEditor) return;

    final position = _estimatedPositionMs(song);

    if (position == _currentPositionMs) return;

    final active = _lyricsService.findActiveLineIndex(song, position);
    final changed = active >= 0 && active != _activeLineIndex;

    setState(() {
      _currentPositionMs = position;
      if (active >= 0) {
        _activeLineIndex = active;
      }
    });

    if (changed) {
      _scrollToLine(active);
    }

    if (Platform.isAndroid) {
      unawaited(_broadcastAndroidOverlay(song));
    }
  }

  int _estimatedPositionMs(SyncedLyricsSong song) {
    var position = _anchorPositionMs;

    if (_clockRunning) {
      position += _localClock.elapsedMilliseconds;
    }

    return _clampPosition(position, song);
  }

  Future<void> _pollMediaSession() async {
    if (_mediaPollBusy || _openingEditor || _song == null) return;

    _mediaPollBusy = true;

    try {
      if (Platform.isIOS) {
        await _pollIOSAudio();
        return;
      }
      if (Platform.isAndroid) {
        final sessions = await _androidMediaService.getSessions();
        final session = _selectAndroidMediaSession(sessions);

        if (session != null) {
          _lastMediaSeenAt = DateTime.now();
          _applyAndroidMediaSession(session);
          return;
        }

        _setTrackingStatus(
          'WAITING',
          Colors.white54,
        );
        return;
      }

      final sessions = await _mediaService.getSessions();
      final session = _selectMediaSession(sessions);

      if (session != null) {
        _lastMediaSeenAt = DateTime.now();

        if (_fallbackStarted) {
          await _stopFingerprintFallback();
        }

        _applyMediaSession(session);
        return;
      }

      final lastSeen = _lastMediaSeenAt;
      if (lastSeen != null &&
          DateTime.now().difference(lastSeen) < _mediaLostGrace) {
        return;
      }

      if (Platform.isWindows) {
        await _ensureFingerprintFallback();
      }
    } finally {
      _mediaPollBusy = false;
    }
  }

  // Provisional iOS activity tracking, NOT authoritative YouTube playback state.
  // Silence and other applications' audio can cause false positives/negatives.
  // Seek correction requires periodic acoustic re-matching in a later version.
  Future<void> _pollIOSAudio() async {
    if (_iosPollBusy || !mounted || _song == null) return;
    _iosPollBusy = true;
    try {
      final raw = await _iosAudioChannel.invokeMapMethod<String, dynamic>(
        widget.useMicrophone ? 'micStats' : 'stats',
      );
      if (!mounted || _openingEditor) return;
      final stats = raw ?? const <String, dynamic>{};
      final phase = (stats['phase'] ?? 'idle').toString();
      final lastSignal = (stats['lastSignalEpochMs'] as num?)?.toInt() ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      // Discover stays connected while its capture engine receives buffers,
      // but advances only when the native music-level gate reports activity.
      // The two concepts must not be conflated: room noise is not playback.
      final lastMusic = (stats['lastMusicEpochMs'] as num?)?.toInt() ?? 0;
      final lastBuffer = (stats['lastBufferEpochMs'] as num?)?.toInt() ?? 0;
      final micStreamHealthy = lastBuffer > 0 && now >= lastBuffer &&
          now - lastBuffer < _iosMicBufferTimeoutMs;
      final nativeMusicGateOpen = stats['musicGateOpen'] == true;
      final micMusicActive = nativeMusicGateOpen &&
          lastMusic > 0 && now >= lastMusic &&
          now - lastMusic < _iosMicQuietTimeoutMs;
      final active = widget.useMicrophone
          ? (phase == 'listening' || phase == 'matched') &&
              micStreamHealthy && micMusicActive
          : phase == 'capturing' && lastSignal > 0 &&
              now >= lastSignal && now - lastSignal < _iosQuietTimeoutMs;
      final song = _song;
      if (song == null) return;
      // Apply only fresh matches of the *currently displayed* track.
      // A new match provides a position anchor; the local clock interpolates
      // between matches. This is not direct access to YouTube's seek state.
      final sequence = (stats['matchSequence'] as num?)?.toInt() ?? 0;
      final matchedAt = (stats['matchedEpochMs'] as num?)?.toInt() ?? 0;
      final offset = (stats['matchedOffset'] as num?)?.toDouble() ?? -1;
      final matchedTitle = (stats['matchedTitle'] ?? '').toString();
      final matchedArtist = (stats['matchedArtist'] ?? '').toString();
      if (active && sequence > _iosLastMatchSequence &&
          matchedAt > 0 && now >= matchedAt && now - matchedAt < 15000 &&
          offset >= 0 && matchedTitle.isNotEmpty) {
        _iosLastMatchSequence = sequence;
        final score = _lyricsService.mediaMetadataScoreForSong(
          song, title: matchedTitle, artist: matchedArtist,
          albumArtist: '',
        );
        if (score < 70) {
          // An acoustic match for a different library track: retain the same
          // capture session and switch the displayed lyrics in place.
          final nextSong = await _lyricsService.findSongForMediaMetadata(
            title: matchedTitle,
            artist: matchedArtist,
          );
          if (!mounted || _openingEditor) return;
          if (nextSong != null && nextSong.jsonPath != _currentJsonPath) {
            final lastSwitch = _iosLastTrackSwitch;
            final canSwitch = lastSwitch == null ||
                DateTime.now().difference(lastSwitch) > const Duration(seconds: 3);
            if (canSwitch) {
              await _switchIOSSong(nextSong, offset);
              return;
            }
          }
        } else {
          // ShazamKit's matchOffset is a reference position; callback delivery
          // latency is not guaranteed. Do not add that latency blindly.
          final measured = _clampPosition((offset * 1000).round(), song);
          final predicted = _estimatedPositionMs(song);
          final drift = measured - predicted;
          if (drift.abs() >= _iosHardSeekThresholdMs) {
            _setAnchor(measured, running: true, forceScroll: true);
          } else if (drift.abs() >= _iosMinCorrectionMs) {
            _setAnchor(predicted + (drift * 0.35).round(),
                running: true, forceScroll: false);
          }
        }
      }
      if (active) {
        _iosAudioSeen = true;
        if (!_clockRunning) {
          _setAnchor(_estimatedPositionMs(song), running: true, forceScroll: false);
        }
        _setTrackingStatus(
          widget.useMicrophone ? 'MIC AUDIO' : 'AUDIO',
          Colors.greenAccent,
        );
      } else {
        if (_clockRunning) {
          _setAnchor(_estimatedPositionMs(song), running: false, forceScroll: false);
        }
        _setTrackingStatus(
          phase == 'error' ? 'CAPTURE ERROR' :
          (_iosAudioSeen ? 'NO AUDIO' : 'WAIT AUDIO'),
          phase == 'error' ? Colors.redAccent : Colors.orangeAccent,
        );
      }
    } on PlatformException catch (e) {
      debugPrint('iOS audio activity tracking failed: $e');
      _setTrackingStatus('IOS ERROR', Colors.redAccent);
    } finally {
      _iosPollBusy = false;
    }
  }

  Future<void> _switchIOSSong(SyncedLyricsSong nextSong, double offset) async {
    // Re-read from disk to avoid using a stale library entry after editing.
    try {
      final loaded = await _lyricsService.loadSong(nextSong.jsonPath);
      if (!mounted || _openingEditor) return;
      final position = _clampPosition((offset * 1000).round(), loaded);
      final index = _lyricsService.findActiveLineIndex(loaded, position);
      _iosLastTrackSwitch = DateTime.now();
      _currentJsonPath = loaded.jsonPath;
      _lastScrolledIndex = -1;
      setState(() {
        _song = loaded;
        _activeLineIndex = index;
        _error = null;
      });
      // A different song's timeline must never inherit the previous clock.
      _setAnchor(position, running: true, forceScroll: false);
      _setTrackingStatus('NEW TRACK', Colors.greenAccent);
      _scheduleInitialScroll();
      debugPrint('iOS auto track switch: ${loaded.displayName} @ ${position}ms');
    } catch (error) {
      debugPrint('iOS auto track switch failed: $error');
      _setTrackingStatus('TRACK ERROR', Colors.orangeAccent);
    }
  }

  AndroidMediaSessionState? _selectAndroidMediaSession(
    List<AndroidMediaSessionState> sessions,
  ) {
    final song = _song;
    if (song == null) return null;

    final usable = sessions
        .where(
          (session) =>
              session.available &&
              (session.isPlaying || session.isPaused || session.isStopped),
        )
        .toList();

    if (usable.isEmpty) return null;

    AndroidMediaSessionState? bestMetadata;
    var bestScore = 0;

    for (final session in usable) {
      final score = _lyricsService.mediaMetadataScoreForSong(
        song,
        title: session.title,
        artist: session.artist,
        albumArtist: session.albumArtist,
      );

      if (score > bestScore) {
        bestScore = score;
        bestMetadata = session;
      }
    }

    if (bestMetadata != null && bestScore >= 70) {
      return bestMetadata;
    }

    final preferredApp = widget.mediaSourceAppId?.trim().toLowerCase();

    if (preferredApp != null && preferredApp.isNotEmpty) {
      final sameApp = usable
          .where(
            (session) =>
                session.sourceAppId.trim().toLowerCase() == preferredApp,
          )
          .toList();

      if (sameApp.isNotEmpty) {
        sameApp.sort((a, b) {
          final aRank = a.isPlaying ? 0 : (a.isPaused ? 1 : 2);
          final bRank = b.isPlaying ? 0 : (b.isPaused ? 1 : 2);
          return aRank.compareTo(bRank);
        });

        return sameApp.first;
      }
    }

    final active = usable
        .where((session) => session.isPlaying || session.isPaused)
        .toList();

    if (active.length == 1) {
      return active.first;
    }

    return null;
  }

  void _applyAndroidMediaSession(AndroidMediaSessionState session) {
    final song = _song;
    if (song == null) return;

    final rawPosition = _clampPosition(session.positionMs, song);
    final mediaPosition = _clampPosition(session.estimatedPositionMs, song);
    final isPlaying = session.isPlaying;
    final isPaused = session.isPaused || session.isStopped;

    if (isPaused) {
      final pausePosition =
          rawPosition > 0 ? rawPosition : _estimatedPositionMs(song);

      _lastMediaRawPositionMs = rawPosition;
      _lastMediaPlaying = false;

      _setAnchor(
        pausePosition,
        running: false,
        forceScroll: true,
      );

      _setTrackingStatus(
        'PAUSED',
        Colors.orangeAccent,
      );
      return;
    }

    if (!isPlaying) return;

    final predicted = _estimatedPositionMs(song);
    final previousRaw = _lastMediaRawPositionMs;
    final rawChanged = previousRaw == null ||
        (rawPosition - previousRaw).abs() >= _mediaRawChangeThresholdMs;
    final resuming = _lastMediaPlaying != true;

    if (resuming) {
      _setAnchor(
        mediaPosition,
        running: true,
        forceScroll: true,
      );
    } else if (rawChanged) {
      final drift = mediaPosition - predicted;

      if (drift.abs() >= _mediaHardSeekThresholdMs) {
        _setAnchor(
          mediaPosition,
          running: true,
          forceScroll: true,
        );
      } else if (drift.abs() >= 120) {
        final corrected =
            predicted + (drift * _mediaSoftCorrectionFactor).round();

        _setAnchor(
          corrected,
          running: true,
          forceScroll: false,
        );
      }
    }

    _lastMediaRawPositionMs = rawPosition;
    _lastMediaPlaying = true;

    _setTrackingStatus(
      'MEDIA',
      Colors.greenAccent,
    );
  }

  WindowsMediaSessionState? _selectMediaSession(
    List<WindowsMediaSessionState> sessions,
  ) {
    final song = _song;
    if (song == null) return null;

    final usable = sessions
        .where(
          (session) =>
              session.available &&
              (session.isPlaying || session.isPaused || session.isStopped),
        )
        .toList();

    if (usable.isEmpty) return null;

    // First choice: metadata that clearly matches the loaded song.
    WindowsMediaSessionState? bestMetadata;
    var bestScore = 0;

    for (final session in usable) {
      final score = _lyricsService.mediaMetadataScoreForSong(
        song,
        title: session.title,
        artist: session.artist,
        albumArtist: session.albumArtist,
      );

      if (score > bestScore) {
        bestScore = score;
        bestMetadata = session;
      }
    }

    if (bestMetadata != null && bestScore >= 70) {
      return bestMetadata;
    }

    // Second choice: the application that Home associated with this song.
    final preferredApp = widget.mediaSourceAppId?.trim().toLowerCase();

    if (preferredApp != null && preferredApp.isNotEmpty) {
      final sameApp = usable
          .where(
            (session) => session.sourceAppId.trim().toLowerCase() == preferredApp,
          )
          .toList();

      if (sameApp.isNotEmpty) {
        sameApp.sort((a, b) {
          final aRank = a.isPlaying ? 0 : (a.isPaused ? 1 : 2);
          final bRank = b.isPlaying ? 0 : (b.isPaused ? 1 : 2);
          return aRank.compareTo(bRank);
        });

        return sameApp.first;
      }
    }

    // The expected real-world use is one active player. If there is exactly
    // one active session, it is safe to use it even when metadata is empty.
    final active = usable.where((session) => session.isPlaying || session.isPaused).toList();

    if (active.length == 1) {
      return active.first;
    }

    return null;
  }

  void _applyMediaSession(WindowsMediaSessionState session) {
    final song = _song;
    if (song == null) return;

    final rawPosition = _clampPosition(session.positionMs, song);
    final mediaPosition = _clampPosition(session.estimatedPositionMs(), song);
    final isPlaying = session.isPlaying;
    final isPaused = session.isPaused || session.isStopped;

    if (isPaused) {
      final pausePosition = rawPosition > 0 ? rawPosition : _estimatedPositionMs(song);

      _lastMediaRawPositionMs = rawPosition;
      _lastMediaPlaying = false;

      _setAnchor(
        pausePosition,
        running: false,
        forceScroll: true,
      );

      _setTrackingStatus(
        'PAUSED',
        Colors.orangeAccent,
      );

      return;
    }

    if (!isPlaying) return;

    final predicted = _estimatedPositionMs(song);
    final previousRaw = _lastMediaRawPositionMs;
    final rawChanged = previousRaw == null ||
        (rawPosition - previousRaw).abs() >= _mediaRawChangeThresholdMs;

    final resuming = _lastMediaPlaying != true;

    if (resuming) {
      _setAnchor(
        mediaPosition,
        running: true,
        forceScroll: true,
      );
    } else if (rawChanged) {
      final drift = mediaPosition - predicted;

      if (drift.abs() >= _mediaHardSeekThresholdMs) {
        // Forward/backward seek: Windows position wins immediately.
        _setAnchor(
          mediaPosition,
          running: true,
          forceScroll: true,
        );
      } else if (drift.abs() >= 120) {
        final corrected =
            predicted + (drift * _mediaSoftCorrectionFactor).round();

        _setAnchor(
          corrected,
          running: true,
          forceScroll: false,
        );
      }
    }

    _lastMediaRawPositionMs = rawPosition;
    _lastMediaPlaying = true;

    _setTrackingStatus(
      'MEDIA',
      Colors.greenAccent,
    );
  }

  void _setAnchor(
    int positionMs, {
    required bool running,
    required bool forceScroll,
  }) {
    final song = _song;
    if (song == null) return;

    final position = _clampPosition(positionMs, song);
    final active = _lyricsService.findActiveLineIndex(song, position);
    final changed = active >= 0 && active != _activeLineIndex;

    _anchorPositionMs = position;
    _currentPositionMs = position;
    _clockRunning = running;

    _localClock
      ..stop()
      ..reset();

    if (running && position < song.durationMs) {
      _localClock.start();
    }

    if (mounted) {
      setState(() {
        if (active >= 0) {
          _activeLineIndex = active;
        }
      });
    }

    if (forceScroll && active >= 0) {
      _scrollToLine(active, force: true);
    } else if (changed) {
      _scrollToLine(active);
    }
  }

  void _setTrackingStatus(String label, Color color) {
    if (_trackingLabel == label && _trackingColor == color) return;
    if (!mounted) return;

    setState(() {
      _trackingLabel = label;
      _trackingColor = color;
    });

    final song = _song;
    if (Platform.isAndroid && song != null) {
      unawaited(_broadcastAndroidOverlay(song, force: true));
    }
  }

  Future<void> _ensureFingerprintFallback() async {
    if (!Platform.isWindows || _fallbackStarted || _openingEditor) return;

    try {
      await _fingerprintService.ensureReady();
      await _captureService.startContinuousCapture();

      _fallbackCaptureClock
        ..reset()
        ..start();

      _fallbackStarted = true;
      _fallbackPaused = false;
      _lastFallbackMeasuredMs = null;
      _fallbackStagnantMeasurements = 0;

      _fallbackTimer?.cancel();
      _fallbackTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _runFingerprintFallback(),
      );

      _setTrackingStatus(
        'FINGERPRINT',
        Colors.amberAccent,
      );
    } catch (e) {
      debugPrint('Fingerprint fallback unavailable: $e');
      _setTrackingStatus(
        'LOCAL',
        Colors.white54,
      );
    }
  }

  Future<void> _runFingerprintFallback() async {
    if (!_fallbackStarted ||
        _fallbackBusy ||
        _openingEditor ||
        _fallbackCaptureClock.elapsed < const Duration(seconds: 5)) {
      return;
    }

    final song = _song;
    if (song == null) return;

    _fallbackBusy = true;
    String? snapshotPath;

    try {
      final snapshot = await _captureService.snapshotContinuousCapture(
        last: const Duration(seconds: 5),
      );

      snapshotPath = snapshot.filePath;

      final result = await _fingerprintService.match(snapshot.filePath);
      final aligned = result.alignedHashes ?? 0;
      final common = result.commonHashes ?? 0;
      final ratio = common > 0 ? aligned / common : 0.0;

      final resultPath = _normalizeTrackIdentity(result.trackPath ?? '');
      final lockedPath = _normalizeTrackIdentity(widget.lockedTrackName);
      final resultName = _normalizeTrackIdentity(result.trackName ?? '');
      final songTitle = _normalizeTrackIdentity(song.title);

      final sameSong = result.matched &&
          ((resultPath.isNotEmpty && lockedPath.isNotEmpty && resultPath == lockedPath) ||
              (resultName.isNotEmpty && songTitle.isNotEmpty &&
                  (resultName.contains(songTitle) || songTitle.contains(resultName))));

      final reliable = sameSong &&
          result.offsetSeconds != null &&
          aligned >= _fallbackMinimumAlignedHashes &&
          ratio >= _fallbackMinimumRatio;

      if (!reliable) return;

      var measuredMs =
          ((result.offsetSeconds! + result.queryDuration) * 1000).round();
      measuredMs += result.roundTripTime.inMilliseconds;
      measuredMs = _clampPosition(measuredMs, song);

      final previous = _lastFallbackMeasuredMs;

      if (previous != null &&
          (measuredMs - previous).abs() < _fallbackStagnantToleranceMs) {
        _fallbackStagnantMeasurements++;
      } else {
        _fallbackStagnantMeasurements = 0;
      }

      _lastFallbackMeasuredMs = measuredMs;

      if (_fallbackStagnantMeasurements >= _fallbackStagnantBeforePause) {
        _fallbackPaused = true;
        _setAnchor(
          measuredMs,
          running: false,
          forceScroll: true,
        );
        _setTrackingStatus('FP PAUSED', Colors.orangeAccent);
        return;
      }

      if (_fallbackPaused) {
        _fallbackPaused = false;
        _setAnchor(
          measuredMs,
          running: true,
          forceScroll: true,
        );
        _setTrackingStatus('FINGERPRINT', Colors.amberAccent);
        return;
      }

      final predicted = _estimatedPositionMs(song);
      final error = measuredMs - predicted;

      if (error.abs() >= 1200) {
        _setAnchor(
          measuredMs,
          running: true,
          forceScroll: true,
        );
      } else if (error.abs() >= 300) {
        _setAnchor(
          predicted + (error * 0.35).round(),
          running: true,
          forceScroll: false,
        );
      }
    } catch (e) {
      debugPrint('Fingerprint fallback error: $e');
    } finally {
      if (snapshotPath != null) {
        await _deleteFile(snapshotPath);
      }
      _fallbackBusy = false;
    }
  }

  Future<void> _stopFingerprintFallback() async {
    if (!_fallbackStarted) return;

    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _fallbackStarted = false;
    _fallbackPaused = false;

    _fallbackCaptureClock
      ..stop()
      ..reset();

    try {
      await _captureService.stopContinuousCapture();
    } catch (_) {}
  }

  Future<void> _openEditor() async {
    if (_openingEditor) return;

    setState(() {
      _openingEditor = true;
    });

    _uiTimer?.cancel();
    _mediaTimer?.cancel();
    await _stopFingerprintFallback();

    _localClock.stop();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LyricsEditScreen(
          jsonPath: _currentJsonPath,
        ),
      ),
    );

    if (!mounted) return;

    try {
      final updatedSong = await _lyricsService.loadSong(_currentJsonPath);
      final safePosition = _clampPosition(_currentPositionMs, updatedSong);
      final active =
          _lyricsService.findActiveLineIndex(updatedSong, safePosition);

      setState(() {
        _song = updatedSong;
        _activeLineIndex = active;
        _openingEditor = false;
        _error = null;
      });

      _setAnchor(
        safePosition,
        running: false,
        forceScroll: true,
      );

      _lastMediaRawPositionMs = null;
      _lastMediaPlaying = null;
      _lastMediaSeenAt = null;

      _startUiTimer();
      _startMediaTimer();
      await _pollMediaSession();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _openingEditor = false;
        _error = e.toString();
      });
    }
  }

  int _clampPosition(int value, SyncedLyricsSong song) {
    final maximum = song.durationMs > 0 ? song.durationMs : value;
    return value.clamp(0, maximum).toInt();
  }

  void _scheduleInitialScroll([int attempt = 0]) {
    if (attempt > 15) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (_scrollController.isAttached) {
        _jumpToInitialLine();
        return;
      }

      Future.delayed(const Duration(milliseconds: 80), () {
        if (mounted) {
          _scheduleInitialScroll(attempt + 1);
        }
      });
    });
  }

  void _jumpToInitialLine() {
    final song = _song;
    if (song == null || !_scrollController.isAttached) return;

    final index = _activeLineIndex >= 0
        ? _activeLineIndex
        : _lyricsService.findNearestLineIndex(song, _currentPositionMs);

    if (index < 0) return;

    _lastScrolledIndex = index;

    _scrollController.jumpTo(
      index: index,
      alignment: 0.45,
    );
  }

  void _scrollToLine(
    int index, {
    bool force = false,
  }) {
    if (index < 0 || !_scrollController.isAttached) return;
    if (!force && index == _lastScrolledIndex) return;

    _lastScrolledIndex = index;

    _scrollController.scrollTo(
      index: index,
      alignment: 0.45,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  String _normalizeTrackIdentity(String value) {
    return value
        .replaceAll('\\', '/')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '')
        .trim();
  }

  Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  String _formatTime(int milliseconds) {
    final totalSeconds = milliseconds ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiTimer?.cancel();
    _mediaTimer?.cancel();
    _fallbackTimer?.cancel();
    _localClock.stop();
    _fallbackCaptureClock.stop();

    if (Platform.isWindows) {
      _captureService.stopContinuousCapture();
      _fingerprintService.dispose();
    }

    unawaited(
      _restoreNormalWindowMode(),
    );

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = _song;
    final backgroundOpacity =
        (_backgroundOpacityPercent / 100.0).clamp(0.0, 1.0).toDouble();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: backgroundOpacity),
            ),
          ),
          SafeArea(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  )
                : song == null
                    ? const Center(child: CircularProgressIndicator())
                    : Column(
                        children: [
                          _buildHeader(song),
                          Expanded(child: _buildLyrics(song)),
                        ],
                      ),
          ),
          if (Platform.isWindows) ..._buildResizeHandles(),
        ],
      ),
    );
  }

  Widget _buildHeader(SyncedLyricsSong song) {
    if (Platform.isAndroid || MediaQuery.sizeOf(context).width < 600) {
      return _buildMobileHeader(song);
    }

    return _buildDesktopHeader(song);
  }

  Widget _buildMobileHeader(SyncedLyricsSong song) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.10),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Back',
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (song.artist.isNotEmpty)
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatTime(_currentPositionMs),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _trackingColor,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _trackingLabel,
                        style: TextStyle(
                          color: _trackingColor.withValues(alpha: 0.82),
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text(
                'BACKGROUND',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 13,
                    ),
                  ),
                  child: Slider(
                    min: 0,
                    max: 100,
                    divisions: 100,
                    value: _backgroundOpacityPercent,
                    onChanged: (value) {
                      setState(() {
                        _backgroundOpacityPercent = value;
                      });

                      if (Platform.isAndroid) {
                        unawaited(
                          _androidOverlayService.setBackground(value),
                        );
                      }
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 42,
                child: Text(
                  '${_backgroundOpacityPercent.round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (Platform.isAndroid)
                TextButton.icon(
                  onPressed: _forceOpenAndroidOverlay,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 17),
                  label: const Text(
                    'FLOAT',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Calibrate',
                visualDensity: VisualDensity.compact,
                onPressed: _openingEditor ? null : _openEditor,
                icon: const Icon(Icons.tune_rounded, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopHeader(SyncedLyricsSong song) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.10),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.38),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) {
                      if (Platform.isWindows) {
                        windowManager.startDragging();
                      }
                    },
                    child: Container(
                      constraints: const BoxConstraints(
                        minHeight: 50,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      color: Colors.transparent,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.open_with_rounded,
                            color: Colors.white54,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (song.artist.isNotEmpty)
                                  Text(
                                    song.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 13,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _openingEditor ? null : _openEditor,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.black.withValues(alpha: 0.30),
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
                icon: const Icon(Icons.tune_rounded, size: 17),
                label: const Text('CALIBRATE'),
              ),
              const SizedBox(width: 14),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatTime(_currentPositionMs),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _trackingColor,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _trackingLabel,
                          style: TextStyle(
                            color: _trackingColor.withValues(alpha: 0.82),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(width: 4),
              const Icon(
                Icons.opacity_rounded,
                size: 17,
                color: Colors.white60,
              ),
              const SizedBox(width: 7),
              const Text(
                'BACKGROUND',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 13,
                    ),
                  ),
                  child: Slider(
                    min: 0,
                    max: 100,
                    divisions: 100,
                    value: _backgroundOpacityPercent,
                    onChanged: (value) {
                      setState(() {
                        _backgroundOpacityPercent = value;
                      });
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 46,
                child: Text(
                  '${_backgroundOpacityPercent.round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildResizeHandles() {
    const edge = 6.0;
    const corner = 14.0;

    return [
      _resizeHandle(
        left: 0,
        top: corner,
        bottom: corner,
        width: edge,
        resizeEdge: ResizeEdge.left,
        cursor: SystemMouseCursors.resizeLeftRight,
      ),
      _resizeHandle(
        right: 0,
        top: corner,
        bottom: corner,
        width: edge,
        resizeEdge: ResizeEdge.right,
        cursor: SystemMouseCursors.resizeLeftRight,
      ),
      _resizeHandle(
        left: corner,
        right: corner,
        top: 0,
        height: edge,
        resizeEdge: ResizeEdge.top,
        cursor: SystemMouseCursors.resizeUpDown,
      ),
      _resizeHandle(
        left: corner,
        right: corner,
        bottom: 0,
        height: edge,
        resizeEdge: ResizeEdge.bottom,
        cursor: SystemMouseCursors.resizeUpDown,
      ),
      _resizeHandle(
        left: 0,
        top: 0,
        width: corner,
        height: corner,
        resizeEdge: ResizeEdge.topLeft,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
      ),
      _resizeHandle(
        right: 0,
        top: 0,
        width: corner,
        height: corner,
        resizeEdge: ResizeEdge.topRight,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
      ),
      _resizeHandle(
        left: 0,
        bottom: 0,
        width: corner,
        height: corner,
        resizeEdge: ResizeEdge.bottomLeft,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
      ),
      _resizeHandle(
        right: 0,
        bottom: 0,
        width: corner,
        height: corner,
        resizeEdge: ResizeEdge.bottomRight,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
      ),
    ];
  }

  Widget _resizeHandle({
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
    required ResizeEdge resizeEdge,
    required MouseCursor cursor,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) {
            windowManager.startResizing(resizeEdge);
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _buildLyrics(SyncedLyricsSong song) {
    return ScrollablePositionedList.builder(
      itemScrollController: _scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: 42,
        vertical: 180,
      ),
      itemCount: song.lines.length,
      itemBuilder: (context, index) {
        final line = song.lines[index];
        final active = index == _activeLineIndex;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            line.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: active ? Colors.white : Colors.white30,
              fontSize: active ? 32 : 25,
              height: 1.25,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        );
      },
    );
  }
}
