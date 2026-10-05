import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../services/synced_lyrics_service.dart';

class LyricsCalibrationScreen
    extends StatefulWidget {
  final String jsonPath;

  const LyricsCalibrationScreen({
    super.key,
    required this.jsonPath,
  });

  @override
  State<LyricsCalibrationScreen>
      createState() =>
          _LyricsCalibrationScreenState();
}

class _LyricsCalibrationScreenState
    extends State<
        LyricsCalibrationScreen> {
  final AudioPlayer _player =
      AudioPlayer();

  final FocusNode _keyboardFocus =
      FocusNode();

  StreamSubscription<Duration>?
      _positionSub;

  StreamSubscription<PlayerState>?
      _stateSub;

  Map<String, dynamic>? _json;

  List<Map<String, dynamic>>
      _lines = [];

  String _title = '';
  String _artist = '';

  int _autoLineIndex = 0;

  int? _editingLineIndex;

  int _positionMs = 0;
  int _durationMs = 0;

  bool _loading = true;
  bool _saving = false;
  bool _playing = false;
  bool _marking = false;

  double _volume = 1.0;

  String? _error;
  String? _lastSavedMessage;

  int get _displayedLineIndex =>
      _editingLineIndex ??
      _autoLineIndex;

  bool get _isEditLocked =>
      _editingLineIndex != null;

  @override
  void initState() {
    super.initState();

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

      final raw =
          await file.readAsString(
        encoding: utf8,
      );

      final decoded =
          Map<String, dynamic>.from(
        jsonDecode(raw) as Map,
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
                    Map<String, dynamic>
                        .from(
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

      final title =
          decoded['title']
                  ?.toString() ??
              'Unknown song';

      final artist =
          decoded['artist']
                  ?.toString() ??
              '';

      final audioPath =
          await _resolveAudioPath(
        decoded,
        title,
      );

      if (audioPath == null) {
        throw StateError(
          'Reference audio could not be found.',
        );
      }

      await _player.setFilePath(
        audioPath,
      );

      await _player.setVolume(
        _volume,
      );

      _durationMs =
          _player.duration
                  ?.inMilliseconds ??
              0;

      _positionSub =
          _player.positionStream.listen(
        (position) {
          if (!mounted) {
            return;
          }

          final milliseconds =
              position.inMilliseconds;

          final autoIndex =
              _findLineForPosition(
            milliseconds,
          );

          setState(() {
            _positionMs =
                milliseconds;

            if (autoIndex >= 0) {
              _autoLineIndex =
                  autoIndex;
            }
          });
        },
      );

      _stateSub =
          _player.playerStateStream.listen(
        (state) {
          if (!mounted) {
            return;
          }

          setState(() {
            _playing =
                state.playing;
          });
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _json = decoded;
        _lines = lines;
        _title = title;
        _artist = artist;
        _autoLineIndex = 0;
        _editingLineIndex = null;
        _loading = false;
      });

      await _player.seek(
        Duration(
          milliseconds:
              _effectiveStart(
            0,
          ),
        ),
      );

      WidgetsBinding.instance
          .addPostFrameCallback(
        (_) {
          _keyboardFocus
              .requestFocus();
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

  Future<String?>
      _resolveAudioPath(
    Map<String, dynamic> json,
    String title,
  ) async {
    final value =
        json['audioPath']
            ?.toString()
            .trim();

    if (value != null &&
        value.isNotEmpty &&
        await File(
          value,
        ).exists()) {
      return value;
    }

    //
    // Compatibility with the original
    // Nobody JSON.
    //
    if (title
            .toLowerCase()
            .trim() ==
        'nobody') {
      const folderPath =
          r'F:\Nueva carpeta\Avenged Sevenfold - Life Is But A Dream (2023) Mp3 320kbps (PMEDIA)';

      final directory =
          Directory(
        folderPath,
      );

      if (await directory.exists()) {
        await for (final entity
            in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) {
            continue;
          }

          final lower =
              entity.path
                  .toLowerCase();

          if (lower.endsWith(
                '.mp3',
              ) &&
              lower.contains(
                'nobody',
              )) {
            return entity.path;
          }
        }
      }
    }

    return null;
  }

  Map<String, dynamic> _line(
    int index,
  ) {
    return Map<String, dynamic>.from(
      _lines[index],
    );
  }

  int _start(
    int index,
  ) {
    return (_lines[index]
                ['startMs']
            as num?)
        ?.toInt() ??
        0;
  }

  int _originalStart(
    int index,
  ) {
    return (_lines[index]
                ['originalStartMs']
            as num?)
        ?.toInt() ??
        _start(
          index,
        );
  }

  int _effectiveStart(
    int index,
  ) {
    return _start(
      index,
    );
  }

  int _findLineForPosition(
    int positionMs,
  ) {
    if (_lines.isEmpty) {
      return -1;
    }

    if (positionMs <
        _effectiveStart(
          0,
        )) {
      return 0;
    }

    for (var i =
            _lines.length - 1;
        i >= 0;
        i--) {
      if (positionMs >=
          _effectiveStart(
            i,
          )) {
        return i;
      }
    }

    return 0;
  }

  int _clamp(
    int value,
  ) {
    if (value < 0) {
      return 0;
    }

    if (_durationMs > 0 &&
        value > _durationMs) {
      return _durationMs;
    }

    return value;
  }

  Future<void> _togglePlay() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> _seekBy(
    int deltaMs,
  ) async {
    final target =
        _clamp(
      _player.position
              .inMilliseconds +
          deltaMs,
    );

    await _player.seek(
      Duration(
        milliseconds:
            target,
      ),
    );
  }

  Future<void> _setVolume(
    double value,
  ) async {
    final safe =
        value.clamp(
      0.0,
      1.0,
    );

    setState(() {
      _volume =
          safe;
    });

    await _player.setVolume(
      safe,
    );
  }

  void _returnToAutoFollow() {
    final position =
        _player.position
            .inMilliseconds;

    final auto =
        _findLineForPosition(
      position,
    );

    setState(() {
      _editingLineIndex =
          null;

      if (auto >= 0) {
        _autoLineIndex =
            auto;
      }

      _lastSavedMessage =
          null;
    });
  }

  Future<void> _markNow() async {
    if (_marking ||
        _lines.isEmpty) {
      return;
    }

    final index =
        _displayedLineIndex;

    final position =
        _player.position
            .inMilliseconds;

    setState(() {
      _marking = true;
    });

    try {
      final current =
          _line(
        index,
      );

      current['startMs'] =
          position;

      current['words'] =
          <dynamic>[];

      _lines[index] =
          current;

      if (index > 0) {
        final previous =
            _line(
          index - 1,
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
        _marking = false;

        _lastSavedMessage =
            'Line ${index + 1} saved';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _marking = false;
        _error = e.toString();
      });
    }
  }

  Future<void>
      _resetCurrentLineToCtc() async {
    if (_lines.isEmpty) {
      return;
    }

    final index =
        _displayedLineIndex;

    setState(() {
      _editingLineIndex =
          index;
    });

    final original =
        _originalStart(
      index,
    );

    final current =
        _line(
      index,
    );

    current['startMs'] =
        original;

    current['words'] =
        <dynamic>[];

    _lines[index] =
        current;

    if (index > 0) {
      final previous =
          _line(
        index - 1,
      );

      previous['endMs'] =
          original > 0
              ? original - 1
              : 0;

      previous['words'] =
          <dynamic>[];

      _lines[index - 1] =
          previous;
    }

    await _saveJson();

    await _player.seek(
      Duration(
        milliseconds:
            _clamp(
          original,
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _editingLineIndex =
          index;

      _lastSavedMessage =
          'Line ${index + 1} reset to CTC';
    });
  }

  Future<void> _previousLine() async {
    final current =
        _displayedLineIndex;

    if (current <= 0) {
      return;
    }

    final target =
        current - 1;

    setState(() {
      _editingLineIndex =
          target;
    });

    await _player.seek(
      Duration(
        milliseconds:
            _effectiveStart(
          target,
        ),
      ),
    );
  }

  Future<void> _nextLine() async {
    final current =
        _displayedLineIndex;

    if (current >=
        _lines.length - 1) {
      return;
    }

    final target =
        current + 1;

    setState(() {
      _editingLineIndex =
          target;
    });

    await _player.seek(
      Duration(
        milliseconds:
            _effectiveStart(
          target,
        ),
      ),
    );
  }

  Future<void> _replayLine() async {
    final index =
        _displayedLineIndex;

    setState(() {
      _editingLineIndex =
          index;
    });

    await _player.seek(
      Duration(
        milliseconds:
            _effectiveStart(
          index,
        ),
      ),
    );

    if (!_player.playing) {
      await _player.play();
    }
  }

  Future<void> _saveJson() async {
    final json =
        _json;

    if (json == null) {
      return;
    }

    json['lines'] =
        _lines;

    if (_durationMs > 0) {
      json['durationMs'] =
          _durationMs;
    }

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

  Future<void> _saveFinal() async {
    if (_saving) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await _saveJson();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Calibration saved',
          ),
        ),
      );

      setState(() {
        _saving = false;
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

  String _formatTime(
    int milliseconds,
  ) {
    var value =
        milliseconds;

    if (value < 0) {
      value = 0;
    }

    final minutes =
        value ~/ 60000;

    final seconds =
        (value % 60000) ~/ 1000;

    final millis =
        value % 1000;

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }

  KeyEventResult _handleKey(
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent &&
        event is! KeyRepeatEvent) {
      return KeyEventResult
          .ignored;
    }

    if (event.logicalKey ==
        LogicalKeyboardKey.space) {
      _togglePlay();

      return KeyEventResult
          .handled;
    }

    if (event.logicalKey ==
        LogicalKeyboardKey.arrowLeft) {
      _seekBy(
        -1000,
      );

      return KeyEventResult
          .handled;
    }

    if (event.logicalKey ==
        LogicalKeyboardKey.arrowRight) {
      _seekBy(
        1000,
      );

      return KeyEventResult
          .handled;
    }

    return KeyEventResult
        .ignored;
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _stateSub?.cancel();

    _keyboardFocus.dispose();

    _player.dispose();

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
      );
    }

    final index =
        _displayedLineIndex;

    final line =
        _lines[index];

    final text =
        line['text']
                ?.toString() ??
            '';

    final currentStart =
        _effectiveStart(
      index,
    );

    final originalStart =
        _originalStart(
      index,
    );

    final delta =
        currentStart -
            originalStart;

    return Scaffold(
      backgroundColor:
          const Color(
        0xFF080808,
      ),
      body: SafeArea(
        child: Focus(
          focusNode:
              _keyboardFocus,
          autofocus: true,
          onKeyEvent:
              _handleKey,
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
                          () {
                        Navigator.pop(
                          context,
                        );
                      },
                      icon:
                          const Icon(
                        Icons
                            .arrow_back_rounded,
                      ),
                    ),
                    const SizedBox(
                      width: 8,
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
                                  Colors
                                      .white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed:
                          _saving
                              ? null
                              : _saveFinal,
                      icon:
                          const Icon(
                        Icons
                            .save_rounded,
                      ),
                      label:
                          const Text(
                        'SAVE',
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal:
                      28,
                  vertical:
                      8,
                ),
                child: Row(
                  children: [
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
                        borderRadius:
                            BorderRadius
                                .circular(
                          18,
                        ),
                        color:
                            _isEditLocked
                                ? Colors
                                    .orange
                                    .withValues(
                                      alpha:
                                          0.12,
                                    )
                                : Colors
                                    .greenAccent
                                    .withValues(
                                      alpha:
                                          0.10,
                                    ),
                      ),
                      child: Text(
                        _isEditLocked
                            ? 'EDIT LOCK'
                            : 'AUTO FOLLOW',
                        style:
                            TextStyle(
                          color:
                              _isEditLocked
                                  ? Colors
                                      .orangeAccent
                                  : Colors
                                      .greenAccent,
                          fontSize:
                              11,
                          fontWeight:
                              FontWeight
                                  .w700,
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
                      horizontal:
                          60,
                    ),
                    child: Column(
                      mainAxisAlignment:
                          MainAxisAlignment
                              .center,
                      children: [
                        Text(
                          text,
                          textAlign:
                              TextAlign
                                  .center,
                          maxLines: 2,
                          overflow:
                              TextOverflow
                                  .ellipsis,
                          style:
                              const TextStyle(
                            fontSize:
                                38,
                            fontWeight:
                                FontWeight
                                    .w700,
                            height:
                                1.25,
                          ),
                        ),

                        const SizedBox(
                          height: 30,
                        ),

                        Text(
                          'CTC  ${_formatTime(originalStart)}',
                          style:
                              const TextStyle(
                            color:
                                Colors
                                    .white38,
                          ),
                        ),

                        const SizedBox(
                          height: 5,
                        ),

                        Text(
                          'CURRENT  ${_formatTime(currentStart)}',
                          style:
                              const TextStyle(
                            color:
                                Colors
                                    .white70,
                          ),
                        ),

                        const SizedBox(
                          height: 5,
                        ),

                        Text(
                          'Δ ${delta >= 0 ? '+' : ''}${delta} ms',
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
                  horizontal:
                      30,
                ),
                child: Slider(
                  value:
                      _positionMs
                          .toDouble()
                          .clamp(
                            0,
                            _durationMs
                                .toDouble(),
                          ),
                  min: 0,
                  max:
                      _durationMs > 0
                          ? _durationMs
                              .toDouble()
                          : 1,
                  onChanged:
                      (value) {
                    _player.seek(
                      Duration(
                        milliseconds:
                            value
                                .round(),
                      ),
                    );
                  },
                ),
              ),

              Padding(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal:
                      34,
                ),
                child: Row(
                  children: [
                    Text(
                      _formatTime(
                        _positionMs,
                      ),
                      style:
                          const TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTime(
                        _durationMs,
                      ),
                      style:
                          const TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(
                height: 12,
              ),

              Wrap(
                alignment:
                    WrapAlignment
                        .center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton(
                    onPressed:
                        () =>
                            _seekBy(
                      -5000,
                    ),
                    child:
                        const Text(
                      '-5s',
                    ),
                  ),
                  OutlinedButton(
                    onPressed:
                        () =>
                            _seekBy(
                      -1000,
                    ),
                    child:
                        const Text(
                      '-1s',
                    ),
                  ),
                  IconButton.filled(
                    onPressed:
                        _togglePlay,
                    icon: Icon(
                      _playing
                          ? Icons
                              .pause_rounded
                          : Icons
                              .play_arrow_rounded,
                    ),
                  ),
                  OutlinedButton(
                    onPressed:
                        () =>
                            _seekBy(
                      1000,
                    ),
                    child:
                        const Text(
                      '+1s',
                    ),
                  ),
                  OutlinedButton(
                    onPressed:
                        () =>
                            _seekBy(
                      5000,
                    ),
                    child:
                        const Text(
                      '+5s',
                    ),
                  ),
                ],
              ),

              Padding(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  34,
                  14,
                  34,
                  4,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons
                          .volume_down_rounded,
                      size: 20,
                    ),
                    Expanded(
                      child: Slider(
                        value:
                            _volume,
                        min: 0,
                        max: 1,
                        onChanged:
                            _setVolume,
                      ),
                    ),
                    const Icon(
                      Icons
                          .volume_up_rounded,
                      size: 20,
                    ),
                  ],
                ),
              ),

              Padding(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  24,
                  8,
                  24,
                  14,
                ),
                child:
                    FilledButton.icon(
                  onPressed:
                      _marking
                          ? null
                          : _markNow,
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
                      vertical:
                          13,
                      horizontal:
                          18,
                    ),
                    child:
                        Text(
                      'MARK CURRENT LINE',
                    ),
                  ),
                ),
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
                        _replayLine,
                    icon:
                        const Icon(
                      Icons
                          .replay_rounded,
                    ),
                    label:
                        const Text(
                      'REPLAY',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        _resetCurrentLineToCtc,
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
                        _isEditLocked
                            ? _returnToAutoFollow
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

              if (_lastSavedMessage !=
                  null)
                Padding(
                  padding:
                      const EdgeInsets
                          .only(
                    top: 12,
                  ),
                  child: Text(
                    _lastSavedMessage!,
                    style:
                        const TextStyle(
                      color:
                          Colors
                              .greenAccent,
                      fontSize: 12,
                    ),
                  ),
                ),

              const SizedBox(
                height: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}