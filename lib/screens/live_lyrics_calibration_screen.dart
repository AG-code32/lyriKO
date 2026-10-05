import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/fingerprint_match_service.dart';
import '../services/system_audio_capture_service.dart';

class LiveLyricsCalibrationScreen
    extends StatefulWidget {
  final String jsonPath;
  final int initialPositionMs;
  final String lockedTrackName;

  const LiveLyricsCalibrationScreen({
    super.key,
    required this.jsonPath,
    required this.initialPositionMs,
    required this.lockedTrackName,
  });

  @override
  State<LiveLyricsCalibrationScreen>
      createState() =>
          _LiveLyricsCalibrationScreenState();
}

class _LiveLyricsCalibrationScreenState
    extends State<
        LiveLyricsCalibrationScreen> {
  final FingerprintMatchService
      _fingerprintService =
      FingerprintMatchService();

  final SystemAudioCaptureService
      _captureService =
      SystemAudioCaptureService();

  Timer? _uiTimer;
  Timer? _trackingTimer;

  final Stopwatch _localClock =
      Stopwatch();

  final Stopwatch _captureClock =
      Stopwatch();

  Map<String, dynamic>? _json;

  List<Map<String, dynamic>>
      _lines = [];

  String _title = '';
  String _artist = '';

  int _durationMs = 0;

  int _basePositionMs = 0;
  int _currentPositionMs = 0;

  int _autoLineIndex = 0;
  int? _editingLineIndex;

  bool _loading = true;
  bool _trackingBusy = false;
  bool _playing = true;
  bool _saving = false;

  int _consecutiveMisses = 0;
  int _stagnantMeasurements = 0;

  int? _lastMeasuredPositionMs;

  String? _error;
  String? _message;

  static const Duration _trackingWindow =
      Duration(seconds: 3);

  static const Duration _trackingInterval =
      Duration(seconds: 2);

  static const int _missesBeforeHold =
      4;

  static const int _stagnantBeforeHold =
      3;

  static const int _stagnantThresholdMs =
      350;

  int get _displayedLineIndex =>
      _editingLineIndex ??
      _autoLineIndex;

  bool get _editLocked =>
      _editingLineIndex != null;

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
      final file =
          File(
        widget.jsonPath,
      );

      if (!await file.exists()) {
        throw StateError(
          'Sync JSON not found:\n'
          '${widget.jsonPath}',
        );
      }

      final decoded =
          Map<String, dynamic>.from(
        jsonDecode(
          await file.readAsString(
            encoding: utf8,
          ),
        ) as Map,
      );

      final rawLines =
          decoded['lines'];

      if (rawLines is! List ||
          rawLines.isEmpty) {
        throw StateError(
          'No lyric lines found.',
        );
      }

      final lines =
          rawLines
              .whereType<Map>()
              .map(
                (item) =>
                    Map<String, dynamic>.from(
                  item,
                ),
              )
              .toList();

      for (final line in lines) {
        line['originalStartMs'] ??=
            line['startMs'] ?? 0;

        line['originalEndMs'] ??=
            line['endMs'] ?? 0;

        line['startMs'] ??=
            line['originalStartMs'];

        line['endMs'] ??=
            line['originalEndMs'];
      }

      final durationMs =
          (decoded['durationMs']
                      as num?)
                  ?.toInt() ??
              ((lines.last['endMs']
                          as num?)
                      ?.toInt() ??
                  0);

      final position =
          widget.initialPositionMs.clamp(
        0,
        durationMs,
      );

      final active =
          _findLineForPosition(
        lines,
        position,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _json = decoded;
        _lines = lines;

        _title =
            decoded['title']
                    ?.toString() ??
                '';

        _artist =
            decoded['artist']
                    ?.toString() ??
                '';

        _durationMs =
            durationMs;

        _basePositionMs =
            position;

        _currentPositionMs =
            position;

        _autoLineIndex =
            active < 0
                ? 0
                : active;

        _loading = false;
      });

      await _fingerprintService
          .ensureReady();

      await _captureService
          .startContinuousCapture();

      _captureClock
        ..reset()
        ..start();

      _localClock
        ..reset()
        ..start();

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
          _track();
        },
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  int _findLineForPosition(
    List<Map<String, dynamic>> lines,
    int positionMs,
  ) {
    if (lines.isEmpty) {
      return -1;
    }

    for (var i =
            lines.length - 1;
        i >= 0;
        i--) {
      final start =
          (lines[i]['startMs']
                      as num?)
                  ?.toInt() ??
              0;

      if (positionMs >= start) {
        return i;
      }
    }

    return 0;
  }

  void _updateLocalPosition() {
    if (!_playing ||
        _lines.isEmpty ||
        !mounted) {
      return;
    }

    var position =
        _basePositionMs +
            _localClock.elapsedMilliseconds;

    position =
        position.clamp(
      0,
      _durationMs,
    );

    final active =
        _findLineForPosition(
      _lines,
      position,
    );

    setState(() {
      _currentPositionMs =
          position;

      if (active >= 0) {
        _autoLineIndex =
            active;
      }
    });
  }

  bool _sameTrack(
    FingerprintMatchResult result,
  ) {
    if (!result.matched) {
      return false;
    }

    final resultPath =
        result.trackPath;

    final resultName =
        result.trackName ?? '';

    final audioPath =
        _json?['audioPath']
            ?.toString();

    final candidates = <String>[
      widget.lockedTrackName,
      if (audioPath != null)
        audioPath,
      _title,
    ];

    for (final candidate
        in candidates) {
      if (candidate.trim().isEmpty) {
        continue;
      }

      if (resultPath != null &&
          _normalizePath(
                resultPath,
              ) ==
              _normalizePath(
                candidate,
              )) {
        return true;
      }

      if (resultPath != null &&
          _fileName(
                resultPath,
              ) ==
              _fileName(
                candidate,
              )) {
        return true;
      }

      final a =
          _normalizeText(
        resultName,
      );

      final b =
          _normalizeText(
        candidate,
      );

      if (a.isNotEmpty &&
          b.isNotEmpty &&
          (a == b ||
              a.contains(
                b,
              ) ||
              b.contains(
                a,
              ))) {
        return true;
      }
    }

    return false;
  }

  String _normalizePath(
    String value,
  ) {
    return value
        .replaceAll(
          '\\',
          '/',
        )
        .toLowerCase()
        .trim();
  }

  String _fileName(
    String value,
  ) {
    final normalized =
        value.replaceAll(
      '\\',
      '/',
    );

    var name =
        normalized.split('/').last;

    final dot =
        name.lastIndexOf('.');

    if (dot > 0) {
      name =
          name.substring(
        0,
        dot,
      );
    }

    return _normalizeText(
      name,
    );
  }

  String _normalizeText(
    String value,
  ) {
    return value
        .toLowerCase()
        .replaceAll(
          RegExp(
            r'[^a-z0-9]+',
          ),
          '',
        );
  }

  Future<void> _track() async {
    if (_trackingBusy ||
        _captureClock.elapsed <
            _trackingWindow) {
      return;
    }

    _trackingBusy = true;

    String? snapshotPath;

    try {
      final snapshot =
          await _captureService
              .snapshotContinuousCapture(
        last: _trackingWindow,
      );

      snapshotPath =
          snapshot.filePath;

      final result =
          await _fingerprintService.match(
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

      final reliable =
          _sameTrack(
                result,
              ) &&
              aligned >= 5 &&
              ratio >= 0.50 &&
              result.offsetSeconds !=
                  null;

      if (!reliable) {
        _consecutiveMisses++;

        if (_consecutiveMisses >=
            _missesBeforeHold) {
          _freeze();
        }

        return;
      }

      _consecutiveMisses = 0;

      var measured =
          ((result.offsetSeconds! +
                          result.queryDuration) *
                      1000)
                  .round() +
              result.roundTripTime
                  .inMilliseconds;

      measured =
          measured.clamp(
        0,
        _durationMs,
      );

      final previous =
          _lastMeasuredPositionMs;

      if (previous != null) {
        final movement =
            measured -
                previous;

        if (movement.abs() <
            _stagnantThresholdMs) {
          _stagnantMeasurements++;
        } else {
          _stagnantMeasurements = 0;

          if (!_playing) {
            _setPosition(
              measured,
              resume: true,
            );
          }
        }
      }

      _lastMeasuredPositionMs =
          measured;

      if (_stagnantMeasurements >=
          _stagnantBeforeHold) {
        _setPosition(
          measured,
          resume: false,
        );

        return;
      }

      if (!_playing) {
        return;
      }

      final error =
          measured -
              _currentPositionMs;

      if (error.abs() >= 1200) {
        _setPosition(
          measured,
          resume: true,
        );
      } else if (error.abs() >=
          350) {
        final corrected =
            _currentPositionMs +
                (error * 0.35)
                    .round();

        _setPosition(
          corrected,
          resume: true,
        );
      }
    } catch (_) {
      _consecutiveMisses++;

      if (_consecutiveMisses >=
          _missesBeforeHold) {
        _freeze();
      }
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

      _trackingBusy = false;
    }
  }

  void _setPosition(
    int position, {
    required bool resume,
  }) {
    position =
        position.clamp(
      0,
      _durationMs,
    );

    _basePositionMs =
        position;

    _currentPositionMs =
        position;

    _localClock
      ..stop()
      ..reset();

    if (resume) {
      _playing = true;
      _localClock.start();
    } else {
      _playing = false;
    }

    final active =
        _findLineForPosition(
      _lines,
      position,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      if (active >= 0) {
        _autoLineIndex =
            active;
      }
    });
  }

  void _freeze() {
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

  void _previousLine() {
    final current =
        _displayedLineIndex;

    if (current <= 0) {
      return;
    }

    setState(() {
      _editingLineIndex =
          current - 1;
      _message = null;
    });
  }

  void _nextLine() {
    final current =
        _displayedLineIndex;

    if (current >=
        _lines.length - 1) {
      return;
    }

    setState(() {
      _editingLineIndex =
          current + 1;
      _message = null;
    });
  }

  void _autoFollow() {
    setState(() {
      _editingLineIndex = null;
      _message = null;
    });
  }

  Future<void> _markCurrentLine() async {
    if (_lines.isEmpty ||
        _saving) {
      return;
    }

    final index =
        _displayedLineIndex;

    final position =
        _currentPositionMs;

    setState(() {
      _saving = true;
    });

    try {
      final current =
          Map<String, dynamic>.from(
        _lines[index],
      );

      current['startMs'] =
          position;

      //
      // We keep originalStartMs untouched.
      //
      current['originalStartMs'] ??=
          current['startMs'];

      current['words'] =
          <dynamic>[];

      _lines[index] =
          current;

      if (index > 0) {
        final previous =
            Map<String, dynamic>.from(
          _lines[index - 1],
        );

        previous['endMs'] =
            position > 0
                ? position - 1
                : 0;

        previous['words'] =
            <dynamic>[];

        _lines[index - 1] =
            previous;
      }

      await _saveJson();

      if (!mounted) {
        return;
      }

      setState(() {
        _saving = false;

        _editingLineIndex =
            index;

        _message =
            'Line ${index + 1} calibrated at '
            '${_formatTime(position)}';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _resetCurrentLine() async {
    final index =
        _displayedLineIndex;

    final line =
        Map<String, dynamic>.from(
      _lines[index],
    );

    final originalStart =
        (line['originalStartMs']
                    as num?)
                ?.toInt() ??
            (line['startMs']
                    as num?)
                ?.toInt() ??
            0;

    line['startMs'] =
        originalStart;

    line['words'] =
        <dynamic>[];

    _lines[index] =
        line;

    if (index > 0) {
      final previous =
          Map<String, dynamic>.from(
        _lines[index - 1],
      );

      previous['endMs'] =
          originalStart > 0
              ? originalStart - 1
              : 0;

      previous['words'] =
          <dynamic>[];

      _lines[index - 1] =
          previous;
    }

    await _saveJson();

    if (!mounted) {
      return;
    }

    setState(() {
      _editingLineIndex =
          index;

      _message =
          'Line ${index + 1} reset to CTC';
    });
  }

  Future<void> _saveJson() async {
    final json =
        _json;

    if (json == null) {
      return;
    }

    json['lines'] =
        _lines;

    await File(
      widget.jsonPath,
    ).writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(
        json,
      ),
      encoding: utf8,
      flush: true,
    );
  }

  String _formatTime(
    int milliseconds,
  ) {
    final minutes =
        milliseconds ~/ 60000;

    final seconds =
        (milliseconds % 60000) ~/
            1000;

    final millis =
        milliseconds % 1000;

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }

  Future<void> _close() async {
    await _saveJson();

    if (!mounted) {
      return;
    }

    Navigator.pop(
      context,
      _currentPositionMs,
    );
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _trackingTimer?.cancel();

    _localClock.stop();
    _captureClock.stop();

    unawaited(
      _captureService.stopContinuousCapture(),
    );

    unawaited(
      _fingerprintService.dispose(),
    );

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    if (_loading) {
      return const Scaffold(
        backgroundColor:
            Color(
          0xFF080808,
        ),
        body: Center(
          child:
              CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor:
            const Color(
          0xFF080808,
        ),
        appBar: AppBar(
          backgroundColor:
              const Color(
            0xFF080808,
          ),
        ),
        body: Center(
          child: Padding(
            padding:
                const EdgeInsets.all(
              30,
            ),
            child:
                SelectableText(
              _error!,
              style:
                  const TextStyle(
                color:
                    Colors.redAccent,
              ),
            ),
          ),
        ),
      );
    }

    final index =
        _displayedLineIndex;

    final line =
        _lines[index];

    final currentStart =
        (line['startMs']
                    as num?)
                ?.toInt() ??
            0;

    final originalStart =
        (line['originalStartMs']
                    as num?)
                ?.toInt() ??
            currentStart;

    final delta =
        currentStart -
            originalStart;

    return Scaffold(
      backgroundColor:
          const Color(
        0xFF080808,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets
                      .fromLTRB(
                22,
                16,
                22,
                8,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed:
                        _close,
                    icon:
                        const Icon(
                      Icons
                          .arrow_back_rounded,
                    ),
                  ),

                  const SizedBox(
                    width: 10,
                  ),

                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Text(
                          _title,
                          style:
                              const TextStyle(
                            fontSize:
                                22,
                            fontWeight:
                                FontWeight
                                    .w700,
                          ),
                        ),
                        Text(
                          _artist,
                          style:
                              const TextStyle(
                            color:
                                Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Container(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      horizontal:
                          12,
                      vertical:
                          6,
                    ),
                    decoration:
                        BoxDecoration(
                      color:
                          Colors.greenAccent
                              .withValues(
                        alpha: 0.08,
                      ),
                      borderRadius:
                          BorderRadius
                              .circular(
                        18,
                      ),
                    ),
                    child:
                        const Text(
                      'LIVE CALIBRATION',
                      style:
                          TextStyle(
                        color:
                            Colors.greenAccent,
                        fontSize:
                            10,
                        fontWeight:
                            FontWeight
                                .w700,
                      ),
                    ),
                  ),

                  const SizedBox(
                    width: 18,
                  ),

                  Column(
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .end,
                    children: [
                      Text(
                        _formatTime(
                          _currentPositionMs,
                        ),
                        style:
                            const TextStyle(
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        _playing
                            ? 'SYNC'
                            : 'HOLD',
                        style:
                            TextStyle(
                          fontSize: 10,
                          fontWeight:
                              FontWeight
                                  .w700,
                          color:
                              _playing
                                  ? Colors
                                      .greenAccent
                                  : Colors
                                      .orangeAccent,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            Padding(
              padding:
                  const EdgeInsets
                      .symmetric(
                horizontal: 30,
                vertical: 8,
              ),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      horizontal: 11,
                      vertical: 5,
                    ),
                    decoration:
                        BoxDecoration(
                      color:
                          Colors.white
                              .withValues(
                        alpha: 0.05,
                      ),
                      borderRadius:
                          BorderRadius
                              .circular(
                        18,
                      ),
                    ),
                    child: Text(
                      _editLocked
                          ? 'EDIT LOCK'
                          : 'AUTO FOLLOW',
                      style:
                          const TextStyle(
                        color:
                            Colors.white54,
                        fontSize: 10,
                      ),
                    ),
                  ),

                  const Spacer(),

                  Text(
                    'Line ${index + 1} / ${_lines.length}',
                    style:
                        const TextStyle(
                      color:
                          Colors.white38,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: Center(
                child: Padding(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 60,
                  ),
                  child: Column(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .center,
                    children: [
                      Text(
                        line['text']
                                ?.toString() ??
                            '',
                        textAlign:
                            TextAlign.center,
                        style:
                            const TextStyle(
                          fontSize: 38,
                          fontWeight:
                              FontWeight
                                  .w700,
                          height: 1.25,
                        ),
                      ),

                      const SizedBox(
                        height: 34,
                      ),

                      Text(
                        'CTC   ${_formatTime(originalStart)}',
                        style:
                            const TextStyle(
                          color:
                              Colors.white38,
                        ),
                      ),

                      const SizedBox(
                        height: 6,
                      ),

                      Text(
                        'SAVED   ${_formatTime(currentStart)}',
                        style:
                            const TextStyle(
                          color:
                              Colors.white70,
                        ),
                      ),

                      const SizedBox(
                        height: 6,
                      ),

                      Text(
                        'Δ ${delta >= 0 ? '+' : ''}$delta ms',
                        style:
                            TextStyle(
                          color:
                              delta == 0
                                  ? Colors
                                      .white30
                                  : Colors
                                      .orangeAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            Padding(
              padding:
                  const EdgeInsets
                      .symmetric(
                horizontal: 24,
              ),
              child:
                  const Text(
                'Control play, pause or seek in YouTube/Spotify. '
                'Lyriko keeps listening and follows the detected position.',
                textAlign:
                    TextAlign.center,
                style:
                    TextStyle(
                  color:
                      Colors.white38,
                  fontSize: 12,
                ),
              ),
            ),

            const SizedBox(
              height: 18,
            ),

            FilledButton.icon(
              onPressed:
                  _saving
                      ? null
                      : _markCurrentLine,
              icon:
                  const Icon(
                Icons
                    .location_on_rounded,
              ),
              label:
                  const Padding(
                padding:
                    EdgeInsets
                        .symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child:
                    Text(
                  'MARK CURRENT LINE',
                ),
              ),
            ),

            const SizedBox(
              height: 14,
            ),

            Wrap(
              alignment:
                  WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      index > 0
                          ? _previousLine
                          : null,
                  icon:
                      const Icon(
                    Icons
                        .skip_previous_rounded,
                  ),
                  label:
                      const Text(
                    'PREVIOUS',
                  ),
                ),

                OutlinedButton.icon(
                  onPressed:
                      _resetCurrentLine,
                  icon:
                      const Icon(
                    Icons
                        .restart_alt_rounded,
                  ),
                  label:
                      const Text(
                    'RESET TO CTC',
                  ),
                ),

                OutlinedButton.icon(
                  onPressed:
                      index <
                              _lines.length -
                                  1
                          ? _nextLine
                          : null,
                  icon:
                      const Icon(
                    Icons
                        .skip_next_rounded,
                  ),
                  label:
                      const Text(
                    'NEXT',
                  ),
                ),

                FilledButton.tonalIcon(
                  onPressed:
                      _editLocked
                          ? _autoFollow
                          : null,
                  icon:
                      const Icon(
                    Icons
                        .sync_rounded,
                  ),
                  label:
                      const Text(
                    'AUTO FOLLOW',
                  ),
                ),
              ],
            ),

            if (_message != null)
              Padding(
                padding:
                    const EdgeInsets
                        .only(
                  top: 14,
                ),
                child: Text(
                  _message!,
                  style:
                      const TextStyle(
                    color:
                        Colors.greenAccent,
                    fontSize: 12,
                  ),
                ),
              ),

            const SizedBox(
              height: 28,
            ),
          ],
        ),
      ),
    );
  }
}