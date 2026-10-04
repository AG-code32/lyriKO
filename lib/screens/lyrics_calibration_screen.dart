import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

class LyricsCalibrationScreen extends StatefulWidget {
  const LyricsCalibrationScreen({
    super.key,
  });

  @override
  State<LyricsCalibrationScreen> createState() =>
      _LyricsCalibrationScreenState();
}

class _LyricsCalibrationScreenState
    extends State<LyricsCalibrationScreen> {
  final AudioPlayer _player = AudioPlayer();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;

  Map<String, dynamic>? _json;

  List<Map<String, dynamic>> _lines = [];

  //
  // Línea que corresponde al tiempo real del reproductor.
  //
  int _autoLineIndex = 0;

  //
  // Si tiene valor, esta es la línea bloqueada para edición.
  // El reproductor puede moverse sin cambiar la línea visible.
  //
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
      _editingLineIndex ?? _autoLineIndex;

  bool get _isEditLocked =>
      _editingLineIndex != null;

  String get _userProfile {
    final value =
        Platform.environment['USERPROFILE'];

    if (value == null ||
        value.isEmpty) {
      throw StateError(
        'USERPROFILE could not be found.',
      );
    }

    return value;
  }

  String get _projectRoot =>
      '$_userProfile\\Desktop\\fluter_projects\\Lyriko\\lyrics_app';

  String get _syncJsonPath =>
      '$_projectRoot\\assets\\lyrics\\Avenged Sevenfold - Nobody.json';

  String get _albumRoot =>
      r'F:\Nueva carpeta\Avenged Sevenfold - Life Is But A Dream (2023) Mp3 320kbps (PMEDIA)';

  @override
  void initState() {
    super.initState();

    _load();
  }

  Future<void> _load() async {
    try {
      final jsonFile =
          File(_syncJsonPath);

      if (!await jsonFile.exists()) {
        throw StateError(
          'Sync JSON not found:\n'
          '$_syncJsonPath',
        );
      }

      final raw =
          await jsonFile.readAsString(
        encoding: utf8,
      );

      final decoded =
          jsonDecode(raw)
              as Map<String, dynamic>;

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
              .map(
                (item) =>
                    Map<String, dynamic>.from(
                  item as Map,
                ),
              )
              .toList();

      //
      // Mantener referencia CTC original.
      //
      for (final line in lines) {
        line['originalStartMs'] ??=
            line['startMs'] ?? 0;

        line['originalEndMs'] ??=
            line['endMs'] ?? 0;
      }

      final mp3Path =
          await _findNobodyMp3();

      await _player.setFilePath(
        mp3Path,
      );

      await _player.setVolume(
        _volume,
      );

      _durationMs =
          _player.duration
                  ?.inMilliseconds ??
              0;

      //
      // El reproductor SIEMPRE calcula
      // qué línea corresponde al tiempo.
      //
      // Pero si estamos en EDIT LOCK,
      // NO modifica la línea que vemos.
      //
      _positionSub =
          _player.positionStream.listen(
        (position) {
          if (!mounted) {
            return;
          }

          final newPosition =
              position.inMilliseconds;

          final newAutoLine =
              _findLineForPosition(
            newPosition,
          );

          setState(() {
            _positionMs =
                newPosition;

            if (newAutoLine >= 0) {
              _autoLineIndex =
                  newAutoLine;
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
        _json =
            decoded;

        _lines =
            lines;

        _autoLineIndex =
            0;

        _editingLineIndex =
            null;

        _loading =
            false;
      });

      //
      // Al abrir:
      // ir EXACTAMENTE al start guardado
      // de la primera línea.
      //
      final firstStart =
          _effectiveStart(0);

      await _player.seek(
        Duration(
          milliseconds:
              _clamp(
            firstStart,
          ),
        ),
      );

      _syncAutoLineToPlayer();
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loading =
            false;

        _error =
            e.toString();
      });
    }
  }

  Future<String> _findNobodyMp3() async {
    final folder =
        Directory(_albumRoot);

    if (!await folder.exists()) {
      throw StateError(
        'Album folder not found:\n'
        '$_albumRoot',
      );
    }

    await for (final entity
        in folder.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }

      final lower =
          entity.path.toLowerCase();

      if (lower.endsWith('.mp3') &&
          lower.contains('nobody')) {
        return entity.path;
      }
    }

    throw StateError(
      'Nobody MP3 was not found.',
    );
  }

  Map<String, dynamic> _line(
    int index,
  ) {
    return Map<String, dynamic>.from(
      _lines[index],
    );
  }

  int _manualStart(
    int index,
  ) {
    final value =
        _lines[index]['startMs'];

    if (value is num) {
      return value.toInt();
    }

    return 0;
  }

  int _originalStart(
    int index,
  ) {
    final value =
        _lines[index]
            ['originalStartMs'];

    if (value is num) {
      return value.toInt();
    }

    return _manualStart(
      index,
    );
  }

  int _effectiveStart(
    int index,
  ) {
    return _manualStart(
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
        _effectiveStart(0)) {
      return 0;
    }

    //
    // Encontrar la última línea cuyo
    // startMs sea <= al playhead.
    //
    for (var i =
            _lines.length - 1;
        i >= 0;
        i--) {
      if (positionMs >=
          _effectiveStart(i)) {
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

  String _formatTime(
    int milliseconds,
  ) {
    var ms =
        milliseconds;

    if (ms < 0) {
      ms = 0;
    }

    final minutes =
        ms ~/ 60000;

    final seconds =
        (ms % 60000) ~/ 1000;

    final millis =
        ms % 1000;

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
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

    _syncAutoLineToPlayer();
  }

  void _syncAutoLineToPlayer() {
    if (!mounted ||
        _lines.isEmpty) {
      return;
    }

    final position =
        _player.position
            .inMilliseconds;

    final index =
        _findLineForPosition(
      position,
    );

    setState(() {
      _positionMs =
          position;

      if (index >= 0) {
        _autoLineIndex =
            index;
      }
    });
  }

  Future<void> _setVolume(
    double value,
  ) async {
    final safeVolume =
        value.clamp(
      0.0,
      1.0,
    );

    setState(() {
      _volume =
          safeVolume;
    });

    await _player.setVolume(
      safeVolume,
    );
  }

  //
  // =============================
  // AUTO FOLLOW
  // =============================
  //
  void _returnToAutoFollow() {
    final position =
        _player.position
            .inMilliseconds;

    final index =
        _findLineForPosition(
      position,
    );

    setState(() {
      _editingLineIndex =
          null;

      _positionMs =
          position;

      if (index >= 0) {
        _autoLineIndex =
            index;
      }

      _lastSavedMessage =
          null;
    });
  }

  //
  // =============================
  // MARK
  // =============================
  //
  Future<void> _markNow() async {
    if (_marking ||
        _lines.isEmpty) {
      return;
    }

    //
    // Si estamos editando una línea bloqueada,
    // modificamos ESA línea.
    //
    // Si estamos en AUTO FOLLOW,
    // modificamos la línea activa automática.
    //
    final lineIndex =
        _displayedLineIndex;

    final position =
        _player.position
            .inMilliseconds;

    setState(() {
      _marking =
          true;
    });

    try {
      final current =
          _line(
        lineIndex,
      );

      current['startMs'] =
          position;

      current['words'] =
          <dynamic>[];

      _lines[lineIndex] =
          current;

      if (lineIndex > 0) {
        final previous =
            _line(
          lineIndex - 1,
        );

        previous['endMs'] =
            position > 0
                ? position - 1
                : 0;

        previous['words'] =
            <dynamic>[];

        _lines[lineIndex - 1] =
            previous;
      }

      await _saveJson();

      if (!mounted) {
        return;
      }

      final autoIndex =
          _findLineForPosition(
        position,
      );

      setState(() {
        if (autoIndex >= 0) {
          _autoLineIndex =
              autoIndex;
        }

        _lastSavedMessage =
            'Line ${lineIndex + 1} saved at '
            '${_formatTime(position)}';

        _marking =
            false;
      });

      //
      // Si había EDIT LOCK,
      // permanece bloqueado.
      //
      // Tú decides cuándo volver a AUTO.
      //
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _marking =
            false;

        _error =
            e.toString();
      });
    }
  }

  //
  // =============================
  // RESET TO CTC
  // =============================
  //
  Future<void> _resetCurrentLineToCtc() async {
    if (_lines.isEmpty ||
        _marking) {
      return;
    }

    final index =
        _displayedLineIndex;

    //
    // Entramos en EDIT LOCK.
    //
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

    //
    // Ir EXACTAMENTE al CTC.
    //
    await _player.seek(
      Duration(
        milliseconds:
            _clamp(
          original,
        ),
      ),
    );

    _syncAutoLineToPlayer();

    if (!mounted) {
      return;
    }

    setState(() {
      //
      // IMPORTANTE:
      // aunque el reproductor piense que corresponde
      // otra línea, mantenemos la elegida.
      //
      _editingLineIndex =
          index;

      _lastSavedMessage =
          'Line ${index + 1} reset to CTC '
          '${_formatTime(original)}';
    });
  }

  //
  // =============================
  // PREVIOUS
  // =============================
  //
  Future<void> _previousLine() async {
    final current =
        _displayedLineIndex;

    if (current <= 0) {
      return;
    }

    final target =
        current - 1;

    //
    // BLOQUEAMOS esta línea para editar.
    //
    setState(() {
      _editingLineIndex =
          target;

      _lastSavedMessage =
          null;
    });

    //
    // Ir exactamente a su start actual.
    //
    await _player.seek(
      Duration(
        milliseconds:
            _effectiveStart(
          target,
        ),
      ),
    );

    _syncAutoLineToPlayer();

    //
    // _syncAutoLineToPlayer puede calcular
    // otra línea automática,
    // pero EDIT LOCK sigue mostrando target.
    //
  }

  //
  // =============================
  // NEXT
  // =============================
  //
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

      _lastSavedMessage =
          null;
    });

    await _player.seek(
      Duration(
        milliseconds:
            _effectiveStart(
          target,
        ),
      ),
    );

    _syncAutoLineToPlayer();
  }

  //
  // =============================
  // REPLAY
  // =============================
  //
  Future<void> _replayLine() async {
    final targetIndex =
        _displayedLineIndex;

    //
    // Replay también entra en EDIT LOCK.
    //
    setState(() {
      _editingLineIndex =
          targetIndex;
    });

    //
    // SIN 2.5 segundos.
    //
    // Va EXACTAMENTE al start actual.
    //
    final targetTime =
        _effectiveStart(
      targetIndex,
    );

    await _player.seek(
      Duration(
        milliseconds:
            _clamp(
          targetTime,
        ),
      ),
    );

    _syncAutoLineToPlayer();

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
      _syncJsonPath,
    ).writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(
        json,
      ),
      encoding:
          utf8,
      flush:
          true,
    );
  }

  Future<void> _saveFinal() async {
    if (_saving) {
      return;
    }

    setState(() {
      _saving =
          true;
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
    } finally {
      if (mounted) {
        setState(() {
          _saving =
              false;
        });
      }
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _stateSub?.cancel();

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
        body: Center(
          child: Padding(
            padding:
                const EdgeInsets.all(
              30,
            ),
            child: Text(
              _error!,
              textAlign:
                  TextAlign.center,
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

    final displayedIndex =
        _displayedLineIndex;

    final current =
        _lines[
            displayedIndex];

    final previousText =
        displayedIndex > 0
            ? _lines[
                    displayedIndex -
                        1]
                ['text']
                .toString()
            : '';

    final nextText =
        displayedIndex <
                _lines.length - 1
            ? _lines[
                    displayedIndex +
                        1]
                ['text']
                .toString()
            : '';

    final maxSlider =
        _durationMs > 0
            ? _durationMs
                .toDouble()
            : 1.0;

    final sliderValue =
        _clamp(
          _positionMs,
        )
            .toDouble()
            .clamp(
              0.0,
              maxSlider,
            );

    return Scaffold(
      backgroundColor:
          const Color(
        0xFF080808,
      ),

      body: SafeArea(
        child: Focus(
          autofocus:
              true,

          onKeyEvent: (
            node,
            event,
          ) {
            if (event
                    is KeyRepeatEvent &&
                event.logicalKey ==
                    LogicalKeyboardKey
                        .space) {
              return KeyEventResult
                  .handled;
            }

            if (event
                    is KeyDownEvent &&
                event.logicalKey ==
                    LogicalKeyboardKey
                        .space) {
              _markNow();

              return KeyEventResult
                  .handled;
            }

            return KeyEventResult
                .ignored;
          },

          child: Column(
            children: [
              //
              // HEADER
              //
              Padding(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  22,
                  14,
                  26,
                  14,
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
                        Icons
                            .arrow_back_rounded,
                      ),
                    ),

                    const SizedBox(
                      width:
                          10,
                    ),

                    const Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,

                        children: [
                          Text(
                            'Nobody Sync Calibration',

                            style:
                                TextStyle(
                              color:
                                  Colors.white,
                              fontSize:
                                  21,
                              fontWeight:
                                  FontWeight
                                      .w700,
                            ),
                          ),

                          Text(
                            'Avenged Sevenfold',

                            style:
                                TextStyle(
                              color:
                                  Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ),

                    //
                    // MODE INDICATOR
                    //
                    Container(
                      padding:
                          const EdgeInsets
                              .symmetric(
                        horizontal:
                            12,
                        vertical:
                            7,
                      ),

                      decoration:
                          BoxDecoration(
                        borderRadius:
                            BorderRadius
                                .circular(
                          20,
                        ),

                        border:
                            Border.all(
                          color:
                              _isEditLocked
                                  ? Colors
                                      .orangeAccent
                                  : Colors
                                      .greenAccent,
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
                              12,

                          fontWeight:
                              FontWeight
                                  .w700,
                        ),
                      ),
                    ),

                    const SizedBox(
                      width:
                          16,
                    ),

                    Text(
                      '${displayedIndex + 1} / ${_lines.length}',

                      style:
                          const TextStyle(
                        color:
                            Colors.white54,

                        fontFeatures: [
                          FontFeature
                              .tabularFigures(),
                        ],
                      ),
                    ),

                    const SizedBox(
                      width:
                          20,
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

              const Divider(
                height:
                    1,
                color:
                    Colors.white12,
              ),

              Expanded(
                child: Center(
                  child:
                      SingleChildScrollView(
                    padding:
                        const EdgeInsets
                            .fromLTRB(
                      40,
                      20,
                      40,
                      28,
                    ),

                    child:
                        ConstrainedBox(
                      constraints:
                          const BoxConstraints(
                        maxWidth:
                            1100,
                      ),

                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min,

                        children: [
                          //
                          // FIXED LYRIC PANEL
                          //
                          SizedBox(
                            height:
                                245,

                            child: Column(
                              children: [
                                SizedBox(
                                  height:
                                      42,

                                  child: Center(
                                    child: Text(
                                      previousText,

                                      maxLines:
                                          1,

                                      overflow:
                                          TextOverflow
                                              .ellipsis,

                                      textAlign:
                                          TextAlign
                                              .center,

                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white24,

                                        fontSize:
                                            18,
                                      ),
                                    ),
                                  ),
                                ),

                                const SizedBox(
                                  height:
                                      6,
                                ),

                                SizedBox(
                                  height:
                                      108,

                                  child: Center(
                                    child:
                                        AnimatedSwitcher(
                                      duration:
                                          const Duration(
                                        milliseconds:
                                            160,
                                      ),

                                      child:
                                          Text(
                                        current['text']
                                            .toString(),

                                        key:
                                            ValueKey(
                                          displayedIndex,
                                        ),

                                        maxLines:
                                            2,

                                        overflow:
                                            TextOverflow
                                                .ellipsis,

                                        textAlign:
                                            TextAlign
                                                .center,

                                        style:
                                            const TextStyle(
                                          color:
                                              Colors.white,

                                          fontSize:
                                              38,

                                          height:
                                              1.18,

                                          fontWeight:
                                              FontWeight
                                                  .w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                                SizedBox(
                                  height:
                                      36,

                                  child: Center(
                                    child: Text(
                                      'Start: '
                                      '${_formatTime(_effectiveStart(displayedIndex))}'
                                      '   •   '
                                      'CTC: '
                                      '${_formatTime(_originalStart(displayedIndex))}',

                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white38,

                                        fontFeatures: [
                                          FontFeature
                                              .tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),

                                SizedBox(
                                  height:
                                      45,

                                  child: Center(
                                    child: Text(
                                      nextText,

                                      maxLines:
                                          1,

                                      overflow:
                                          TextOverflow
                                              .ellipsis,

                                      textAlign:
                                          TextAlign
                                              .center,

                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white24,

                                        fontSize:
                                            18,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          SizedBox(
                            height:
                                28,

                            child: Center(
                              child:
                                  _lastSavedMessage ==
                                          null
                                      ? const SizedBox()
                                      : Text(
                                          _lastSavedMessage!,

                                          style:
                                              const TextStyle(
                                            color:
                                                Colors.white54,

                                            fontSize:
                                                12,

                                            fontFeatures: [
                                              FontFeature
                                                  .tabularFigures(),
                                            ],
                                          ),
                                        ),
                            ),
                          ),

                          const SizedBox(
                            height:
                                12,
                          ),

                          //
                          // TIMELINE
                          //
                          Slider(
                            min:
                                0,

                            max:
                                maxSlider,

                            value:
                                sliderValue,

                            onChanged: (
                              value,
                            ) async {
                              await _player
                                  .seek(
                                Duration(
                                  milliseconds:
                                      value.round(),
                                ),
                              );

                              _syncAutoLineToPlayer();
                            },
                          ),

                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .spaceBetween,

                            children: [
                              Text(
                                _formatTime(
                                  _positionMs,
                                ),

                                style:
                                    const TextStyle(
                                  color:
                                      Colors.white,

                                  fontSize:
                                      21,

                                  fontWeight:
                                      FontWeight
                                          .w600,

                                  fontFeatures: [
                                    FontFeature
                                        .tabularFigures(),
                                  ],
                                ),
                              ),

                              Text(
                                _formatTime(
                                  _durationMs,
                                ),

                                style:
                                    const TextStyle(
                                  color:
                                      Colors.white30,

                                  fontSize:
                                      15,

                                  fontFeatures: [
                                    FontFeature
                                        .tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(
                            height:
                                18,
                          ),

                          //
                          // PLAYER
                          //
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,

                            children: [
                              OutlinedButton(
                                onPressed: () {
                                  _seekBy(
                                    -5000,
                                  );
                                },

                                child:
                                    const Padding(
                                  padding:
                                      EdgeInsets
                                          .symmetric(
                                    horizontal:
                                        10,
                                    vertical:
                                        11,
                                  ),

                                  child:
                                      Text(
                                    '-5 s',
                                  ),
                                ),
                              ),

                              const SizedBox(
                                width:
                                    12,
                              ),

                              OutlinedButton(
                                onPressed: () {
                                  _seekBy(
                                    -1000,
                                  );
                                },

                                child:
                                    const Padding(
                                  padding:
                                      EdgeInsets
                                          .symmetric(
                                    horizontal:
                                        10,
                                    vertical:
                                        11,
                                  ),

                                  child:
                                      Text(
                                    '-1 s',
                                  ),
                                ),
                              ),

                              const SizedBox(
                                width:
                                    20,
                              ),

                              FilledButton(
                                style:
                                    FilledButton
                                        .styleFrom(
                                  shape:
                                      const CircleBorder(),

                                  padding:
                                      const EdgeInsets.all(
                                    25,
                                  ),
                                ),

                                onPressed:
                                    _togglePlay,

                                child:
                                    Icon(
                                  _playing
                                      ? Icons
                                          .pause_rounded
                                      : Icons
                                          .play_arrow_rounded,

                                  size:
                                      44,
                                ),
                              ),

                              const SizedBox(
                                width:
                                    20,
                              ),

                              OutlinedButton(
                                onPressed: () {
                                  _seekBy(
                                    1000,
                                  );
                                },

                                child:
                                    const Padding(
                                  padding:
                                      EdgeInsets
                                          .symmetric(
                                    horizontal:
                                        10,
                                    vertical:
                                        11,
                                  ),

                                  child:
                                      Text(
                                    '+1 s',
                                  ),
                                ),
                              ),

                              const SizedBox(
                                width:
                                    12,
                              ),

                              OutlinedButton(
                                onPressed: () {
                                  _seekBy(
                                    5000,
                                  );
                                },

                                child:
                                    const Padding(
                                  padding:
                                      EdgeInsets
                                          .symmetric(
                                    horizontal:
                                        10,
                                    vertical:
                                        11,
                                  ),

                                  child:
                                      Text(
                                    '+5 s',
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(
                            height:
                                18,
                          ),

                          //
                          // VOLUME
                          //
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,

                            children: [
                              Icon(
                                _volume == 0
                                    ? Icons
                                        .volume_off_rounded
                                    : _volume <
                                            0.5
                                        ? Icons
                                            .volume_down_rounded
                                        : Icons
                                            .volume_up_rounded,

                                color:
                                    Colors.white54,

                                size:
                                    22,
                              ),

                              const SizedBox(
                                width:
                                    8,
                              ),

                              SizedBox(
                                width:
                                    260,

                                child:
                                    Slider(
                                  min:
                                      0,

                                  max:
                                      1,

                                  divisions:
                                      20,

                                  value:
                                      _volume,

                                  onChanged:
                                      _setVolume,
                                ),
                              ),

                              const SizedBox(
                                width:
                                    8,
                              ),

                              SizedBox(
                                width:
                                    46,

                                child: Text(
                                  '${(_volume * 100).round()}%',

                                  textAlign:
                                      TextAlign
                                          .right,

                                  style:
                                      const TextStyle(
                                    color:
                                        Colors.white54,

                                    fontFeatures: [
                                      FontFeature
                                          .tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(
                            height:
                                16,
                          ),

                          //
                          // MARK
                          //
                          FilledButton.icon(
                            onPressed:
                                _marking
                                    ? null
                                    : _markNow,

                            icon:
                                const Icon(
                              Icons
                                  .my_location_rounded,
                            ),

                            label:
                                Padding(
                              padding:
                                  const EdgeInsets
                                      .symmetric(
                                horizontal:
                                    28,
                                vertical:
                                    15,
                              ),

                              child: Text(
                                _marking
                                    ? 'SAVING...'
                                    : _isEditLocked
                                        ? 'MARK EDIT LINE  •  SPACE'
                                        : 'MARK CURRENT LINE  •  SPACE',

                                style:
                                    const TextStyle(
                                  fontWeight:
                                      FontWeight
                                          .w700,

                                  fontSize:
                                      15,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(
                            height:
                                20,
                          ),

                          //
                          // NAVIGATION
                          //
                          Wrap(
                            alignment:
                                WrapAlignment
                                    .center,

                            spacing:
                                12,

                            runSpacing:
                                10,

                            children: [
                              OutlinedButton.icon(
                                onPressed:
                                    displayedIndex >
                                            0
                                        ? _previousLine
                                        : null,

                                icon:
                                    const Icon(
                                  Icons
                                      .chevron_left,
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
                                      .restart_alt,
                                ),

                                label:
                                    const Text(
                                  'REPLAY LINE',
                                ),
                              ),

                              OutlinedButton.icon(
                                onPressed:
                                    _resetCurrentLineToCtc,

                                icon:
                                    const Icon(
                                  Icons
                                      .restore_rounded,
                                ),

                                label:
                                    const Text(
                                  'RESET TO CTC',
                                ),
                              ),

                              OutlinedButton.icon(
                                onPressed:
                                    displayedIndex <
                                            _lines.length -
                                                1
                                        ? _nextLine
                                        : null,

                                icon:
                                    const Icon(
                                  Icons
                                      .chevron_right,
                                ),

                                label:
                                    const Text(
                                  'NEXT',
                                ),
                              ),

                              //
                              // Salir explícitamente de EDIT LOCK.
                              //
                              FilledButton.icon(
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
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}