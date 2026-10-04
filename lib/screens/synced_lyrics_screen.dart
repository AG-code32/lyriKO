import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../services/fingerprint_match_service.dart';
import '../services/synced_lyrics_service.dart';
import '../services/system_audio_capture_service.dart';

class SyncedLyricsScreen
    extends StatefulWidget {
  final int initialPositionMs;

  final String lockedTrackName;

  const SyncedLyricsScreen({
    super.key,
    required this.initialPositionMs,
    required this.lockedTrackName,
  });

  @override
  State<SyncedLyricsScreen>
      createState() =>
          _SyncedLyricsScreenState();
}

class _SyncedLyricsScreenState
    extends State<
        SyncedLyricsScreen> {
  final SyncedLyricsService
      _lyricsService =
      SyncedLyricsService();

  final FingerprintMatchService
      _fingerprintService =
      FingerprintMatchService();

  final SystemAudioCaptureService
      _captureService =
      SystemAudioCaptureService();

  final ItemScrollController
      _scrollController =
      ItemScrollController();

  SyncedLyricsSong? _song;

  Timer? _uiTimer;
  Timer? _trackingTimer;

  final Stopwatch _localClock =
      Stopwatch();

  final Stopwatch _captureClock =
      Stopwatch();

  int _basePositionMs = 0;

  int _currentPositionMs = 0;

  int _activeLineIndex = -1;

  int _lastScrolledIndex = -1;

  bool _playing = true;

  bool _trackingBusy = false;

  int _consecutiveMisses = 0;

  int? _lastMeasuredPositionMs;

  int _stagnantMeasurements = 0;

  String? _error;

  static const Duration
      _trackingWindow =
      Duration(seconds: 3);

  static const Duration
      _trackingInterval =
      Duration(seconds: 2);

  static const int
      _ignoreErrorMs = 400;

  static const int
      _hardCorrectionMs = 1500;

  static const double
      _softCorrectionFactor = 0.35;

  @override
  void initState() {
    super.initState();

    _basePositionMs =
        widget.initialPositionMs;

    _currentPositionMs =
        widget.initialPositionMs;

    _load();
  }

  Future<void> _load() async {
    try {
      final song =
          await _lyricsService
              .loadNobody();

      _currentPositionMs =
          _currentPositionMs.clamp(
        0,
        song.durationMs,
      );

      _basePositionMs =
          _currentPositionMs;

      var active =
          _lyricsService
              .findActiveLineIndex(
        song,
        _currentPositionMs,
      );

      if (active < 0) {
        active =
            _lyricsService
                .findNearestLineIndex(
          song,
          _currentPositionMs,
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _song = song;

        _activeLineIndex =
            active;
      });

      await _fingerprintService
          .ensureReady();

      await _captureService
          .startContinuousCapture();

      _captureClock.start();

      _localClock.start();

      _uiTimer =
          Timer.periodic(
        const Duration(
          milliseconds: 40,
        ),
        (_) {
          _updateLocalPosition();
        },
      );

      _trackingTimer =
          Timer.periodic(
        _trackingInterval,
        (_) {
          _trackRealPosition();
        },
      );

      _scheduleInitialScroll();
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error =
            e.toString();
      });
    }
  }

  void _scheduleInitialScroll([
    int attempt = 0,
  ]) {
    if (attempt > 15) {
      return;
    }

    WidgetsBinding.instance
        .addPostFrameCallback(
      (_) {
        if (!mounted) {
          return;
        }

        if (_scrollController
            .isAttached) {
          _jumpToInitialLine();

          return;
        }

        Future.delayed(
          const Duration(
            milliseconds: 80,
          ),
          () {
            if (mounted) {
              _scheduleInitialScroll(
                attempt + 1,
              );
            }
          },
        );
      },
    );
  }

  void _updateLocalPosition() {
    final song =
        _song;

    if (song == null ||
        !mounted ||
        !_playing) {
      return;
    }

    var position =
        _basePositionMs +
        _localClock
            .elapsedMilliseconds;

    if (position >=
        song.durationMs) {
      position =
          song.durationMs;

      _playing = false;

      _localClock.stop();
    }

    final active =
        _lyricsService
            .findActiveLineIndex(
      song,
      position,
    );

    final changed =
        active >= 0 &&
        active !=
            _activeLineIndex;

    setState(() {
      _currentPositionMs =
          position;

      if (active >= 0) {
        _activeLineIndex =
            active;
      }
    });

    if (changed) {
      _scrollToLine(
        active,
      );
    }
  }

  Future<void>
      _trackRealPosition() async {
    if (_trackingBusy) {
      return;
    }

    if (_captureClock.elapsed <
        _trackingWindow) {
      return;
    }

    final song =
        _song;

    if (song == null) {
      return;
    }

    _trackingBusy = true;

    String? snapshotPath;

    try {
      final snapshot =
          await _captureService
              .snapshotContinuousCapture(
        last:
            _trackingWindow,
      );

      snapshotPath =
          snapshot.filePath;

      final result =
          await _fingerprintService
              .match(
        snapshot.filePath,
      );

      final trackName =
          (result.trackName ?? '')
              .toLowerCase();

      final lockedName =
          widget.lockedTrackName
              .toLowerCase();

      final sameSong =
          result.matched &&
          trackName.contains(
            lockedName,
          );

      final aligned =
          result.alignedHashes ??
              0;

      final common =
          result.commonHashes ??
              0;

      final ratio =
          common > 0
              ? aligned / common
              : 0.0;

      final reliable =
          sameSong &&
          aligned >= 5 &&
          ratio >= 0.50 &&
          result.offsetSeconds !=
              null;

      if (!reliable) {
        _registerTrackingMiss();

        return;
      }

      _consecutiveMisses = 0;

      var measuredMs =
          ((result.offsetSeconds! +
                      result.queryDuration) *
                  1000)
              .round();

      measuredMs +=
          result.roundTripTime
              .inMilliseconds;

      measuredMs =
          measuredMs.clamp(
        0,
        song.durationMs,
      );

      final previous =
          _lastMeasuredPositionMs;

      if (previous != null) {
        final movement =
            measuredMs -
            previous;

        if (movement.abs() <
            350) {
          _stagnantMeasurements++;
        } else {
          _stagnantMeasurements =
              0;
        }
      }

      _lastMeasuredPositionMs =
          measuredMs;

      if (_stagnantMeasurements >=
          1) {
        _freezeAtPosition(
          measuredMs,
        );

        return;
      }

      if (!_playing) {
        _setRealPosition(
          measuredMs,
          forceScroll: true,
        );

        return;
      }

      final error =
          measuredMs -
          _currentPositionMs;

      final absoluteError =
          error.abs();

      if (absoluteError <
          _ignoreErrorMs) {
        return;
      }

      if (absoluteError >=
          _hardCorrectionMs) {
        _setRealPosition(
          measuredMs,
          forceScroll: true,
        );

        return;
      }

      final correction =
          (error *
                  _softCorrectionFactor)
              .round();

      _applySoftCorrection(
        correction,
      );
    } catch (_) {
      _registerTrackingMiss();
    } finally {
      if (snapshotPath != null) {
        await _deleteFile(
          snapshotPath,
        );
      }

      _trackingBusy = false;
    }
  }

  void _registerTrackingMiss() {
    _consecutiveMisses++;

    if (_consecutiveMisses >= 2) {
      _freezePlayback();
    }
  }

  void _applySoftCorrection(
    int correctionMs,
  ) {
    final song =
        _song;

    if (song == null) {
      return;
    }

    final corrected =
        (_currentPositionMs +
                correctionMs)
            .clamp(
      0,
      song.durationMs,
    );

    _basePositionMs =
        corrected;

    _currentPositionMs =
        corrected;

    _localClock
      ..stop()
      ..reset()
      ..start();

    final active =
        _lyricsService
            .findActiveLineIndex(
      song,
      corrected,
    );

    if (active >= 0 &&
        active !=
            _activeLineIndex) {
      setState(() {
        _activeLineIndex =
            active;
      });

      _scrollToLine(
        active,
      );
    }
  }

  void _setRealPosition(
    int positionMs, {
    required bool forceScroll,
  }) {
    final song =
        _song;

    if (song == null ||
        !mounted) {
      return;
    }

    final position =
        positionMs.clamp(
      0,
      song.durationMs,
    );

    _basePositionMs =
        position;

    _currentPositionMs =
        position;

    _localClock
      ..stop()
      ..reset();

    if (position <
        song.durationMs) {
      _playing = true;

      _localClock.start();
    } else {
      _playing = false;
    }

    var active =
        _lyricsService
            .findActiveLineIndex(
      song,
      position,
    );

    if (active < 0) {
      active =
          _lyricsService
              .findNearestLineIndex(
        song,
        position,
      );
    }

    final changed =
        active >= 0 &&
        active !=
            _activeLineIndex;

    setState(() {
      if (active >= 0) {
        _activeLineIndex =
            active;
      }
    });

    if (forceScroll &&
        active >= 0) {
      _scrollToLine(
        active,
        force: true,
      );
    } else if (changed) {
      _scrollToLine(
        active,
      );
    }
  }

  void _freezeAtPosition(
    int positionMs,
  ) {
    final song =
        _song;

    if (song == null) {
      return;
    }

    final position =
        positionMs.clamp(
      0,
      song.durationMs,
    );

    _basePositionMs =
        position;

    _currentPositionMs =
        position;

    _localClock
      ..stop()
      ..reset();

    if (!mounted) {
      return;
    }

    setState(() {
      _playing = false;
    });
  }

  void _freezePlayback() {
    if (!_playing) {
      return;
    }

    _basePositionMs =
        _currentPositionMs;

    _localClock
      ..stop()
      ..reset();

    if (!mounted) {
      return;
    }

    setState(() {
      _playing = false;
    });
  }

  void _jumpToInitialLine() {
    final song =
        _song;

    if (song == null ||
        !_scrollController
            .isAttached) {
      return;
    }

    var index =
        _activeLineIndex;

    if (index < 0) {
      index =
          _lyricsService
              .findNearestLineIndex(
        song,
        _currentPositionMs,
      );
    }

    if (index < 0) {
      return;
    }

    _lastScrolledIndex =
        index;

    _scrollController.jumpTo(
      index: index,
      alignment: 0.45,
    );
  }

  void _scrollToLine(
    int index, {
    bool force = false,
  }) {
    if (index < 0) {
      return;
    }

    if (!force &&
        index ==
            _lastScrolledIndex) {
      return;
    }

    if (!_scrollController
        .isAttached) {
      return;
    }

    _lastScrolledIndex =
        index;

    _scrollController.scrollTo(
      index: index,
      alignment: 0.45,
      duration:
          const Duration(
        milliseconds: 420,
      ),
      curve:
          Curves.easeOutCubic,
    );
  }

  Future<void> _deleteFile(
    String path,
  ) async {
    try {
      final file =
          File(path);

      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  String _formatTime(
    int milliseconds,
  ) {
    final totalSeconds =
        milliseconds ~/ 1000;

    final minutes =
        totalSeconds ~/ 60;

    final seconds =
        totalSeconds % 60;

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _uiTimer?.cancel();

    _trackingTimer?.cancel();

    _localClock.stop();

    _captureClock.stop();

    _captureService
        .stopContinuousCapture();

    _fingerprintService.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final song =
        _song;

    return Scaffold(
      backgroundColor:
          const Color(
        0xFF080808,
      ),
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Text(
                  _error!,
                  style:
                      const TextStyle(
                    color:
                        Colors.redAccent,
                  ),
                ),
              )
            : song == null
                ? const Center(
                    child:
                        CircularProgressIndicator(),
                  )
                : Column(
                    children: [
                      _buildHeader(
                        song,
                      ),

                      Expanded(
                        child:
                            _buildLyrics(
                          song,
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _buildHeader(
    SyncedLyricsSong song,
  ) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(
        24,
        18,
        24,
        12,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              Navigator.pop(
                context,
              );
            },
            icon:
                const Icon(
              Icons.arrow_back_rounded,
            ),
          ),

          const SizedBox(
            width: 12,
          ),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style:
                      const TextStyle(
                    color:
                        Colors.white,
                    fontSize: 22,
                    fontWeight:
                        FontWeight.w700,
                  ),
                ),

                Text(
                  song.artist,
                  style:
                      const TextStyle(
                    color:
                        Colors.white54,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),

          Column(
            crossAxisAlignment:
                CrossAxisAlignment.end,
            children: [
              Text(
                _formatTime(
                  _currentPositionMs,
                ),
                style:
                    const TextStyle(
                  color:
                      Colors.white70,
                  fontSize: 15,
                  fontFeatures: [
                    FontFeature
                        .tabularFigures(),
                  ],
                ),
              ),

              Text(
                _playing
                    ? 'SYNC'
                    : 'HOLD',
                style:
                    const TextStyle(
                  color:
                      Colors.white30,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLyrics(
    SyncedLyricsSong song,
  ) {
    return ScrollablePositionedList
        .builder(
      itemScrollController:
          _scrollController,

      padding:
          const EdgeInsets.symmetric(
        horizontal: 42,
        vertical: 180,
      ),

      itemCount:
          song.lines.length,

      itemBuilder: (
        context,
        index,
      ) {
        final line =
            song.lines[index];

        final active =
            index ==
                _activeLineIndex;

        return Padding(
          padding:
              const EdgeInsets.symmetric(
            vertical: 12,
          ),
          child: active
              ? _buildActiveLine(
                  line,
                )
              : Text(
                  line.text,
                  textAlign:
                      TextAlign.center,
                  style:
                      const TextStyle(
                    color:
                        Colors.white30,
                    fontSize: 25,
                    height: 1.25,
                    fontWeight:
                        FontWeight.w500,
                  ),
                ),
        );
      },
    );
  }

  Widget _buildActiveLine(
    SyncedLyricLine line,
  ) {
    // Word-level karaoke highlighting is intentionally disabled.
    // The calibrated line startMs is the only timing used for display.
    return Text(
      line.text,
      textAlign:
          TextAlign.center,
      style:
          const TextStyle(
        color:
            Colors.white,
        fontSize: 32,
        height: 1.25,
        fontWeight:
            FontWeight.w700,
      ),
    );
  }
}