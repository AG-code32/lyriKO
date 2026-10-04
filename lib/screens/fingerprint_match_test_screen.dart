import 'dart:io';

import 'package:flutter/material.dart';

import '../services/fingerprint_match_service.dart';
import '../services/lyrics_sync_builder_service.dart';
import '../services/synced_lyrics_service.dart';
import '../services/system_audio_capture_service.dart';
import 'lyrics_calibration_screen.dart';
import 'synced_lyrics_screen.dart';

class FingerprintMatchTestScreen
    extends StatefulWidget {
  const FingerprintMatchTestScreen({
    super.key,
  });

  @override
  State<FingerprintMatchTestScreen>
      createState() =>
          _FingerprintMatchTestScreenState();
}

class _FingerprintMatchTestScreenState
    extends State<FingerprintMatchTestScreen>
    with SingleTickerProviderStateMixin {
  final SystemAudioCaptureService
      _captureService =
      SystemAudioCaptureService();

  final FingerprintMatchService
      _fingerprintService =
      FingerprintMatchService();

  final LyricsSyncBuilderService
      _syncBuilder =
      LyricsSyncBuilderService();

  final SyncedLyricsService
      _syncedLyricsService =
      SyncedLyricsService();

  static const List<int>
      _attemptSeconds = [
    2,
    3,
    4,
    5,
    7,
    10,
    15,
    20,
    25,
  ];

  static const int
      _minimumAlignedHashes = 5;

  static const double
      _minimumHashRatio = 0.50;

  late AnimationController
      _listenAnimation;

  FingerprintEngineInfo?
      _engineInfo;

  bool _running = false;

  bool _rebuildingAlignment = false;

  bool _reloadingSync = false;

  String _message =
      'Tap to identify a song';

  String? _error;

  @override
  void initState() {
    super.initState();

    _listenAnimation =
        AnimationController(
      vsync: this,
      duration:
          const Duration(
        milliseconds: 1300,
      ),
    );

    _warmUpEngine();
  }

  Future<void> _warmUpEngine() async {
    try {
      final info =
          await _fingerprintService
              .ensureReady();

      if (!mounted) {
        return;
      }

      setState(() {
        _engineInfo = info;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error =
            e.toString();

        _message =
            'Fingerprint engine unavailable';
      });
    }
  }

  int _windowForAttempt(
    int second,
  ) {
    if (second <= 5) {
      return second;
    }

    return 5;
  }

  Future<void>
      _rebuildNobodyAlignment() async {
    if (_running ||
        _rebuildingAlignment ||
        _reloadingSync) {
      return;
    }

    setState(() {
      _rebuildingAlignment =
          true;

      _error = null;

      _message =
          'Rebuilding Nobody alignment...';
    });

    final result =
        await _syncBuilder
            .rebuildNobody();

    if (!mounted) {
      return;
    }

    setState(() {
      _rebuildingAlignment =
          false;

      if (result.success) {
        _message =
            'Nobody alignment updated';
      } else {
        _message =
            'Alignment rebuild failed';

        _error =
            result.message;
      }
    });

    if (result.success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: Text(
            'Nobody alignment rebuilt in '
            '${result.elapsed.inSeconds}s',
          ),
        ),
      );
    }
  }

  Future<void>
      _reloadNobodySync() async {
    if (_running ||
        _rebuildingAlignment ||
        _reloadingSync) {
      return;
    }

    setState(() {
      _reloadingSync =
          true;

      _error = null;

      _message =
          'Reloading Nobody sync...';
    });

    try {
      final song =
          await _syncedLyricsService
              .loadNobody();

      if (!mounted) {
        return;
      }

      setState(() {
        _reloadingSync =
            false;

        _message =
            'Nobody sync reloaded';
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: Text(
            'Reloaded '
            '${song.lines.length} '
            'synced lyric lines',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _reloadingSync =
            false;

        _message =
            'Could not reload sync';

        _error =
            e.toString();
      });
    }
  }

  Future<void>
      _openCalibration() async {
    if (_running ||
        _rebuildingAlignment ||
        _reloadingSync) {
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) =>
                const LyricsCalibrationScreen(),
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _message =
          'Calibration changes saved';
    });
  }

  Future<void> _startListening() async {
    if (_running ||
        _rebuildingAlignment ||
        _reloadingSync ||
        _engineInfo == null) {
      return;
    }

    setState(() {
      _running = true;

      _error = null;

      _message =
          'Listening...';
    });

    _listenAnimation.repeat(
      reverse: true,
    );

    final totalWatch =
        Stopwatch()..start();

    bool captureStarted = false;

    try {
      await _fingerprintService
          .ensureReady();

      await _captureService
          .startContinuousCapture();

      captureStarted = true;

      for (final targetSecond
          in _attemptSeconds) {
        final target =
            Duration(
          seconds:
              targetSecond,
        );

        final remaining =
            target -
                totalWatch.elapsed;

        if (!remaining.isNegative) {
          await Future.delayed(
            remaining,
          );
        }

        if (!mounted) {
          return;
        }

        final windowSeconds =
            _windowForAttempt(
          targetSecond,
        );

        final snapshot =
            await _captureService
                .snapshotContinuousCapture(
          last:
              Duration(
            seconds:
                windowSeconds,
          ),
        );

        try {
          final result =
              await _fingerprintService
                  .match(
            snapshot.filePath,
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

          final accepted =
              result.matched &&
              aligned >=
                  _minimumAlignedHashes &&
              ratio >=
                  _minimumHashRatio &&
              result.offsetSeconds !=
                  null;

          if (!accepted) {
            continue;
          }

          totalWatch.stop();

          final trackName =
              result.trackName ??
                  '';

          final lowerTrackName =
              trackName.toLowerCase();

          final currentMs =
              ((result.offsetSeconds! +
                          result.queryDuration) *
                      1000)
                  .round() +
              result.roundTripTime
                  .inMilliseconds;

          await _captureService
              .stopContinuousCapture();

          captureStarted = false;

          if (!mounted) {
            return;
          }

          if (lowerTrackName.contains(
            'nobody',
          )) {
            _listenAnimation.stop();

            setState(() {
              _message =
                  'Nobody';
            });

            await Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    (_) =>
                        SyncedLyricsScreen(
                  initialPositionMs:
                      currentMs,
                  lockedTrackName:
                      'nobody',
                ),
              ),
            );

            if (!mounted) {
              return;
            }

            setState(() {
              _message =
                  'Tap to identify a song';
            });

            return;
          }

          _listenAnimation.stop();

          setState(() {
            _message =
                'Song found, but synchronized '
                'lyrics are not available yet';
          });

          return;
        } finally {
          await _deleteFile(
            snapshot.filePath,
          );
        }
      }

      if (mounted) {
        setState(() {
          _message =
              'No song found';
        });
      }
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error =
            e.toString();

        _message =
            'Could not identify the song';
      });
    } finally {
      if (captureStarted) {
        try {
          await _captureService
              .stopContinuousCapture();
        } catch (_) {}
      }

      _listenAnimation.stop();

      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
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

  @override
  void dispose() {
    _listenAnimation.dispose();

    _fingerprintService.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final busy =
        _running ||
        _rebuildingAlignment ||
        _reloadingSync;

    return Scaffold(
      backgroundColor:
          const Color(
        0xFF080808,
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding:
                const EdgeInsets.all(
              32,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  const Text(
                    'Lyriko',
                    style:
                        TextStyle(
                      color:
                          Colors.white,
                      fontSize: 44,
                      fontWeight:
                          FontWeight.w800,
                      letterSpacing:
                          -1.5,
                    ),
                  ),

                  const SizedBox(
                    height: 18,
                  ),

                  Text(
                    _message,
                    textAlign:
                        TextAlign.center,
                    style:
                        const TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 16,
                    ),
                  ),

                  const SizedBox(
                    height: 55,
                  ),

                  AnimatedBuilder(
                    animation:
                        _listenAnimation,
                    builder: (
                      context,
                      child,
                    ) {
                      final animation =
                          _running
                              ? _listenAnimation
                                  .value
                              : 0.0;

                      final glow =
                          25.0 +
                          animation *
                              45;

                      final spread =
                          2.0 +
                          animation *
                              12;

                      final scale =
                          1.0 +
                          animation *
                              0.05;

                      return Transform.scale(
                        scale:
                            scale,
                        child:
                            Container(
                          width: 180,
                          height: 180,
                          decoration:
                              BoxDecoration(
                            shape:
                                BoxShape
                                    .circle,
                            boxShadow:
                                _running
                                    ? [
                                        BoxShadow(
                                          color:
                                              Colors.white.withValues(
                                            alpha:
                                                0.16 +
                                                animation *
                                                    0.14,
                                          ),
                                          blurRadius:
                                              glow,
                                          spreadRadius:
                                              spread,
                                        ),
                                      ]
                                    : null,
                          ),
                          child:
                              Material(
                            shape:
                                const CircleBorder(),
                            color:
                                const Color(
                              0xFF181818,
                            ),
                            child:
                                InkWell(
                              customBorder:
                                  const CircleBorder(),
                              onTap:
                                  busy ||
                                          _engineInfo ==
                                              null
                                      ? null
                                      : _startListening,
                              child:
                                  Center(
                                child:
                                    _running
                                        ? const SizedBox(
                                            width:
                                                54,
                                            height:
                                                54,
                                            child:
                                                CircularProgressIndicator(
                                              strokeWidth:
                                                  3,
                                              color:
                                                  Colors.white,
                                            ),
                                          )
                                        : const Icon(
                                            Icons
                                                .graphic_eq_rounded,
                                            size:
                                                72,
                                            color:
                                                Colors.white,
                                          ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(
                    height: 40,
                  ),

                  FilledButton.tonalIcon(
                    onPressed:
                        busy
                            ? null
                            : _openCalibration,
                    icon:
                        const Icon(
                      Icons
                          .tune_rounded,
                    ),
                    label:
                        const Padding(
                      padding:
                          EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 8,
                      ),
                      child: Text(
                        'CALIBRATE NOBODY SYNC',
                      ),
                    ),
                  ),

                  const SizedBox(
                    height: 12,
                  ),

                  FilledButton.tonalIcon(
                    onPressed:
                        busy
                            ? null
                            : _rebuildNobodyAlignment,
                    icon:
                        _rebuildingAlignment
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      2,
                                ),
                              )
                            : const Icon(
                                Icons
                                    .construction_rounded,
                              ),
                    label:
                        Padding(
                      padding:
                          const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 8,
                      ),
                      child: Text(
                        _rebuildingAlignment
                            ? 'REBUILDING ALIGNMENT...'
                            : 'REBUILD NOBODY ALIGNMENT',
                      ),
                    ),
                  ),

                  const SizedBox(
                    height: 12,
                  ),

                  OutlinedButton.icon(
                    onPressed:
                        busy
                            ? null
                            : _reloadNobodySync,
                    icon:
                        _reloadingSync
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      2,
                                ),
                              )
                            : const Icon(
                                Icons
                                    .refresh_rounded,
                              ),
                    label:
                        Padding(
                      padding:
                          const EdgeInsets.symmetric(
                        vertical: 11,
                        horizontal: 8,
                      ),
                      child: Text(
                        _reloadingSync
                            ? 'RELOADING...'
                            : 'RELOAD SYNC',
                      ),
                    ),
                  ),

                  const SizedBox(
                    height: 22,
                  ),

                  Text(
                    _running
                        ? 'Listening to system audio'
                        : _rebuildingAlignment
                            ? 'Re-aligning the full song from the updated lyrics'
                            : _reloadingSync
                                ? 'Reading the current sync JSON'
                                : 'Tap the large button while music is playing',
                    textAlign:
                        TextAlign.center,
                    style:
                        const TextStyle(
                      color:
                          Colors.white30,
                      fontSize: 13,
                    ),
                  ),

                  if (_error !=
                      null) ...[
                    const SizedBox(
                      height: 25,
                    ),

                    ConstrainedBox(
                      constraints:
                          const BoxConstraints(
                        maxWidth: 620,
                      ),
                      child:
                          Text(
                        _error!,
                        textAlign:
                            TextAlign.center,
                        style:
                            const TextStyle(
                          color:
                              Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}