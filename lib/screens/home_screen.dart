import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/android_media_session_service.dart';
import '../services/fingerprint_match_service.dart';
import '../services/synced_lyrics_service.dart';
import '../services/system_audio_capture_service.dart';
import '../services/windows_media_session_service.dart';
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

  final WindowsMediaSessionService _windowsMediaSessionService =
      WindowsMediaSessionService();

  final AndroidMediaSessionService _androidMediaSessionService =
      AndroidMediaSessionService();

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

    if (Platform.isWindows) {
      // Windows Media Session is optional. If it is available, it becomes
      // the preferred source for metadata and playback state.
      await _windowsMediaSessionService.initialize();

      try {
        final info = await _fingerprintService.ensureReady();

        if (!mounted) {
          return;
        }

        setState(() {
          _engineInfo = info;
        });
      } catch (_) {
        // Fingerprint remains a Windows fallback. Do not disable LISTEN just
        // because the fallback engine is unavailable.
        if (!mounted) {
          return;
        }

        setState(() {
          _engineInfo = null;
          _error = null;
        });
      }
    } else if (Platform.isAndroid) {
      // The Android bridge was validated separately. No audio capture or
      // fingerprint fallback is used on Android yet.
      _engineInfo = null;
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

  Future<bool> _tryIdentifyFromMediaSession() async {
    if (Platform.isAndroid) {
      return _tryIdentifyFromAndroidMediaSession();
    }

    if (Platform.isWindows) {
      return _tryIdentifyFromWindowsMediaSession();
    }

    return false;
  }

  Future<bool> _tryIdentifyFromAndroidMediaSession() async {
    final hasAccess = await _androidMediaSessionService.hasNotificationAccess();

    if (!hasAccess) {
      if (mounted) {
        setState(() {
          _status = 'Notification access is required';
        });
      }

      await _androidMediaSessionService.openNotificationAccessSettings();
      return false;
    }

    final sessions = await _androidMediaSessionService.getSessions();

    final ordered = [...sessions]
      ..sort((a, b) {
        final aRank = a.isPlaying ? 0 : (a.isPaused ? 1 : 2);
        final bRank = b.isPlaying ? 0 : (b.isPaused ? 1 : 2);
        return aRank.compareTo(bRank);
      });

    for (final session in ordered) {
      if (!session.available || !session.hasMetadata) {
        continue;
      }

      final song = await _lyricsService.findSongForMediaMetadata(
        title: session.title,
        artist: session.artist,
        albumArtist: session.albumArtist,
      );

      if (song == null) {
        continue;
      }

      debugPrint(
        'Android media match: '
        '${session.sourceAppId} | '
        '${session.artist} | '
        '${session.title} -> '
        '${song.displayName}',
      );

      await _openDetectedSong(
        song: song,
        initialPositionMs: session.estimatedPositionMs,
        lockedTrackName: song.displayName,
        mediaSourceAppId: session.sourceAppId,
      );

      return true;
    }

    return false;
  }

  Future<bool> _tryIdentifyFromWindowsMediaSession() async {
    final sessions = await _windowsMediaSessionService.getSessions();

    if (sessions.isEmpty) {
      return false;
    }

    final ordered = [...sessions]
      ..sort((a, b) {
        final aRank = a.isPlaying ? 0 : (a.isPaused ? 1 : 2);
        final bRank = b.isPlaying ? 0 : (b.isPaused ? 1 : 2);
        return aRank.compareTo(bRank);
      });

    for (final session in ordered) {
      if (!session.available || !session.hasMetadata) {
        continue;
      }

      final song = await _lyricsService.findSongForMediaMetadata(
        title: session.title,
        artist: session.artist,
        albumArtist: session.albumArtist,
      );

      if (song == null) {
        continue;
      }

      debugPrint(
        'Windows media match: '
        '${session.sourceAppId} | '
        '${session.artist} | '
        '${session.title} -> '
        '${song.displayName}',
      );

      await _openDetectedSong(
        song: song,
        initialPositionMs: session.estimatedPositionMs(),
        lockedTrackName: song.displayName,
        mediaSourceAppId: session.sourceAppId,
      );

      return true;
    }

    return false;
  }

  Future<String?> _findActivePlaybackSourceAppId() async {
    if (Platform.isAndroid) {
      final sessions = await _androidMediaSessionService.getSessions();
      final active = sessions
          .where((session) => session.available && (session.isPlaying || session.isPaused))
          .toList();

      if (active.isEmpty) return null;
      active.sort((a, b) => (a.isPlaying ? 0 : 1).compareTo(b.isPlaying ? 0 : 1));
      return active.first.sourceAppId;
    }

    if (Platform.isWindows) {
      final sessions = await _windowsMediaSessionService.getSessions();
      final active = sessions
          .where((session) => session.available && (session.isPlaying || session.isPaused))
          .toList();

      if (active.isEmpty) return null;
      active.sort((a, b) => (a.isPlaying ? 0 : 1).compareTo(b.isPlaying ? 0 : 1));
      return active.first.sourceAppId;
    }

    return null;
  }

  Future<void> _openDetectedSong({
    required SyncedLyricsSong song,
    required int initialPositionMs,
    required String lockedTrackName,
    String? mediaSourceAppId,
  }) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _status = song.displayName;
    });

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SyncedLyricsScreen(
          initialPositionMs: initialPositionMs,
          lockedTrackName: lockedTrackName,
          jsonPath: song.jsonPath,
          mediaSourceAppId: mediaSourceAppId,
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Tap to identify what is playing';
    });
  }

  static const MethodChannel _iosProbeChannel =
      MethodChannel('lyriko/ios_audio_probe');

  Future<void> _runIOSAudioProbe() async {
    setState(() {
      _listening = true;
      _stopRequested = false;
      _error = null;
      _status = 'Choose full-display capture in the iOS picker';
    });
    _listenAnimation.repeat(reverse: true);
    try {
      await _iosProbeChannel.invokeMethod<void>('start');
      while (mounted && !_stopRequested) {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted || _stopRequested) break;
        final stats = await _iosProbeChannel.invokeMapMethod<String, dynamic>('stats');
        if (!mounted) break;
        final phase = stats?['phase'] ?? 'unknown';
        final buffers = stats?['audioBuffers'] ?? 0;
        final bytes = stats?['audioBytes'] ?? 0;
        final error = stats?['error'] ?? '';
        final frames = stats?['sampleFrames'] ?? 0;
        final payloadBuffers = stats?['payloadBuffers'] ?? 0;
        final signalBuffers = stats?['signalBuffers'] ?? 0;
        final rms = (stats?['rms'] as num?)?.toDouble() ?? 0.0;
        final peak = (stats?['peak'] as num?)?.toDouble() ?? 0.0;
        final format = stats?['format'] ?? 'unknown';
        final diagnosis = stats?['diagnosis'] ?? '';
        setState(() {
          _status = 'iOS: $phase | audio: $buffers | bytes: $bytes'
              '\nframes: $frames | payload: $payloadBuffers | signal: $signalBuffers'
              '\nRMS: ${rms.toStringAsFixed(5)} | peak: ${peak.toStringAsFixed(5)}'
              '\n$format | $diagnosis';
          if (error.toString().isNotEmpty) _error = error.toString();
        });
        if (phase == 'error' || phase == 'cancelled') break;
      }
    } catch (e) {
      if (mounted) setState(() { _status = 'iOS audio test failed'; _error = '$e'; });
    } finally {
      try { await _iosProbeChannel.invokeMethod<void>('stop'); } catch (_) {}
      _listenAnimation.stop();
      if (mounted) setState(() { _listening = false; _stopRequested = false; });
    }
  }

  Future<void> _startListening() async {
    if (_listening) {
      return;
    }
    if (Platform.isIOS) {
      await _runIOSAudioProbe();
      return;
    }

    setState(() {
      _listening = true;
      _stopRequested = false;
      _error = null;
      _status = 'Checking media session...';
    });

    _listenAnimation.repeat(reverse: true);

    bool captureStarted = false;
    final watch = Stopwatch()..start();

    try {
      // Preferred path: Windows Media Session metadata.
      final metadataFound = await _tryIdentifyFromMediaSession();

      if (metadataFound || _stopRequested || !mounted) {
        return;
      }

      if (Platform.isAndroid) {
        if (mounted) {
          setState(() {
            _status = 'No matching lyrics found for the active Android media session';
          });
        }
        return;
      }

      // Windows fallback path: audfprint.
      if (_engineInfo == null) {
        try {
          _engineInfo = await _fingerprintService.ensureReady();
        } catch (e) {
          if (mounted) {
            setState(() {
              _status = 'No metadata match and fingerprint fallback is unavailable';
              _error = e.toString();
            });
          }
          return;
        }
      }

      if (!mounted || _stopRequested) {
        return;
      }

      setState(() {
        _status = 'Listening with fingerprint...';
      });

      await _fingerprintService.ensureReady();
      await _captureService.startContinuousCapture();
      captureStarted = true;

      Future<bool> tryIdentify(int windowSeconds) async {
        if (!mounted || _stopRequested) {
          return false;
        }

        String? snapshotPath;

        try {
          final snapshot = await _captureService.snapshotContinuousCapture(
            last: Duration(seconds: windowSeconds),
          );

          snapshotPath = snapshot.filePath;

          final matchWatch = Stopwatch()..start();
          final result = await _fingerprintService.match(snapshot.filePath);
          matchWatch.stop();

          debugPrint(
            'Fingerprint ${windowSeconds}s: '
            '${matchWatch.elapsedMilliseconds} ms',
          );

          if (!mounted || _stopRequested) {
            return false;
          }

          final aligned = result.alignedHashes ?? 0;
          final common = result.commonHashes ?? 0;
          final ratio = common > 0 ? aligned / common : 0.0;

          final accepted = result.matched &&
              aligned >= _minimumAlignedHashes &&
              ratio >= _minimumHashRatio &&
              result.offsetSeconds != null;

          if (!accepted) {
            return false;
          }

          final song = await _lyricsService.findSongForTrackPath(result.trackPath);

          final positionMs =
              ((result.offsetSeconds! + result.queryDuration) * 1000).round() +
                  result.roundTripTime.inMilliseconds;

          await _captureService.stopContinuousCapture();
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

          // Even when identification required fingerprint, a browser/player
          // Media Session can still provide play/pause/seek afterwards.
          final mediaSourceAppId = await _findActivePlaybackSourceAppId();

          await _openDetectedSong(
            song: song,
            initialPositionMs: positionMs,
            lockedTrackName: result.trackPath ?? song.title,
            mediaSourceAppId: mediaSourceAppId,
          );

          return true;
        } catch (e) {
          debugPrint('Fingerprint attempt failed: $e');
          return false;
        } finally {
          if (snapshotPath != null) {
            try {
              final file = File(snapshotPath);
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

        final targetDuration = Duration(seconds: target);
        final remaining = targetDuration - watch.elapsed;

        if (!remaining.isNegative) {
          await Future.delayed(remaining);
        }

        if (!mounted || _stopRequested) {
          break;
        }

        final found = await tryIdentify(_windowForAttempt(target));
        if (found) {
          return;
        }
      }

      while (mounted && !_stopRequested) {
        await Future.delayed(const Duration(seconds: 2));

        if (_stopRequested) {
          break;
        }

        final found = await tryIdentify(5);
        if (found) {
          return;
        }
      }
    } catch (e) {
      if (mounted && !_stopRequested) {
        setState(() {
          _error = e.toString();
          _status = 'Could not start listening';
        });
      }
    } finally {
      if (captureStarted) {
        try {
          await _captureService.stopContinuousCapture();
        } catch (_) {}
      }

      _listenAnimation.stop();

      if (mounted) {
        setState(() {
          _listening = false;
          _stopRequested = false;

          if (_status == 'Stopping...') {
            _status = 'Tap to identify what is playing';
          }
        });
      }
    }
  }

  Future<void> _openAddSong() async {
    if (_listening) {
      return;
    }

    // Add Song may update audfprint DB on Windows.
    if (Platform.isWindows) {
      _fingerprintService.dispose();
    }

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

    if (Platform.isWindows) {
      try {
        final info = await _fingerprintService.ensureReady();

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

    if (Platform.isWindows) {
      _captureService.stopContinuousCapture();
      _fingerprintService.dispose();
    }

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
              padding: EdgeInsets.fromLTRB(
                MediaQuery.sizeOf(context).width < 600 ? 18 : 34,
                MediaQuery.sizeOf(context).width < 600 ? 22 : 34,
                MediaQuery.sizeOf(context).width < 600 ? 18 : 34,
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
                      fontSize: 40,
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
                            width: MediaQuery.sizeOf(context).width < 600 ? 126 : 150,
                            height: MediaQuery.sizeOf(context).width < 600 ? 126 : 150,
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
                                    _listening
                                        ? _stopListening
                                        : _startListening,
                                child:
                                    Icon(
                                  _listening
                                      ? Icons
                                          .stop_rounded
                                      : Icons
                                          .graphic_eq_rounded,
                                  size: MediaQuery.sizeOf(context).width < 600 ? 56 : 66,
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

                  LayoutBuilder(
                    builder: (context, constraints) {
                      final mobile = constraints.maxWidth < 600;

                      final heading = const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your Songs',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Preview or edit synchronization visually',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      );

                      final addButton = FilledButton.icon(
                        onPressed: _listening ? null : _openAddSong,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('ADD SONG'),
                      );

                      if (mobile) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            heading,
                            const SizedBox(height: 14),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: addButton,
                            ),
                          ],
                        );
                      }

                      return Row(
                        children: [
                          Expanded(child: heading),
                          addButton,
                        ],
                      );
                    },
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < 600;

        final info = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: mobile ? 42 : 48,
              height: mobile ? 42 : 48,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.music_note_rounded),
            ),
            SizedBox(width: mobile ? 12 : 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${song.lines.length} lyric lines',
                    style: const TextStyle(
                      color: Colors.white24,
                      fontSize: 11,
                    ),
                  ),
                  if (song.hasManualCalibration)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${song.manualCalibrationCount} manually adjusted lines',
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 10,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );

        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: mobile ? WrapAlignment.start : WrapAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: () => _openPreview(song),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('PREVIEW'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _openEditor(song),
              icon: const Icon(Icons.timeline_rounded, size: 18),
              label: const Text('EDIT'),
            ),
            IconButton(
              tooltip: 'Delete song',
              onPressed: () => _deleteSong(song),
              icon: const Icon(Icons.delete_outline_rounded),
              color: Colors.white38,
            ),
          ],
        );

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: EdgeInsets.fromLTRB(
            mobile ? 14 : 20,
            15,
            mobile ? 12 : 10,
            15,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF121212),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.05),
            ),
          ),
          child: mobile
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    info,
                    const SizedBox(height: 14),
                    actions,
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: info),
                    const SizedBox(width: 16),
                    actions,
                  ],
                ),
        );
      },
    );
  }

}