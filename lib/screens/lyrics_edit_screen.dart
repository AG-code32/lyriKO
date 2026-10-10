import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/timeline_lyric_line.dart';
import '../services/synced_lyrics_service.dart';
import '../services/waveform_cache_service.dart';
import '../services/lyriko_server_client.dart';
import '../widgets/lyrics_timeline/lyrics_track.dart';
import '../widgets/lyrics_timeline/timeline_ruler.dart';
import '../widgets/lyrics_timeline/timeline_transport.dart';
import '../widgets/lyrics_timeline/waveform_track.dart';

class LyricsEditScreen extends StatefulWidget {
  final String jsonPath;

  const LyricsEditScreen({
    super.key,
    required this.jsonPath,
  });

  @override
  State<LyricsEditScreen> createState() =>
      _LyricsEditScreenState();
}

class _LyricsEditScreenState
    extends State<LyricsEditScreen>
    with SingleTickerProviderStateMixin {
  static const double _rulerHeight =
      46;

  static const double _audioHeight =
      184;

  static const double _lyricsHeight =
      166;

  static const double _labelWidth =
      92;

  static const int _minClipMs =
      300;

  final AudioPlayer _player =
      AudioPlayer();

  final WaveformCacheService
      _waveformService =
      WaveformCacheService();

  final ScrollController
      _scrollController =
      ScrollController();

  final GlobalKey _timelineAreaKey = GlobalKey();
  final Map<int, Offset> _touchPoints = <int, Offset>{};
  bool _pinchActive = false;
  bool _marqueeSelecting = false;
  double? _lastPinchDistance;

  void _trackTouchDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touchPoints[event.pointer] = event.position;
    if (_touchPoints.length == 2) {
      setState(() => _pinchActive = true);
      _lastPinchDistance = _distanceBetweenTouches();
    }
  }

  double _distanceBetweenTouches() {
    final points = _touchPoints.values.toList();
    if (points.length < 2) return 0;
    return (points[0] - points[1]).distance;
  }

  void _trackTouchMove(PointerMoveEvent event) {
    if (!_touchPoints.containsKey(event.pointer)) return;
    _touchPoints[event.pointer] = event.position;
    if (_touchPoints.length != 2 || !_pinchActive) return;
    final distance = _distanceBetweenTouches();
    final previous = _lastPinchDistance;
    _lastPinchDistance = distance;
    if (previous == null || previous < 8 || distance < 8) return;
    final box = _timelineAreaKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final points = _touchPoints.values.toList();
    final focalGlobal = (points[0] + points[1]) / 2;
    final focalLocal = box.globalToLocal(focalGlobal);
    _zoom(focalLocal.dx, (distance / previous).clamp(0.75, 1.35));
  }

  void _trackTouchEnd(PointerEvent event) {
    _touchPoints.remove(event.pointer);
    if (_touchPoints.length < 2) {
      _lastPinchDistance = null;
      if (_pinchActive) setState(() => _pinchActive = false);
    }
  }


  void _onMarqueeStateChanged(bool active) {
    if (!mounted || _marqueeSelecting == active) return;
    if (active && _scrollController.hasClients) {
      // Stop any previous drag or inertial horizontal scrolling immediately.
      _scrollController.jumpTo(_scrollController.offset);
    }
    setState(() => _marqueeSelecting = active);
  }

  final FocusNode _focusNode =
      FocusNode();

  final ValueNotifier<int> _playhead =
      ValueNotifier<int>(0);

  late final Ticker _playheadTicker;

  final Stopwatch _playheadClock =
      Stopwatch();

  int _playheadAnchorMs = 0;


  bool _seekInProgress = false;

  final SyncedLyricsService _lyricsStorage = SyncedLyricsService();
  final LyrikoServerClient _server = LyrikoServerClient();
  String? _serverSongId;
  int? _serverVersion;
  String? _editableJsonPath;
  Map<String, dynamic>? _json;

  final List<TimelineLyricLine>
      _lines =
      [];

  List<double> _waveform =
      [];

  String _title = '';

  String _artist = '';

  String _audioPath = '';

  bool _loading = true;

  bool _waveformLoading = false;

  bool _audioAvailable = false;

  bool _playing = false;

  bool _dirty = false;

  bool _saving = false;

  bool _scrubbing = false;

  double _volume = 1.0;
  bool _volumeSliderVisible = false;

  int _durationMs = 0;

  int? _selectedIndex;

  final Set<int> _selectedIndices =
      <int>{};

  int? _hoveredIndex;

  double _pixelsPerSecond =
      50;

  double _dragStartX = 0;

  final Map<int, _DragLineSnapshot>
      _dragSnapshots =
      {};

  DateTime _lastAutoScroll =
      DateTime.fromMillisecondsSinceEpoch(
    0,
  );

  String? _error;

  @override
  void initState() {
    super.initState();

    _playheadTicker =
        createTicker(
      _onPlayheadFrame,
    );

    _load();

    _player.positionStream.listen(
      (position) {
        if (!mounted) {
          return;
        }

        final realMs =
            position.inMilliseconds
                .clamp(
                  0,
                  _durationMs,
                )
                .toInt();


        if (_seekInProgress) {
          return;
        }

        if (!_playing) {
          _setPlayheadReference(
            realMs,
            updateVisual:
                true,
          );

          return;
        }

        final predicted =
            _predictedPlayheadMs();

        final drift =
            realMs -
                predicted;

        final absoluteDrift =
            drift.abs();

        if (absoluteDrift >
            180) {
          _setPlayheadReference(
            realMs,
            updateVisual:
                true,
          );

          return;
        }

        if (absoluteDrift >
            5) {
          final correction =
              (drift * 0.18)
                  .round();

          _playheadAnchorMs +=
              correction;
        }
      },
    );

    _player
        .playerStateStream
        .listen(
      (state) {
        if (!mounted) {
          return;
        }

        final nextPlaying =
            state.playing;

        if (_playing ==
            nextPlaying) {
          return;
        }

        if (nextPlaying) {
          final realMs =
              _player.position
                  .inMilliseconds
                  .clamp(
                    0,
                    _durationMs,
                  )
                  .toInt();


          _setPlayheadReference(
            realMs,
            updateVisual:
                true,
          );

          _playheadClock
            ..reset()
            ..start();

          if (!_playheadTicker
              .isActive) {
            _playheadTicker
                .start();
          }
        } else {
          if (_playheadTicker
              .isActive) {
            _playheadTicker
                .stop();
          }

          _playheadClock
              .stop();

          final realMs =
              _player.position
                  .inMilliseconds
                  .clamp(
                    0,
                    _durationMs,
                  )
                  .toInt();


          _setPlayheadReference(
            realMs,
            updateVisual:
                true,
          );
        }

        setState(() {
          _playing =
              nextPlaying;
        });
      },
    );
  }

  int _predictedPlayheadMs() {
    if (!_playing ||
        !_playheadClock
            .isRunning) {
      return _playheadAnchorMs;
    }

    return (_playheadAnchorMs +
            _playheadClock
                .elapsedMilliseconds)
        .clamp(
          0,
          _durationMs,
        )
        .toInt();
  }

  void _setPlayheadReference(
    int milliseconds, {
    required bool updateVisual,
  }) {
    final safe =
        milliseconds
            .clamp(
              0,
              _durationMs,
            )
            .toInt();

    _playheadAnchorMs =
        safe;


    if (_playing) {
      _playheadClock
        ..reset()
        ..start();
    } else {
      _playheadClock
        ..stop()
        ..reset();
    }

    if (updateVisual) {
      _playhead.value =
          safe;
    }
  }

  void _onPlayheadFrame(
    Duration elapsed,
  ) {
    if (!_playing ||
        _seekInProgress ||
        _scrubbing) {
      return;
    }

    final predicted =
        _predictedPlayheadMs();

    if (_playhead.value !=
        predicted) {
      _playhead.value =
          predicted;
    }

    _autoScroll(
      predicted,
    );

    if (predicted >=
        _durationMs) {
      if (_playheadTicker
          .isActive) {
        _playheadTicker
            .stop();
      }
    }
  }

  Future<void> _load()
      async {
    try {
      _editableJsonPath = await _lyricsStorage.editableJsonPath(widget.jsonPath);
      final file = File(_editableJsonPath!);

      if (!await file
          .exists()) {
        throw StateError(
          'Lyrics JSON not found:\n'
          '${widget.jsonPath}',
        );
      }

      // On macOS, Windows is the source of truth for editing.
      // iOS / Android keep their existing local/offline workflow.
      dynamic decoded;
      if (_server.enabled) {
        final remoteSong = await _server.songForPath(widget.jsonPath);
        if (remoteSong == null) {
          throw StateError('La canción no existe en Lyriko Server: ${widget.jsonPath}');
        }
        _serverSongId = remoteSong['id']?.toString();
        final envelope = await _server.lyrics(_serverSongId!);
        _serverVersion = (envelope['version'] as num).toInt();
        decoded = envelope['lyrics'];
      } else {
        decoded = jsonDecode(await file.readAsString(encoding: utf8));
      }

      if (decoded
          is! Map<String, dynamic>) {
        throw StateError(
          'Invalid JSON.',
        );
      }

      final rawLines =
          decoded['lines'];

      if (rawLines is! List) {
        throw StateError(
          'No lyric lines.',
        );
      }

      _lines.clear();

      for (final raw
          in rawLines) {
        final data =
            Map<String, dynamic>.from(
          raw as Map,
        );

        data['originalStartMs'] ??=
            data['startMs'] ??
                0;

        data['originalEndMs'] ??=
            data['endMs'] ??
                data['startMs'] ??
                0;

        data['words'] ??=
            <dynamic>[];

        _lines.add(
          TimelineLyricLine(
            data:
                data,
          ),
        );
      }

      _sortLines();

      _durationMs =
          (decoded['durationMs']
                  as num?)
              ?.toInt() ??
          0;

      if (_lines
          .isNotEmpty) {
        _durationMs =
            math.max(
          _durationMs,
          _lines
              .map(
                (line) =>
                    line.endMs,
              )
              .reduce(
                math.max,
              ),
        ).toInt();
      }

      if (_durationMs <=
          0) {
        _durationMs =
            180000;
      }

      _title =
          decoded['title']
                  ?.toString() ??
              '';

      _artist =
          decoded['artist']
                  ?.toString() ??
              '';

      _audioPath =
          decoded['audioPath']
                  ?.toString() ??
              '';

      _json =
          decoded;

      // Prefer previously imported audio; otherwise discover the bundled
      // development MP3 for this song without changing the lyrics JSON.
      if (!_server.enabled &&
          (_audioPath.isEmpty || !await File(_audioPath).exists())) {
        final bundledAudio = await _bundledAudioForSong();
        if (bundledAudio != null) _audioPath = bundledAudio;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _loading =
            false;
      });

      await _loadAudio();

      await _loadWaveform();

      WidgetsBinding
          .instance
          .addPostFrameCallback(
        (_) {
          if (mounted) {
            _focusNode
                .requestFocus();
          }
        },
      );
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

  Future<String?> _bundledAudioForSong() async {
    if (!(Platform.isIOS || Platform.isAndroid)) return null;
    final filename = widget.jsonPath.split('/').last.replaceFirst(
      RegExp(r'\.json$', caseSensitive: false), '');
    // Read only the requested song to avoid copying all MP3s on first launch.
    final asset = 'assets/audio/$filename.mp3';
    try {
      final data = await rootBundle.load(asset);
      final folder = Directory(
        '${(await getApplicationSupportDirectory()).path}/lyriko_audio');
      await folder.create(recursive: true);
      final file = File('${folder.path}/$filename.mp3');
      if (!await file.exists() || await file.length() != data.lengthInBytes) {
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true);
      }
      return file.path;
    } catch (_) {
      return null; // No MP3 bundled yet. Editing JSON remains available.
    }
  }

  Future<void> _loadAudio()
      async {
    if (_server.enabled) {
      if (_serverSongId == null) return;
    } else {
      if (_audioPath.isEmpty || !await File(_audioPath).exists()) return;
    }

    try {
      final duration = _server.enabled
          ? await _player.setUrl(await _server.audioUrl(_serverSongId!))
          : await _player.setFilePath(_audioPath);

      await _player
          .setVolume(
        _volume,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _audioAvailable =
            true;

        if (duration !=
                null &&
            duration
                    .inMilliseconds >
                0) {
          _durationMs =
              math.max(
            _durationMs,
            duration
                .inMilliseconds,
          ).toInt();
        }
      });

      _setPlayheadReference(
        0,
        updateVisual:
            true,
      );
    } catch (e) {
      debugPrint(
        'Audio error: $e',
      );
    }
  }

  Future<void> _loadWaveform()
      async {
    if (!mounted) {
      return;
    }

    setState(() {
      _waveformLoading =
          true;
    });

    try {
      final data = _server.enabled
          ? WaveformData(samples: await _server.waveform(_serverSongId!))
          : await _waveformService.loadOrCreate(
              songJsonPath: widget.jsonPath,
              audioPath: _audioPath,
            );

      if (!mounted) {
        return;
      }

      setState(() {
        _waveform =
            data?.samples ??
                [];

        _waveformLoading =
            false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _waveformLoading =
            false;
      });

      debugPrint(
        'Waveform error: $e',
      );
    }
  }

  void _sortLines() {
    _lines.sort(
      (a, b) =>
          a.startMs
              .compareTo(
        b.startMs,
      ),
    );
  }

  double _msToPx(
    int ms,
  ) {
    return ms /
        1000 *
        _pixelsPerSecond;
  }

  int _pxToMs(
    double px,
  ) {
    return (
      px /
          _pixelsPerSecond *
          1000
    ).round();
  }

  double get _timelineWidth {
    return math.max<double>(
      _msToPx(
            _durationMs,
          ) +
          100,
      1200,
    );
  }

  void _selectSingle(
    int index,
  ) {
    setState(() {
      _selectedIndex =
          index;

      _selectedIndices
        ..clear()
        ..add(
          index,
        );
    });
  }

  void _clearSelection() {
    if (_selectedIndex == null && _selectedIndices.isEmpty) return;
    setState(() {
      _selectedIndex = null;
      _selectedIndices.clear();
    });
  }

  void _selectGroup(
    Set<int> indices,
  ) {
    final clean =
        indices
            .where(
              (index) =>
                  index >=
                      0 &&
                  index <
                      _lines.length,
            )
            .toSet();

    int? primary;

    if (clean.isNotEmpty) {
      if (_selectedIndex !=
              null &&
          clean.contains(
            _selectedIndex,
          )) {
        primary =
            _selectedIndex;
      } else {
        final sorted =
            clean.toList()
              ..sort();

        primary =
            sorted.first;
      }
    }

    setState(() {
      _selectedIndices
        ..clear()
        ..addAll(
          clean,
        );

      _selectedIndex =
          primary;
    });
  }

  Future<void> _togglePlay()
      async {
    if (!_audioAvailable) {
      _message(
        'Original MP3 unavailable.',
      );

      return;
    }

    if (_playing) {
      await _player
          .pause();

      return;
    }

    if (_playhead.value >=
        _durationMs -
            100) {
      await _seek(
        0,
      );
    }

    final realMs =
        _player.position
            .inMilliseconds
            .clamp(
              0,
              _durationMs,
            )
            .toInt();

    _setPlayheadReference(
      realMs,
      updateVisual:
          true,
    );

    await _player
        .play();
  }

  Future<void> _setVolume(
    double value,
  ) async {
    final safe =
        value.clamp(
      0.0,
      1.0,
    ).toDouble();

    setState(() {
      _volume =
          safe;
    });

    await _player
        .setVolume(
      safe,
    );
  }

  Future<void> _seek(
    int ms,
  ) async {
    final value =
        ms.clamp(
      0,
      _durationMs,
    ).toInt();

    _playhead.value =
        value;

    _playheadAnchorMs =
        value;


    if (!_audioAvailable) {
      return;
    }

    _seekInProgress =
        true;

    _playheadClock
        .stop();

    try {
      await _player.seek(
        Duration(
          milliseconds:
              value,
        ),
      );

      final confirmed =
          _player.position
              .inMilliseconds
              .clamp(
                0,
                _durationMs,
              )
              .toInt();

      _setPlayheadReference(
        confirmed,
        updateVisual:
            true,
      );
    } finally {
      _seekInProgress =
          false;

      if (_playing) {
        _playheadClock
          ..reset()
          ..start();

        if (!_playheadTicker
            .isActive) {
          _playheadTicker
              .start();
        }
      }
    }
  }

  Future<void> _skip(
    int delta,
  ) {
    return _seek(
      _playhead.value +
          delta,
    );
  }

  void _autoScroll(
    int ms,
  ) {
    if (!_scrollController
        .hasClients) {
      return;
    }

    final now =
        DateTime.now();

    if (now.difference(
          _lastAutoScroll,
        ) <
        const Duration(
          milliseconds:
              180,
        )) {
      return;
    }

    final position =
        _scrollController
            .position;

    final viewport =
        position
            .viewportDimension;

    if (viewport <=
        0) {
      return;
    }

    final x =
        _msToPx(
      ms,
    );

    final leftBoundary =
        position.pixels +
            viewport *
                0.12;

    final rightBoundary =
        position.pixels +
            viewport *
                0.82;

    double? target;

    if (x >
        rightBoundary) {
      target =
          x -
              viewport *
                  0.35;
    } else if (x <
        leftBoundary) {
      target =
          x -
              viewport *
                  0.20;
    }

    if (target ==
        null) {
      return;
    }

    _lastAutoScroll =
        now;

    _scrollController
        .jumpTo(
      target
          .clamp(
            0.0,
            position
                .maxScrollExtent,
          )
          .toDouble(),
    );
  }

  void _wheel(
    PointerSignalEvent event,
  ) {
    if (event
        is! PointerScrollEvent) {
      return;
    }

    if (HardwareKeyboard
        .instance
        .isControlPressed) {
      _zoom(
        event.localPosition
            .dx,

        event.scrollDelta
                    .dy <
                0
            ? 1.18
            : 1 /
                1.18,
      );

      return;
    }

    if (!_scrollController
        .hasClients) {
      return;
    }

    final delta =
        event.scrollDelta
                    .dy !=
                0
            ? event
                .scrollDelta
                .dy
            : event
                .scrollDelta
                .dx;

    final target =
        (_scrollController
                    .offset +
                delta)
            .clamp(
      0.0,
      _scrollController
          .position
          .maxScrollExtent,
    );

    _scrollController
        .jumpTo(
      target.toDouble(),
    );
  }

  void _zoom(
    double pointerX,
    double factor,
  ) {
    final oldOffset =
        _scrollController
                .hasClients
            ? _scrollController
                .offset
            : 0.0;

    final anchorMs =
        _pxToMs(
      oldOffset +
          pointerX,
    );

    final newScale =
        (_pixelsPerSecond *
                factor)
            .clamp(
              12.0,
              350.0,
            )
            .toDouble();

    if (newScale ==
        _pixelsPerSecond) {
      return;
    }

    setState(() {
      _pixelsPerSecond =
          newScale;
    });

    WidgetsBinding
        .instance
        .addPostFrameCallback(
      (_) {
        if (!_scrollController
            .hasClients) {
          return;
        }

        final offset =
            _msToPx(
                  anchorMs,
                ) -
                pointerX;

        _scrollController
            .jumpTo(
          offset
              .clamp(
                0.0,
                _scrollController
                    .position
                    .maxScrollExtent,
              )
              .toDouble(),
        );
      },
    );
  }

  _DragLineSnapshot
      _captureSnapshot(
    int index,
  ) {
    final line =
        _lines[index];

    final wordSnapshots =
        <_WordTimingSnapshot>[];

    final words =
        line.data['words'];

    if (words
        is List) {
      for (final raw
          in words) {
        if (raw
            is! Map) {
          continue;
        }

        wordSnapshots.add(
          _WordTimingSnapshot(
            word:
                raw,

            startMs:
                raw['startMs']
                        is num
                    ? (raw['startMs']
                            as num)
                        .toInt()
                    : null,

            endMs:
                raw['endMs']
                        is num
                    ? (raw['endMs']
                            as num)
                        .toInt()
                    : null,
          ),
        );
      }
    }

    return _DragLineSnapshot(
      startMs:
          line.startMs,

      endMs:
          line.endMs,

      words:
          wordSnapshots,
    );
  }

  void _moveStart(
    int index,
    DragStartDetails details,
  ) {
    if (!_selectedIndices
        .contains(
      index,
    )) {
      _selectedIndices
        ..clear()
        ..add(
          index,
        );
    }

    _selectedIndex =
        index;

    _dragStartX =
        details
            .globalPosition
            .dx;

    _dragSnapshots
        .clear();

    for (final selected
        in _selectedIndices) {
      _dragSnapshots[selected] =
          _captureSnapshot(
        selected,
      );
    }

    setState(() {});
  }

  void _moveUpdate(
    int index,
    DragUpdateDetails details,
  ) {
    if (_dragSnapshots
        .isEmpty) {
      return;
    }

    final requestedDelta =
        _pxToMs(
      details
              .globalPosition
              .dx -
          _dragStartX,
    );

    var minimumDelta =
        -0x3FFFFFFF;

    var maximumDelta =
        0x3FFFFFFF;

    final moving =
        _dragSnapshots.keys
            .toSet();

    for (final entry
        in _dragSnapshots
            .entries) {
      final currentIndex =
          entry.key;

      final snapshot =
          entry.value;

      //
      // Timeline bounds.
      //
      minimumDelta =
          math.max(
        minimumDelta,
        -snapshot.startMs,
      );

      maximumDelta =
          math.min(
        maximumDelta,
        _durationMs -
            snapshot.endMs,
      );

      //
      // Previous clip that is NOT part of the group.
      //
      final previousIndex =
          currentIndex -
              1;

      if (previousIndex >=
              0 &&
          !moving.contains(
            previousIndex,
          )) {
        minimumDelta =
            math.max(
          minimumDelta,
          _lines[previousIndex]
                  .endMs -
              snapshot
                  .startMs,
        );
      }

      //
      // Next clip that is NOT part of the group.
      //
      final nextIndex =
          currentIndex +
              1;

      if (nextIndex <
              _lines.length &&
          !moving.contains(
            nextIndex,
          )) {
        maximumDelta =
            math.min(
          maximumDelta,
          _lines[nextIndex]
                  .startMs -
              snapshot
                  .endMs,
        );
      }
    }

    final delta =
        requestedDelta
            .clamp(
              minimumDelta,
              maximumDelta,
            )
            .toInt();

    setState(() {
      for (final entry
          in _dragSnapshots
              .entries) {
        final selectedIndex =
            entry.key;

        final snapshot =
            entry.value;

        final line =
            _lines[
                selectedIndex];

        line.startMs =
            snapshot.startMs +
                delta;

        line.endMs =
            snapshot.endMs +
                delta;

        for (final wordSnapshot
            in snapshot.words) {
          if (wordSnapshot
                  .startMs !=
              null) {
            wordSnapshot
                    .word[
                'startMs'] =
                wordSnapshot
                        .startMs! +
                    delta;
          }

          if (wordSnapshot
                  .endMs !=
              null) {
            wordSnapshot
                    .word[
                'endMs'] =
                wordSnapshot
                        .endMs! +
                    delta;
          }
        }
      }

      _dirty =
          true;
    });
  }

  void _moveEnd() {
    _dragSnapshots
        .clear();
  }

  void _resizeLeft(
    int index,
    DragUpdateDetails details,
  ) {
    final line =
        _lines[index];

    final min =
        index >
                0
            ? _lines[index - 1]
                .endMs
            : 0;

    final max =
        line.endMs -
            _minClipMs;

    final value =
        (line.startMs +
                _pxToMs(
                  details
                      .delta
                      .dx,
                ))
            .clamp(
              min,
              max,
            )
            .toInt();

    setState(() {
      //
      // Resize always becomes a single-clip operation.
      //
      _selectedIndices
        ..clear()
        ..add(
          index,
        );

      _selectedIndex =
          index;

      line.startMs =
          value;

      _dirty =
          true;
    });
  }

  void _resizeRight(
    int index,
    DragUpdateDetails details,
  ) {
    final line =
        _lines[index];

    final min =
        line.startMs +
            _minClipMs;

    final max =
        index <
                _lines.length -
                    1
            ? _lines[index + 1]
                .startMs
            : _durationMs;

    final value =
        (line.endMs +
                _pxToMs(
                  details
                      .delta
                      .dx,
                ))
            .clamp(
              min,
              max,
            )
            .toInt();

    setState(() {
      _selectedIndices
        ..clear()
        ..add(
          index,
        );

      _selectedIndex =
          index;

      line.endMs =
          value;

      _dirty =
          true;
    });
  }

  void _addInstrumental() {
    final index =
        _selectedIndex;

    if (index ==
        null) {
      return;
    }

    final line =
        _lines[index];

    final next =
        index <
                _lines.length -
                    1
            ? _lines[index + 1]
                .startMs
            : _durationMs;

    if (next -
            line.endMs <
        _minClipMs) {
      _message(
        'Create a visible gap first.',
      );

      return;
    }

    setState(() {
      _lines.insert(
        index +
            1,
        TimelineLyricLine(
          data: {
            'text':
                '♪',

            'startMs':
                line.endMs,

            'endMs':
                next,

            'originalStartMs':
                line.endMs,

            'originalEndMs':
                next,

            'words':
                <dynamic>[],

            'manualLine':
                true,

            'lineType':
                'instrumental',
          },
        ),
      );

      _selectedIndex =
          index +
              1;

      _selectedIndices
        ..clear()
        ..add(
          index +
              1,
        );

      _dirty =
          true;
    });
  }

  Future<void> _editText()
      async {
    final index =
        _selectedIndex;

    if (index ==
        null) {
      return;
    }

    final line =
        _lines[index];

    final controller =
        TextEditingController(
      text:
          line.text,
    );

    final result =
        await showDialog<String>(
      context:
          context,

      builder:
          (
        context,
      ) =>
              AlertDialog(
        title:
            const Text(
          'Edit lyric',
        ),

        content:
            TextField(
          controller:
              controller,

          autofocus:
              true,

          maxLines:
              4,
        ),

        actions: [
          TextButton(
            onPressed:
                () =>
                    Navigator.pop(
              context,
            ),

            child:
                const Text(
              'CANCEL',
            ),
          ),

          FilledButton(
            onPressed:
                () =>
                    Navigator.pop(
              context,

              controller.text
                  .trim(),
            ),

            child:
                const Text(
              'SAVE',
            ),
          ),
        ],
      ),
    );

    controller.dispose();

    if (result ==
            null ||
        result.isEmpty ||
        result ==
            line.text) {
      return;
    }

    setState(() {
      line.text =
          result;

      if (!line
          .isInstrumental) {
        line.data['words'] =
            <dynamic>[];
      }

      _dirty =
          true;
    });
  }

  void _deleteSelected() {
    final index =
        _selectedIndex;

    if (index ==
        null) {
      return;
    }

    setState(() {
      _lines.removeAt(
        index,
      );

      _selectedIndex =
          null;

      _selectedIndices
          .clear();

      _dirty =
          true;
    });
  }

  Future<void> _save()
      async {
    if (_json ==
            null ||
        _saving) {
      return;
    }

    setState(() {
      _saving =
          true;
    });

    try {
      _sortLines();

      final output =
          Map<String, dynamic>.from(
        _json!,
      );

      output['lines'] =
          _lines
              .map(
                (line) =>
                    line.data,
              )
              .toList();

      output['durationMs'] =
          _durationMs;

      // Commit to Windows first. If authorization/version fails, keep the
      // editor dirty and do not incorrectly report a successful save.
      if (_server.enabled) {
        if (_serverSongId == null || _serverVersion == null) {
          throw StateError('No se ha cargado la versión del servidor.');
        }
        _serverVersion = await _server.saveLyrics(
          _serverSongId!, _serverVersion!, output,
        );
      }

      await File(_editableJsonPath ?? widget.jsonPath).writeAsString(
        const JsonEncoder
            .withIndent(
          '  ',
        ).convert(
          output,
        ),

        encoding:
            utf8,

        flush:
            true,
      );

      final txtPath = (_editableJsonPath ?? widget.jsonPath)
              .replaceFirst(
        RegExp(
          r'\.json$',
          caseSensitive:
              false,
        ),
        '.txt',
      );

      await File(
        txtPath,
      ).writeAsString(
        '${_lines.map((line) => line.text).join('\n')}\n',

        encoding:
            utf8,

        flush:
            true,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _saving =
            false;

        _dirty =
            false;

        _json =
            output;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _saving =
            false;

        _error =
            e.toString();
      });
    }
  }

  KeyEventResult _keyboard(
    FocusNode node,
    KeyEvent event,
  ) {
    if (event
        is! KeyDownEvent) {
      return KeyEventResult
          .ignored;
    }

    if (event.logicalKey ==
        LogicalKeyboardKey
            .space) {
      _togglePlay();

      return KeyEventResult
          .handled;
    }

    if (event.logicalKey ==
        LogicalKeyboardKey
            .arrowLeft) {
      _skip(
        -1000,
      );

      return KeyEventResult
          .handled;
    }

    if (event.logicalKey ==
        LogicalKeyboardKey
            .arrowRight) {
      _skip(
        1000,
      );

      return KeyEventResult
          .handled;
    }

    return KeyEventResult
        .ignored;
  }

  void _message(
    String text,
  ) {
    ScaffoldMessenger.of(
      context,
    )
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content:
              Text(
            text,
          ),
        ),
      );
  }

  @override
  void dispose() {
    if (_playheadTicker
        .isActive) {
      _playheadTicker
          .stop();
    }

    _playheadTicker
        .dispose();

    _playheadClock
        .stop();

    _player
        .dispose();

    _scrollController
        .dispose();

    _focusNode
        .dispose();

    _playhead
        .dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Theme(
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF090A0F),
      ),
      child: Focus(
      focusNode:
          _focusNode,

      autofocus:
          true,

      onKeyEvent:
          _keyboard,

      child:
          Scaffold(
        backgroundColor:
            const Color(
          0xFF090A0F,
        ),

        appBar:
            AppBar(
          backgroundColor:
              const Color(
            0xFF090A0F,
          ),

          title:
              const Text(
            'Lyrics Timeline',
          ),

          actions: [
            FilledButton.icon(
              onPressed:
                  !_dirty ||
                          _saving
                      ? null
                      : _save,

              icon:
                  const Icon(
                Icons.save_rounded,
              ),

              label:
                  const Text(
                'SAVE',
              ),
            ),

            const SizedBox(
              width:
                  12,
            ),
          ],
        ),

        body:
            _loading
                ? const Center(
                    child:
                        CircularProgressIndicator(),
                  )
                : _buildBody(),
      ),
    ),
    );
  }

  Widget _buildBody() {
    final isMobile = MediaQuery.sizeOf(context).width < 640;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          children: [
            _header(),
            _toolbar(),
            Expanded(child: _timeline()),
            _inspector(),
            if (isMobile)
              _mobileTransport()
            else
              TimelineTransport(
                playing: _playing,
                durationMs: _durationMs,
                position: _playhead,
                volume: _volume,
                onVolumeChanged: _setVolume,
                onPlayPause: _togglePlay,
                onBackFive: () => _skip(-5000),
                onForwardFive: () => _skip(5000),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
          ],
        ),
        if (isMobile && _volumeSliderVisible) ...[
          // Invisible touch layer: dismiss on any tap outside the popup.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _volumeSliderVisible = false),
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: 13,
            bottom: _error == null ? 94 : 126,
            child: _floatingVolumeSlider(),
          ),
        ],
      ],
    );
  }

  Widget _floatingVolumeSlider() {
    return Material(
      color: const Color(0xFF222534),
      elevation: 10,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 52,
        height: 218,
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFF45415C), width: 1),
        ),
        child: Column(
          children: [
            const Icon(Icons.volume_up_rounded, size: 17, color: Color(0xFFD3BAFF)),
            Expanded(
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: const Color(0xFFD3BAFF),
                    inactiveTrackColor: const Color(0xFF555469),
                    thumbColor: const Color(0xFFD3BAFF),
                  ),
                  child: Slider(
                    value: _volume.clamp(0.0, 1.0),
                    onChanged: _setVolume,
                  ),
                ),
              ),
            ),
            Text(
              '${(_volume * 100).round()}%',
              style: const TextStyle(fontSize: 10, color: Color(0xFFD3BAFF)),
            ),
          ],
        ),
      ),
    );
  }

  String _clockLabel(int ms) {
    final safe = ms < 0 ? 0 : ms;
    final minutes = safe ~/ 60000;
    final seconds = (safe ~/ 1000) % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _mobileTransport() {
    return Container(
      height: 98,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF11131A),
        border: Border(top: BorderSide(color: Color(0xFF282B34))),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: 'Volume',
              icon: Icon(_volume == 0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded),
              onPressed: () => setState(
                () => _volumeSliderVisible = !_volumeSliderVisible,
              ),
              iconSize: 26,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Back 5 seconds',
                icon: const Icon(Icons.replay_5_rounded),
                onPressed: () => _skip(-5000),
                iconSize: 34,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 54),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: _playing ? 'Pause' : 'Play',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF31536B),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(66, 66),
                ),
                icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                iconSize: 38,
                onPressed: _togglePlay,
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Forward 5 seconds',
                icon: const Icon(Icons.forward_5_rounded),
                onPressed: () => _skip(5000),
                iconSize: 34,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 54),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: ValueListenableBuilder<int>(
              valueListenable: _playhead,
              builder: (context, milliseconds, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _clockLabel(milliseconds),
                    maxLines: 1,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    _clockLabel(_durationMs),
                    maxLines: 1,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      color:
          const Color(
        0xFF11131A,
      ),

      padding:
          const EdgeInsets.all(
        16,
      ),

      child:
          Row(
        children: [
          Expanded(
            child:
                Column(
              crossAxisAlignment:
                  CrossAxisAlignment
                      .start,

              children: [
                Text(
                  _title,

                  style:
                      const TextStyle(
                    color: Color(0xFFFFFFFF),
                    fontSize:
                        22,

                    fontWeight:
                        FontWeight
                            .bold,
                  ),
                ),

                Text(
                  _artist,

                  style:
                      const TextStyle(
                    color:
                        Color(0xFFADB4C4),
                  ),
                ),
              ],
            ),
          ),

        ],
      ),
    );
  }

  Widget _toolbar() {
    final mobile = MediaQuery.sizeOf(context).width < 600;
    if (mobile) {
      return Container(
        color: const Color(0xFF161924),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          IconButton(tooltip: 'Zoom out', onPressed: () => _zoom(140, 1 / 1.25), icon: const Icon(Icons.remove)),
          Text('${_pixelsPerSecond.round()} px/s', style: const TextStyle(fontSize: 12)),
          IconButton(tooltip: 'Zoom in', onPressed: () => _zoom(140, 1.25), icon: const Icon(Icons.add)),
          const Spacer(),
          IconButton(tooltip: 'Add instrumental segment', onPressed: _selectedIndex == null ? null : _addInstrumental, icon: const Icon(Icons.music_note_rounded)),
          IconButton(tooltip: 'Edit text', onPressed: _selectedIndex == null ? null : _editText, icon: const Icon(Icons.edit_rounded)),
          IconButton(tooltip: 'Delete segment', onPressed: _selectedIndex == null ? null : _deleteSelected, icon: const Icon(Icons.delete_outline)),
        ]),
      );
    }
    return _desktopToolbar();
  }

  Widget _desktopToolbar() {

    return Container(
      color:
          const Color(
        0xFF161924,
      ),

      padding:
          const EdgeInsets.symmetric(
        horizontal:
            16,

        vertical:
            8,
      ),

      child:
          Row(
        children: [
          IconButton(
            tooltip:
                'Zoom out',

            onPressed:
                () =>
                    _zoom(
              450,
              1 /
                  1.25,
            ),

            icon:
                const Icon(
              Icons.remove,
            ),
          ),

          SizedBox(
            width:
                80,

            child:
                Center(
              child:
                  Text(
                '${_pixelsPerSecond.round()} px/s',
              ),
            ),
          ),

          IconButton(
            tooltip:
                'Zoom in',

            onPressed:
                () =>
                    _zoom(
              450,
              1.25,
            ),

            icon:
                const Icon(
              Icons.add,
            ),
          ),

          const SizedBox(
            width:
                10,
          ),

          const Text(
            'Ctrl + Wheel = Zoom',

            style:
                TextStyle(
              color:
                  Colors.white38,

              fontSize:
                  11,
            ),
          ),

          const Spacer(),

          if (_selectedIndices
                  .length >
              1)
            Padding(
              padding:
                  const EdgeInsets.only(
                right:
                    12,
              ),

              child:
                  Text(
                '${_selectedIndices.length} selected',

                style:
                    const TextStyle(
                  color:
                      Color(
                    0xFFC4B4FF,
                  ),

                  fontSize:
                      12,

                  fontWeight:
                      FontWeight
                          .w700,
                ),
              ),
            ),

          OutlinedButton.icon(
            onPressed:
                _selectedIndex ==
                        null
                    ? null
                    : _addInstrumental,

            icon:
                const Icon(
              Icons
                  .music_note_rounded,

              size:
                  17,
            ),

            label:
                const Text(
              'ADD ♪ AFTER',
            ),
          ),

          const SizedBox(
            width:
                8,
          ),

          OutlinedButton.icon(
            onPressed:
                _selectedIndex ==
                        null
                    ? null
                    : _editText,

            icon:
                const Icon(
              Icons.edit_rounded,

              size:
                  17,
            ),

            label:
                const Text(
              'TEXT',
            ),
          ),

          IconButton(
            tooltip:
                'Delete selected segment',

            onPressed:
                _selectedIndex ==
                        null
                    ? null
                    : _deleteSelected,

            icon:
                const Icon(
              Icons
                  .delete_outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeline() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fit the lyrics lane to the actual height of the editor viewport.
        // Previously the three fixed-height lanes could exceed it by ~25 px.
        final lyricsTrackHeight = constraints.hasBoundedHeight
            ? math.max(0.0,
                constraints.maxHeight - _rulerHeight - _audioHeight)
            : _lyricsHeight;
        return Row(
      children: [
        SizedBox(
          width:
              _labelWidth,

          child:
              Column(
            children: [
              SizedBox(
                height:
                    _rulerHeight,
              ),

              Container(
                height:
                    _audioHeight,

                color:
                    const Color(
                  0xFF111722,
                ),

                alignment:
                    Alignment.center,

                child:
                    const Column(
                  mainAxisAlignment:
                      MainAxisAlignment
                          .center,

                  children: [
                    Icon(
                      Icons
                          .graphic_eq_rounded,

                      color:
                          Color(
                        0xFF698AB6,
                      ),
                    ),

                    SizedBox(
                      height:
                          3,
                    ),

                    Text(
                      'AUDIO',

                      style:
                          TextStyle(
                        color:
                            Color(
                          0xFF8295B5,
                        ),

                        fontSize:
                            11,
                      ),
                    ),
                  ],
                ),
              ),

              Container(
                height: lyricsTrackHeight,

                color:
                    const Color(
                  0xFF15131D,
                ),

                alignment:
                    Alignment.center,

                child:
                    const Column(
                  mainAxisAlignment:
                      MainAxisAlignment
                          .center,

                  children: [
                    Icon(
                      Icons
                          .subtitles_rounded,

                      color:
                          Color(
                        0xFF9D8AC4,
                      ),
                    ),

                    SizedBox(
                      height:
                          3,
                    ),

                    Text(
                      'LYRICS',

                      style:
                          TextStyle(
                        color:
                            Color(
                          0xFFAFA0CC,
                        ),

                        fontSize:
                            11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child:
              Listener(
            key: _timelineAreaKey,
            onPointerSignal: _wheel,
            onPointerDown: _trackTouchDown,
            onPointerMove: _trackTouchMove,
            onPointerUp: _trackTouchEnd,
            onPointerCancel: _trackTouchEnd,

            child:
                Scrollbar(
              controller:
                  _scrollController,

              thumbVisibility:
                  true,

              child:
                  SingleChildScrollView(
                controller:
                    _scrollController,

                scrollDirection:
                    Axis.horizontal,
                physics: (_pinchActive || _marqueeSelecting)
                    ? const NeverScrollableScrollPhysics()
                    : null,

                child:
                    SizedBox(
                  width:
                      _timelineWidth,

                  child:
                      Column(
                    children: [
                      TimelineRuler(
                        width:
                            _timelineWidth,

                        height:
                            _rulerHeight,

                        pixelsPerSecond:
                            _pixelsPerSecond,

                        durationMs:
                            _durationMs,

                        onSeekX:
                            (
                          x,
                        ) =>
                                _seek(
                          _pxToMs(
                            x,
                          ),
                        ),
                      ),

                      WaveformTrack(
                        width:
                            _timelineWidth,

                        height:
                            _audioHeight,

                        waveform:
                            _waveform,

                        loading:
                            _waveformLoading,

                        playhead:
                            _playhead,

                        pixelsPerSecond:
                            _pixelsPerSecond,

                        onSeekX:
                            (
                          x,
                        ) =>
                                _seek(
                          _pxToMs(
                            x,
                          ),
                        ),

                        onScrubX:
                            (
                          x,
                        ) =>
                                _seek(
                          _pxToMs(
                            x,
                          ),
                        ),

                        onScrubStart:
                            () {
                          _scrubbing =
                              true;
                        },

                        onScrubEnd:
                            () {
                          _scrubbing =
                              false;

                          if (_playing) {
                            _setPlayheadReference(
                              _player
                                  .position
                                  .inMilliseconds,

                              updateVisual:
                                  true,
                            );
                          }
                        },
                      ),

                      LyricsTrack(
                        width:
                            _timelineWidth,

                        height:
                            lyricsTrackHeight,

                        pixelsPerSecond:
                            _pixelsPerSecond,

                        lines:
                            _lines,

                        selectedIndices:
                            _selectedIndices,

                        hoveredIndex:
                            _hoveredIndex,

                        playhead:
                            _playhead,

                        onSelect:
                            _selectSingle,

                        onSelectionChanged:
                            _selectGroup,

                        onClearSelection:
                            _clearSelection,

                        onMarqueeStateChanged:
                            _onMarqueeStateChanged,

                        onHover:
                            (
                          index,
                        ) {
                          setState(() {
                            _hoveredIndex =
                                index;
                          });
                        },

                        onExitHover:
                            () {
                          setState(() {
                            _hoveredIndex =
                                null;
                          });
                        },

                        onMoveStart:
                            _moveStart,

                        onMoveUpdate:
                            _moveUpdate,

                        onMoveEnd:
                            _moveEnd,

                        onResizeLeft:
                            _resizeLeft,

                        onResizeRight:
                            _resizeRight,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
        );
      },
    );
  }

  Widget _inspector() {
    if (MediaQuery.sizeOf(context).width < 600) {
      final index = _selectedIndex;
      if (index == null || index >= _lines.length) {
        return Container(
          height: 48, color: const Color(0xFF11131A), alignment: Alignment.center,
          child: const Text('Select a lyric segment', style: TextStyle(color: Color(0xFFB2B9C8))),
        );
      }
      final line = _lines[index];
      return Container(
        color: const Color(0xFF11131A),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(line.text, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text('START ${line.startMs} ms    END ${line.endMs} ms    ORIGINAL ${line.originalStartMs} ms',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFADB4C4), fontSize: 11)),
        ]),
      );
    }
    return _desktopInspector();
  }

  Widget _desktopInspector() {

    final index =
        _selectedIndex;

    if (index ==
            null ||
        index >=
            _lines.length) {
      return Container(
        height:
            70,

        color:
            const Color(
          0xFF161924,
        ),

        alignment:
            Alignment.center,

        child:
            const Text(
          'Select a lyric segment',

          style:
              TextStyle(
            color:
                Colors.white38,
          ),
        ),
      );
    }

    final line =
        _lines[index];

    return Container(
      height:
          76,

      color:
          const Color(
        0xFF161924,
      ),

      padding:
          const EdgeInsets.symmetric(
        horizontal:
            20,
      ),

      child:
          Row(
        children: [
          Expanded(
            child:
                Row(
              children: [
                if (_selectedIndices
                        .length >
                    1)
                  Container(
                    margin:
                        const EdgeInsets.only(
                      right:
                          10,
                    ),

                    padding:
                        const EdgeInsets.symmetric(
                      horizontal:
                          8,

                      vertical:
                          4,
                    ),

                    decoration:
                        BoxDecoration(
                      color:
                          const Color(
                            0xFF4B3F72,
                          ),

                      borderRadius:
                          BorderRadius.circular(
                        8,
                      ),
                    ),

                    child:
                        Text(
                      '${_selectedIndices.length} clips',

                      style:
                          const TextStyle(
                        color:
                            Color(
                          0xFFE0D7FF,
                        ),

                        fontSize:
                            11,

                        fontWeight:
                            FontWeight
                                .w700,
                      ),
                    ),
                  ),

                Expanded(
                  child:
                      Text(
                    line.text,

                    maxLines:
                        2,

                    overflow:
                        TextOverflow
                            .ellipsis,

                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight
                              .w700,
                    ),
                  ),
                ),
              ],
            ),
          ),

          _InspectorValue(
            title:
                'START',

            value:
                '${line.startMs} ms',
          ),

          const SizedBox(
            width:
                20,
          ),

          _InspectorValue(
            title:
                'END',

            value:
                '${line.endMs} ms',
          ),

          const SizedBox(
            width:
                20,
          ),

          _InspectorValue(
            title:
                'CTC',

            value:
                '${line.originalStartMs} ms',
          ),
        ],
      ),
    );
  }
}

class _DragLineSnapshot {
  final int startMs;

  final int endMs;

  final List<_WordTimingSnapshot>
      words;

  const _DragLineSnapshot({
    required this.startMs,
    required this.endMs,
    required this.words,
  });
}

class _WordTimingSnapshot {
  final Map<dynamic, dynamic>
      word;

  final int? startMs;

  final int? endMs;

  const _WordTimingSnapshot({
    required this.word,
    required this.startMs,
    required this.endMs,
  });
}

class _InspectorValue
    extends StatelessWidget {
  final String title;

  final String value;

  const _InspectorValue({
    required this.title,
    required this.value,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return Column(
      mainAxisAlignment:
          MainAxisAlignment.center,

      crossAxisAlignment:
          CrossAxisAlignment.start,

      children: [
        Text(
          title,

          style:
              const TextStyle(
            color:
                Colors.white38,

            fontSize:
                10,

            fontWeight:
                FontWeight.w700,
          ),
        ),

        const SizedBox(
          height:
              2,
        ),

        Text(
          value,

          style:
              const TextStyle(
            fontSize:
                13,

            fontWeight:
                FontWeight.w600,
          ),
        ),
      ],
    );
  }
}