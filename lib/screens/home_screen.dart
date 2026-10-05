import 'dart:io';

import 'package:flutter/material.dart';

import '../services/fingerprint_match_service.dart';
import '../services/synced_lyrics_service.dart';
import '../services/system_audio_capture_service.dart';
import 'add_song_screen.dart';
import 'lyrics_edit_screen.dart';
import 'song_preview_screen.dart';
import 'synced_lyrics_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
  });

  @override
  State<HomeScreen> createState() =>
      _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final SyncedLyricsService _lyricsService =
      SyncedLyricsService();

  final FingerprintMatchService _fingerprintService =
      FingerprintMatchService();

  final SystemAudioCaptureService _captureService =
      SystemAudioCaptureService();

  //
  // Optimized recognition schedule.
  //
  static const List<int> _attemptSeconds = [
    4,
    6,
    8,
    10,
    12,
    14,
    16,
    18,
    20,
    22,
    24,
  ];

  static const int _minimumAlignedHashes = 5;

  static const double _minimumHashRatio = 0.50;

  late AnimationController _listenAnimation;

  List<SyncedLyricsSong> _songs = [];

  FingerprintEngineInfo? _engineInfo;

  bool _loadingLibrary = true;

  bool _listening = false;

  bool _stopRequested = false;

  String _status =
      'Tap to identify what is playing';

  String? _error;

  @override
  void initState() {
    super.initState();

    _listenAnimation =
        AnimationController(
      vsync: this,
      duration: const Duration(
        milliseconds: 1300,
      ),
    );

    _initialize();
  }

  Future<void> _initialize() async {
    await _loadLibrary();

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
        _error = e.toString();

        _status =
            'Fingerprint engine unavailable';
      });
    }
  }

  Future<void> _loadLibrary() async {
    try {
      final songs =
          await _lyricsService
              .loadLibrary();

      if (!mounted) {
        return;
      }

      setState(() {
        _songs = songs;

        _loadingLibrary = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadingLibrary = false;

        _error = e.toString();
      });
    }
  }

  int _windowForAttempt(
    int second,
  ) {
    if (second <= 4) {
      return 4;
    }

    return 5;
  }

  void _stopListening() {
    if (!_listening) {
      return;
    }

    setState(() {
      _stopRequested = true;

      _status =
          'Stopping...';
    });
  }

  Future<void> _startListening() async {
    if (_listening ||
        _engineInfo == null) {
      return;
    }

    setState(() {
      _listening = true;

      _stopRequested = false;

      _error = null;

      _status =
          'Listening...';
    });

    _listenAnimation.repeat(
      reverse: true,
    );

    bool captureStarted = false;

    final watch =
        Stopwatch()..start();

    try {
      await _fingerprintService
          .ensureReady();

      await _captureService
          .startContinuousCapture();

      captureStarted = true;

      Future<bool> tryIdentify(
        int windowSeconds,
      ) async {
        if (!mounted ||
            _stopRequested) {
          return false;
        }

        String? snapshotPath;

        try {
          final snapshot =
              await _captureService
                  .snapshotContinuousCapture(
            last: Duration(
              seconds: windowSeconds,
            ),
          );

          snapshotPath =
              snapshot.filePath;

          final matchWatch =
              Stopwatch()..start();

          final result =
              await _fingerprintService
                  .match(
            snapshot.filePath,
          );

          matchWatch.stop();

          debugPrint(
            'Fingerprint ${windowSeconds}s: '
            '${matchWatch.elapsedMilliseconds} ms',
          );

          if (!mounted ||
              _stopRequested) {
            return false;
          }

          final aligned =
              result.alignedHashes ?? 0;

          final common =
              result.commonHashes ?? 0;

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
            return false;
          }

          final song =
              await _lyricsService
                  .findSongForTrackPath(
            result.trackPath,
          );

          final positionMs =
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
            return true;
          }

          if (song == null) {
            setState(() {
              _status =
                  'Song recognized, but no synchronized lyrics are available';
            });

            return true;
          }

          setState(() {
            _status =
                song.displayName;
          });

          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  SyncedLyricsScreen(
                initialPositionMs:
                    positionMs,

                lockedTrackName:
                    result.trackPath ??
                        song.title,

                jsonPath:
                    song.jsonPath,
              ),
            ),
          );

          if (!mounted) {
            return true;
          }

          setState(() {
            _status =
                'Tap to identify what is playing';
          });

          return true;
        } catch (e) {
          debugPrint(
            'Fingerprint attempt failed: $e',
          );

          return false;
        } finally {
          if (snapshotPath != null) {
            try {
              final file =
                  File(
                snapshotPath,
              );

              if (await file.exists()) {
                await file.delete();
              }
            } catch (_) {}
          }
        }
      }

      for (final target in _attemptSeconds) {
        if (_stopRequested) {
          break;
        }

        final targetDuration =
            Duration(
          seconds: target,
        );

        final remaining =
            targetDuration -
                watch.elapsed;

        if (!remaining.isNegative) {
          await Future.delayed(
            remaining,
          );
        }

        if (!mounted ||
            _stopRequested) {
          break;
        }

        final found =
            await tryIdentify(
          _windowForAttempt(
            target,
          ),
        );

        if (found) {
          return;
        }
      }

      while (mounted &&
          !_stopRequested) {
        await Future.delayed(
          const Duration(
            seconds: 2,
          ),
        );

        if (_stopRequested) {
          break;
        }

        final found =
            await tryIdentify(
          5,
        );

        if (found) {
          return;
        }
      }
    } catch (e) {
      if (mounted &&
          !_stopRequested) {
        setState(() {
          _error =
              e.toString();

          _status =
              'Could not start listening';
        });
      }
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
          _listening = false;

          _stopRequested = false;

          if (_status ==
              'Stopping...') {
            _status =
                'Tap to identify what is playing';
          }
        });
      }
    }
  }

  Future<void> _openAddSong() async {
    if (_listening) {
      return;
    }

    //
    // Add Song may update audfprint DB.
    //
    _fingerprintService.dispose();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            const AddSongScreen(),
      ),
    );

    if (!mounted) {
      return;
    }

    await _loadLibrary();

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
        _error = e.toString();
      });
    }
  }

  Future<void> _openPreview(
    SyncedLyricsSong song,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            SongPreviewScreen(
          jsonPath:
              song.jsonPath,
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    await _loadLibrary();
  }

  //
  // Unified editor + calibration timeline.
  //
  Future<void> _openEditor(
    SyncedLyricsSong song,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            LyricsEditScreen(
          jsonPath:
              song.jsonPath,
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    await _loadLibrary();
  }

  Future<void> _deleteSong(
    SyncedLyricsSong song,
  ) async {
    if (_listening) {
      return;
    }

    final calibratedLines =
        song.manualCalibrationCount;

    final confirmed =
        await showDialog<bool>(
      context: context,
      builder: (
        dialogContext,
      ) {
        return AlertDialog(
          title:
              const Text(
            'Delete song?',
          ),
          content:
              Column(
            mainAxisSize:
                MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                song.title,
                style:
                    const TextStyle(
                  fontSize: 18,
                  fontWeight:
                      FontWeight.w700,
                ),
              ),

              const SizedBox(
                height: 3,
              ),

              Text(
                song.artist,
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                ),
              ),

              const SizedBox(
                height: 18,
              ),

              const Text(
                'This will remove the synchronized lyrics from your Lyriko library.',
              ),

              if (calibratedLines > 0) ...[
                const SizedBox(
                  height: 14,
                ),

                Text(
                  'WARNING: $calibratedLines lines have manual calibration.',
                  style:
                      const TextStyle(
                    color:
                        Colors.orangeAccent,
                    fontWeight:
                        FontWeight.w700,
                  ),
                ),

                const SizedBox(
                  height: 6,
                ),

                const Text(
                  'Deleting this song will also remove that calibration.',
                  style:
                      TextStyle(
                    color:
                        Colors.white54,
                  ),
                ),
              ],

              const SizedBox(
                height: 14,
              ),

              const Text(
                'The audfprint reference will be kept so the audio database is not rebuilt unnecessarily.',
                style:
                    TextStyle(
                  color:
                      Colors.white38,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  false,
                );
              },
              child:
                  const Text(
                'CANCEL',
              ),
            ),

            FilledButton(
              style:
                  FilledButton.styleFrom(
                backgroundColor:
                    Colors.redAccent,
              ),
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  true,
                );
              },
              child:
                  const Text(
                'DELETE',
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      final jsonFile =
          File(
        song.jsonPath,
      );

      if (await jsonFile.exists()) {
        await jsonFile.delete();
      }

      final txtPath =
          song.jsonPath.replaceFirst(
        RegExp(
          r'\.json$',
          caseSensitive: false,
        ),
        '.txt',
      );

      final txtFile =
          File(
        txtPath,
      );

      if (await txtFile.exists()) {
        await txtFile.delete();
      }

      await _loadLibrary();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: Text(
            '${song.displayName} deleted',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error =
            'Could not delete song:\n$e';
      });
    }
  }

  @override
  void dispose() {
    _stopRequested = true;

    _listenAnimation.dispose();

    _captureService
        .stopContinuousCapture();

    _fingerprintService
        .dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          const Color(
        0xFF080808,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(
              maxWidth: 1000,
            ),
            child:
                SingleChildScrollView(
              padding:
                  const EdgeInsets.fromLTRB(
                34,
                34,
                34,
                50,
              ),
              child:
                  Column(
                crossAxisAlignment:
                    CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Lyriko',
                    textAlign:
                        TextAlign.center,
                    style:
                        TextStyle(
                      fontSize: 46,
                      fontWeight:
                          FontWeight.w800,
                      letterSpacing:
                          -1.6,
                    ),
                  ),

                  const SizedBox(
                    height: 8,
                  ),

                  Text(
                    _status,
                    textAlign:
                        TextAlign.center,
                    style:
                        const TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 15,
                    ),
                  ),

                  const SizedBox(
                    height: 38,
                  ),

                  Center(
                    child:
                        AnimatedBuilder(
                      animation:
                          _listenAnimation,
                      builder: (
                        context,
                        child,
                      ) {
                        final value =
                            _listening
                                ? _listenAnimation
                                    .value
                                : 0.0;

                        return Transform.scale(
                          scale:
                              1 +
                                  value *
                                      0.04,
                          child:
                              Container(
                            width: 150,
                            height: 150,
                            decoration:
                                BoxDecoration(
                              shape:
                                  BoxShape.circle,
                              boxShadow:
                                  _listening
                                      ? [
                                          BoxShadow(
                                            color:
                                                Colors.white.withValues(
                                              alpha:
                                                  0.10 +
                                                      value *
                                                          0.12,
                                            ),
                                            blurRadius:
                                                30 +
                                                    value *
                                                        35,
                                            spreadRadius:
                                                4 +
                                                    value *
                                                        8,
                                          ),
                                        ]
                                      : null,
                            ),
                            child:
                                Material(
                              color:
                                  const Color(
                                0xFF181818,
                              ),
                              shape:
                                  const CircleBorder(),
                              child:
                                  InkWell(
                                customBorder:
                                    const CircleBorder(),
                                onTap:
                                    _engineInfo ==
                                            null
                                        ? null
                                        : _listening
                                            ? _stopListening
                                            : _startListening,
                                child:
                                    Icon(
                                  _listening
                                      ? Icons
                                          .stop_rounded
                                      : Icons
                                          .graphic_eq_rounded,
                                  size: 66,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  const SizedBox(
                    height: 48,
                  ),

                  Row(
                    children: [
                      const Expanded(
                        child:
                            Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Your Songs',
                              style:
                                  TextStyle(
                                fontSize: 24,
                                fontWeight:
                                    FontWeight.w700,
                              ),
                            ),

                            SizedBox(
                              height: 3,
                            ),

                            Text(
                              'Preview or edit synchronization visually',
                              style:
                                  TextStyle(
                                color:
                                    Colors.white38,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),

                      FilledButton.icon(
                        onPressed:
                            _listening
                                ? null
                                : _openAddSong,
                        icon:
                            const Icon(
                          Icons.add_rounded,
                        ),
                        label:
                            const Text(
                          'ADD SONG',
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 20,
                  ),

                  if (_loadingLibrary)
                    const Center(
                      child:
                          Padding(
                        padding:
                            EdgeInsets.all(
                          30,
                        ),
                        child:
                            CircularProgressIndicator(),
                      ),
                    )
                  else if (_songs.isEmpty)
                    Container(
                      padding:
                          const EdgeInsets.all(
                        30,
                      ),
                      decoration:
                          BoxDecoration(
                        color:
                            Colors.white
                                .withValues(
                          alpha: 0.03,
                        ),
                        borderRadius:
                            BorderRadius.circular(
                          16,
                        ),
                      ),
                      child:
                          const Text(
                        'No synchronized songs yet.',
                        textAlign:
                            TextAlign.center,
                        style:
                            TextStyle(
                          color:
                              Colors.white38,
                        ),
                      ),
                    )
                  else
                    ..._songs.map(
                      _buildSongCard,
                    ),

                  if (_error != null) ...[
                    const SizedBox(
                      height: 20,
                    ),

                    SelectableText(
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
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSongCard(
    SyncedLyricsSong song,
  ) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 12,
      ),
      padding:
          const EdgeInsets.fromLTRB(
        20,
        17,
        10,
        17,
      ),
      decoration:
          BoxDecoration(
        color:
            const Color(
          0xFF121212,
        ),
        borderRadius:
            BorderRadius.circular(
          16,
        ),
        border:
            Border.all(
          color:
              Colors.white.withValues(
            alpha: 0.05,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration:
                BoxDecoration(
              color:
                  Colors.white.withValues(
                alpha: 0.06,
              ),
              borderRadius:
                  BorderRadius.circular(
                12,
              ),
            ),
            child:
                const Icon(
              Icons.music_note_rounded,
            ),
          ),

          const SizedBox(
            width: 16,
          ),

          Expanded(
            child:
                Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style:
                      const TextStyle(
                    fontSize: 17,
                    fontWeight:
                        FontWeight.w700,
                  ),
                ),

                const SizedBox(
                  height: 3,
                ),

                Text(
                  song.artist,
                  style:
                      const TextStyle(
                    color:
                        Colors.white54,
                    fontSize: 13,
                  ),
                ),

                const SizedBox(
                  height: 3,
                ),

                Text(
                  '${song.lines.length} lyric lines',
                  style:
                      const TextStyle(
                    color:
                        Colors.white24,
                    fontSize: 11,
                  ),
                ),

                if (song.hasManualCalibration)
                  Padding(
                    padding:
                        const EdgeInsets.only(
                      top: 4,
                    ),
                    child:
                        Text(
                      '${song.manualCalibrationCount} manually adjusted lines',
                      style:
                          const TextStyle(
                        color:
                            Colors.greenAccent,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          OutlinedButton.icon(
            onPressed: () =>
                _openPreview(song),
            icon:
                const Icon(
              Icons.play_arrow_rounded,
              size: 18,
            ),
            label:
                const Text(
              'PREVIEW',
            ),
          ),

          const SizedBox(
            width: 8,
          ),

          FilledButton.tonalIcon(
            onPressed: () =>
                _openEditor(song),
            icon:
                const Icon(
              Icons.timeline_rounded,
              size: 18,
            ),
            label:
                const Text(
              'EDIT',
            ),
          ),

          const SizedBox(
            width: 5,
          ),

          Tooltip(
            message:
                'Delete song',
            child:
                IconButton(
              onPressed: () =>
                  _deleteSong(song),
              icon:
                  const Icon(
                Icons.delete_outline_rounded,
              ),
              color:
                  Colors.white38,
            ),
          ),
        ],
      ),
    );
  }
}