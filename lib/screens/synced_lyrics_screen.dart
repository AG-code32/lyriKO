import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:window_manager/window_manager.dart';

import '../services/fingerprint_match_service.dart';
import '../services/synced_lyrics_service.dart';
import '../services/system_audio_capture_service.dart';
import '../services/windows_media_session_service.dart';
import 'lyrics_edit_screen.dart';

class SyncedLyricsScreen extends StatefulWidget {
  final int initialPositionMs;
  final String lockedTrackName;
  final String jsonPath;

  /// When Home found a Windows Media Session, it passes the owning app here.
  /// Example: chrome.exe or Spotify.exe.
  final String? mediaSourceAppId;

  const SyncedLyricsScreen({
    super.key,
    required this.initialPositionMs,
    required this.lockedTrackName,
    required this.jsonPath,
    this.mediaSourceAppId,
  });

  @override
  State<SyncedLyricsScreen> createState() => _SyncedLyricsScreenState();
}

class _SyncedLyricsScreenState extends State<SyncedLyricsScreen> {
  final SyncedLyricsService _lyricsService = SyncedLyricsService();
  final WindowsMediaSessionService _mediaService =
      WindowsMediaSessionService();
  final FingerprintMatchService _fingerprintService = FingerprintMatchService();
  final SystemAudioCaptureService _captureService = SystemAudioCaptureService();
  final ItemScrollController _scrollController = ItemScrollController();

  SyncedLyricsSong? _song;

  Timer? _uiTimer;
  Timer? _mediaTimer;
  Timer? _fallbackTimer;

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

    _anchorPositionMs = widget.initialPositionMs;
    _currentPositionMs = widget.initialPositionMs;

    _enterLyricsOverlayMode();
    _load();
  }

  Future<void> _enterLyricsOverlayMode() async {
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

  Future<void> _restoreNormalWindowMode() async {
    if (!_overlayModeActive) {
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
      final song = await _lyricsService.loadSong(widget.jsonPath);

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

      _setAnchor(safePosition, running: true, forceScroll: false);

      await _mediaService.initialize();

      _startUiTimer();
      _startMediaTimer();
      _scheduleInitialScroll();

      // Poll immediately rather than waiting for the first timer tick.
      await _pollMediaSession();
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

      await _ensureFingerprintFallback();
    } finally {
      _mediaPollBusy = false;
    }
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
  }

  Future<void> _ensureFingerprintFallback() async {
    if (_fallbackStarted || _openingEditor) return;

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
          jsonPath: widget.jsonPath,
        ),
      ),
    );

    if (!mounted) return;

    try {
      final updatedSong = await _lyricsService.loadSong(widget.jsonPath);
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
    _uiTimer?.cancel();
    _mediaTimer?.cancel();
    _fallbackTimer?.cancel();

    _localClock.stop();
    _fallbackCaptureClock.stop();

    _captureService.stopContinuousCapture();
    _fingerprintService.dispose();

    unawaited(
      _restoreNormalWindowMode(),
    );

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = _song;
    final backgroundOpacity =
        (_backgroundOpacityPercent / 100.0).clamp(0.0, 1.0);

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
          ..._buildResizeHandles(),
        ],
      ),
    );
  }

  Widget _buildHeader(SyncedLyricsSong song) {
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
                      windowManager.startDragging();
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
