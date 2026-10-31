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
import '../services/lyric_sweep_curve.dart';
import '../widgets/lyrics_timeline/sweep_automation_editor.dart';
import '../services/waveform_cache_service.dart';
import '../services/lyriko_server_client.dart';
import '../widgets/lyrics_timeline/lyrics_track.dart';
import '../widgets/lyrics_timeline/word_timing_track.dart';
import '../widgets/lyrics_timeline/timeline_ruler.dart';
import '../widgets/lyrics_timeline/timeline_transport.dart';
import '../widgets/lyrics_timeline/waveform_track.dart';

class LyricsEditScreen extends StatefulWidget {
  final String jsonPath;
  /// Called only after the edited JSON has been saved successfully.
  final Future<void> Function()? onLyricsSaved;

  const LyricsEditScreen({
    super.key,
    required this.jsonPath,
    this.onLyricsSaved,
  });

  @override
  State<LyricsEditScreen> createState() => _LyricsEditScreenState();
}

class _LyricsEditScreenState extends State<LyricsEditScreen>
    with SingleTickerProviderStateMixin {
  static const double _rulerHeight = 46;

  static const double _audioHeight = 184;

  static const double _lyricsHeight = 124;

  static const double _labelWidth = 92;

  bool get _compactIosTimeline => Platform.isIOS;


  static const int _minClipMs = 300;

  final AudioPlayer _player = AudioPlayer();

  final WaveformCacheService _waveformService = WaveformCacheService();

  final ScrollController _scrollController = ScrollController();

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

  final FocusNode _focusNode = FocusNode();

  final ValueNotifier<int> _playhead = ValueNotifier<int>(0);

  late final Ticker _playheadTicker;

  final Stopwatch _playheadClock = Stopwatch();

  int _playheadAnchorMs = 0;

  bool _seekInProgress = false;

  final SyncedLyricsService _lyricsStorage = SyncedLyricsService();
  final LyrikoServerClient _server = LyrikoServerClient();
  String? _serverSongId;
  int? _serverVersion;
  bool _remoteEditing = false;
  String? _editableJsonPath;
  Map<String, dynamic>? _json;

  final List<TimelineLyricLine> _lines = [];

  // Desktop-only word timing editor. All coordinates are song-absolute ms.
  static const double _wordsHeight = 78;
  bool _showWords = true;
  bool _showCurveLane = true;

  int? _selectedWordLine;
  int? _selectedWordIndex;
  static const int _wordMinimumMs = 40;

  List<Map<String, dynamic>> _editableWords(TimelineLyricLine line) {
    final source = line.data['words'];
    if (source is! List) return [];
    return source.whereType<Map>().map((w) => Map<String, dynamic>.from(w)).toList();
  }

  // Coarse alignment for newly imported or replaced lyrics. This uses the
  // waveform amplitude envelope (not speech recognition): it cannot identify
  // individual sung words or distinguish vocals from instruments.
  // Existing synchronized lines are NEVER overwritten automatically.
  bool get _hasApproximateAlignmentInput =>
      Platform.isMacOS && _durationMs > 0 && _lines.isNotEmpty;

  void _autoAlignApproximate({bool replaceExisting = false}) {
    if (!_hasApproximateAlignmentInput) return;
    final candidates = _lines.where((line) =>
        line.text.trim().isNotEmpty &&
        line.data['lineType'] != 'instrumental' &&
        line.text.trim() != '♪').toList();
    if (candidates.isEmpty) return;

    // For existing tracks, preserve manually edited/synchronized segments.
    // Explicit re-alignment is separately confirmed by the caller.
    if (!replaceExisting && candidates.any((line) =>
        line.data['manualLine'] != true &&
        line.data['approximateAlignment'] != true &&
        (line.originalStartMs > 0 || line.originalEndMs > 0))) return;

    final n = candidates.length;
    final duration = _durationMs;
    final minSegment = 160;
    if (duration < n * minSegment) {
      _message('Song too short for this number of lyric lines.');
      return;
    }
    // Character counts give an initial relative allocation. Pauses in the
    // waveform then attract nearby boundaries, but only within a small window
    // to avoid shifting entire verses to unrelated instrumental passages.
    final weights = candidates.map((line) =>
        math.sqrt(math.max(4, line.text.trim().length).toDouble())).toList();
    final totalWeight = weights.fold<double>(0, (sum, value) => sum + value);
    final envelope = _waveform.map((value) => value.abs()).toList();
    final hasEnvelope = envelope.length >= 100;
    final startOffset = hasEnvelope ? math.min(duration ~/ 12, 12000) : 0;
    final usableDuration = duration - startOffset;
    final boundaries = <int>[startOffset];
    var cumulative = 0.0;
    for (var i = 0; i < n - 1; i++) {
      cumulative += weights[i];
      final expected = startOffset + (usableDuration * cumulative / totalWeight).round();
      var best = expected;
      if (hasEnvelope) {
        final window = math.min(1400, math.max(250, duration ~/ (n * 8)));
        var bestEnergy = double.infinity;
        for (var t = math.max(boundaries.last + minSegment, expected - window);
             t <= math.min(duration - (n - i - 1) * minSegment, expected + window);
             t += 50) {
          final index = ((t / duration) * (envelope.length - 1)).round()
              .clamp(0, envelope.length - 1).toInt();
          final from = math.max(0, index - 2);
          final to = math.min(envelope.length - 1, index + 2);
          var energy = 0.0;
          for (var k = from; k <= to; k++) { energy += envelope[k]; }
          energy /= (to - from + 1);
          final penalty = ((t - expected).abs() / window) * 0.08;
          if (energy + penalty < bestEnergy) {
            bestEnergy = energy + penalty;
            best = t;
          }
        }
      }
      final latest = duration - (n - i - 1) * minSegment;
      boundaries.add(best.clamp(boundaries.last + minSegment, latest).toInt());
    }
    boundaries.add(duration);
    setState(() {
      for (var i = 0; i < n; i++) {
        final line = candidates[i];
        line.data['startMs'] = boundaries[i];
        line.data['endMs'] = boundaries[i + 1];
        line.data['originalStartMs'] = boundaries[i];
        line.data['originalEndMs'] = boundaries[i + 1];
        line.data['words'] = <dynamic>[];
        line.data['wordsEdited'] = false;
        line.data['approximateAlignment'] = true;
        line.data['manualLine'] = true;
      }
      _selectedIndex = null;
      _selectedIndices.clear();
      _dirty = true;
    });
    _generateWordTimings();
    _message('Approximate timing generated from ${hasEnvelope ? 'waveform pauses' : 'phrase lengths'}. Review by ear before SAVE.');
  }

  Future<void> _confirmAutoAlign() async {
    if (!_hasApproximateAlignmentInput) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Auto Align — approximate'),
        content: const Text('Recalculate phrase and word times using approximate spacing and waveform pauses. Existing timing edits will be replaced in memory. Nothing is saved until SAVE. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('ALIGN')),
        ],
      ),
    );
    if (mounted && approved == true) _autoAlignApproximate(replaceExisting: true);
  }

  void _generateWordTimings() {
    var count = 0;
    setState(() {
      for (final line in _lines) {
        if (line.data['lineType'] == 'instrumental' || line.text.trim() == '♪') continue;
        // Preserve existing word edits and recognized word timings.
        final existing = line.data['words'];
        if (existing is List && existing.isNotEmpty) continue;
        final tokens = RegExp(r"\S+").allMatches(line.text).map((m) => m.group(0)!).toList();
        if (tokens.isEmpty) continue;
        final duration = math.max(1, line.endMs - line.startMs);
        final weights = tokens.map((t) => math.max(1, t.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').length)).toList();
        final total = weights.fold<int>(0, (a, b) => a + b);
        var cumulative = 0;
        final words = <Map<String, dynamic>>[];
        for (var i = 0; i < tokens.length; i++) {
          final start = line.startMs + (duration * cumulative / total).round();
          cumulative += weights[i];
          final end = i == tokens.length - 1 ? line.endMs : line.startMs + (duration * cumulative / total).round();
          words.add({'text': tokens[i], 'startMs': start, 'endMs': math.max(start + 1, end)});
          count++;
        }
        line.data['words'] = words;
        line.data['wordsEdited'] = true;
        _dirty = true;
      }
    });
    _message(count == 0 ? 'All phrases already have word timings.' : '$count approximate word segments created. Adjust them by ear before saving.');
  }

  void _updateWord(int lineIndex, int wordIndex, int deltaMs, String operation) {
    if (lineIndex < 0 || lineIndex >= _lines.length) return;
    final line = _lines[lineIndex];
    final words = _editableWords(line);
    if (wordIndex < 0 || wordIndex >= words.length) return;
    // First manual edit converts recognized CTC timestamps to current line time.
    if (line.data['wordsEdited'] != true) {
      final originalDuration = line.originalEndMs - line.originalStartMs;
      for (final word in words) {
        final s = (word['startMs'] as num?)?.toInt() ?? line.startMs;
        final e = (word['endMs'] as num?)?.toInt() ?? line.endMs;
        int transform(int value) => originalDuration <= 0
          ? line.startMs + value - line.originalStartMs
          : line.startMs + ((value - line.originalStartMs) * line.durationMs / originalDuration).round();
        word['startMs'] = transform(s).clamp(line.startMs, line.endMs).toInt();
        word['endMs'] = transform(e).clamp(line.startMs, line.endMs).toInt();
      }
    }
    final word = words[wordIndex];
    final start = (word['startMs'] as num).toInt();
    final end = (word['endMs'] as num).toInt();
    // Word handles may be edited independently, but NEVER leave the
    // enclosing LYRICS segment or overlap neighboring words.
    final before = wordIndex == 0
        ? line.startMs
        : math.max(line.startMs,
            (words[wordIndex - 1]['endMs'] as num).toInt());
    final after = wordIndex == words.length - 1
        ? line.endMs
        : math.min(line.endMs,
            (words[wordIndex + 1]['startMs'] as num).toInt());
    final available = math.max(0, after - before);
    final minimum = math.min(_wordMinimumMs, available);
    if (operation == 'move') {
      final minDelta = before - start;
      final maxDelta = after - end;
      final shift = minDelta <= maxDelta
          ? deltaMs.clamp(minDelta, maxDelta).toInt()
          : 0;
      word['startMs'] = start + shift;
      word['endMs'] = end + shift;
    } else if (operation == 'start') {
      final upper = math.max(before, end - minimum);
      word['startMs'] = (start + deltaMs).clamp(before, upper).toInt();
    } else if (operation == 'end') {
      final lower = math.min(after, start + minimum);
      word['endMs'] = (end + deltaMs).clamp(lower, after).toInt();
    }
    setState(() {
      line.data['words'] = words;
      line.data['wordsEdited'] = true;
      _selectedWordLine = lineIndex;
      _selectedWordIndex = wordIndex;
      _dirty = true;
    });
  }


  List<double> _waveform = [];

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

  final Set<int> _selectedIndices = <int>{};
  List<Map<String, dynamic>> _copiedPhrases = [];

  Map<String, dynamic> _clonePhrase(Map<String, dynamic> data) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map);

  void _copyPhrases() {
    if (!Platform.isMacOS || _selectedIndices.isEmpty) return;
    final indices = _selectedIndices.toList()..sort();
    _copiedPhrases = indices.map((i) => _clonePhrase(_lines[i].data)).toList();
    _message('Copied ${_copiedPhrases.length} complete phrases.');
  }

  void _pastePhrases() {
    if (!Platform.isMacOS || _copiedPhrases.isEmpty) return;
    final originals = _copiedPhrases.toList()
      ..sort((a, b) => (a['startMs'] as num).compareTo(b['startMs'] as num));
    final base = (originals.first['startMs'] as num).toInt();
    final last = originals.map((v) => (v['endMs'] as num).toInt()).reduce(math.max);
    final span = last - base;
    if (span <= 0) return;
    var target = _playhead.value;
    final occupied = _lines.toList()..sort((a, b) => a.startMs.compareTo(b.startMs));
    for (final line in occupied) {
      if (line.endMs <= target) continue;
      if (line.startMs >= target + span) break;
      target = line.endMs;
    }
    if (target + span > _durationMs) {
      _message('No gap large enough after playhead. Move playhead to another gap.');
      return;
    }
    final shift = target - base;
    final copies = <TimelineLyricLine>[];
    for (final original in originals) {
      final data = _clonePhrase(original);
      final oldStart = (original['startMs'] as num).toInt();
      final oldEnd = (original['endMs'] as num).toInt();
      data['startMs'] = oldStart + shift;
      data['endMs'] = oldEnd + shift;
      data['originalStartMs'] = oldStart + shift;
      data['originalEndMs'] = oldEnd + shift;
      final originalStart = (original['originalStartMs'] as num?)?.toInt() ?? oldStart;
      final originalEnd = (original['originalEndMs'] as num?)?.toInt() ?? oldEnd;
      final originalSpan = math.max(1, originalEnd - originalStart);
      final edited = original['wordsEdited'] == true;
      final words = data['words'];
      if (words is List) {
        for (final word in words) {
          if (word is! Map) continue;
          int translate(int ms) => edited ? ms + shift :
              oldStart + shift + ((ms - originalStart) * (oldEnd - oldStart) / originalSpan).round();
          if (word['startMs'] is num) word['startMs'] = translate((word['startMs'] as num).toInt());
          if (word['endMs'] is num) word['endMs'] = translate((word['endMs'] as num).toInt());
        }
        data['wordsEdited'] = true;
      }
      copies.add(TimelineLyricLine(data: data));
    }
    setState(() {
      _lines.addAll(copies);
      _sortLines();
      _selectedIndices.clear();
      for (var i = 0; i < _lines.length; i++) {
        if (copies.contains(_lines[i])) _selectedIndices.add(i);
      }
      _selectedIndex = _selectedIndices.isEmpty ? null : _selectedIndices.first;
      _dirty = true;
    });
  }

  Future<void> _reorderSelectedPhrase() async {
    if (!Platform.isMacOS || _selectedIndices.length != 1) {
      _message('Select one LYRICS phrase to reorder.');
      return;
    }
    final sourceIndex = _selectedIndices.single;
    if (_lines.length < 2) return;
    final targetIndex = await showDialog<int>(context: context, builder: (ctx) =>
      AlertDialog(
        title: const Text('Move phrase after…'),
        content: SizedBox(width: 460, height: 320,
          child: ListView.builder(itemCount: _lines.length,
            itemBuilder: (context, i) => i == sourceIndex
              ? const SizedBox.shrink()
              : ListTile(
                  title: Text(_lines[i].text, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${(_lines[i].startMs / 1000).toStringAsFixed(2)} s'),
                  onTap: () => Navigator.pop(ctx, i),
                ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx),
          child: const Text('CANCEL'))],
      ),
    );
    if (!mounted || targetIndex == null || targetIndex == sourceIndex) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Reorder timeline?'),
      content: const Text('Moving across phrases shifts the timing of intervening phrases and their WORDS. Their durations and word spacing are preserved. SAVE commits the changes.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('MOVE')),
      ],
    ));
    if (!mounted || ok != true) return;
    final startIndex = math.min(sourceIndex, targetIndex);
    final endIndex = math.max(sourceIndex, targetIndex);
    final range = _lines.sublist(startIndex, endIndex + 1);
    final oldStart = range.first.startMs;
    final oldEnd = range.last.endMs;
    final moved = _lines[sourceIndex];
    final reordered = List<TimelineLyricLine>.from(range)..remove(moved);
    if (sourceIndex < targetIndex) {
      reordered.add(moved);
    } else {
      reordered.insert(1, moved);
    }
    // Preserve the original total range, including its free space, by
    // placing any slack at the end. Do not touch clips outside this range.
    var cursor = oldStart;
    for (final line in reordered) {
      final duration = line.durationMs;
      _scaleWordsWithPhrase(line, cursor, cursor + duration);
      line.startMs = cursor;
      line.endMs = cursor + duration;
      cursor += duration;
    }
    if (cursor > oldEnd) {
      _message('Cannot reorder: affected clips exceed the available range.');
      return;
    }
    setState(() {
      _lines.replaceRange(startIndex, endIndex + 1, reordered);
      _selectedIndex = _lines.indexOf(moved);
      _selectedIndices..clear()..add(_selectedIndex!);
      _dirty = true;
    });
  }

  Future<void> _addVocalPhrase() async {
    if (!Platform.isMacOS) return;
    final controller = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Add lyric phrase'),
      content: TextField(controller: controller, autofocus: true,
        decoration: const InputDecoration(hintText: 'yeah')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('ADD')),
      ],
    ));
    controller.dispose();
    if (!mounted || value == null || value.isEmpty) return;
    var start = _playhead.value.clamp(0, math.max(0, _durationMs - _minClipMs)).toInt();
    final occupied = _lines.toList()..sort((a, b) => a.startMs.compareTo(b.startMs));
    for (final line in occupied) {
      if (line.endMs <= start) continue;
      if (line.startMs >= start + _minClipMs) break;
      start = line.endMs;
    }
    final next = occupied.where((line) => line.startMs >= start)
        .map((line) => line.startMs).fold<int>(_durationMs, math.min);
    if (next - start < _minClipMs) {
      _message('No empty gap available after the playhead.');
      return;
    }
    final end = math.min(next, start + 1800);
    final added = TimelineLyricLine(data: {
      'text': value, 'startMs': start, 'endMs': end,
      'originalStartMs': start, 'originalEndMs': end,
      'manualLine': true, 'lineType': 'vocal', 'words': <dynamic>[],
      'wordsEdited': true,
    });
    setState(() {
      _lines.add(added); _sortLines();
      _selectedIndex = _lines.indexOf(added);
      _selectedIndices..clear()..add(_selectedIndex!);
      _dirty = true;
    });
    _generateWordTimings();
  }


  int? _hoveredIndex;

  double _pixelsPerSecond = 50;

  double _dragStartX = 0;

  final Map<int, _DragLineSnapshot> _dragSnapshots = {};

  DateTime _lastAutoScroll = DateTime.fromMillisecondsSinceEpoch(0);

  String? _error;

  @override
  void initState() {
    super.initState();

    _playheadTicker = createTicker(_onPlayheadFrame);

    _load();

    _player.positionStream.listen((position) {
      if (!mounted) {
        return;
      }

      final realMs = position.inMilliseconds.clamp(0, _durationMs).toInt();

      if (_seekInProgress) {
        return;
      }

      if (!_playing) {
        _setPlayheadReference(realMs, updateVisual: true);

        return;
      }

      final predicted = _predictedPlayheadMs();

      final drift = realMs - predicted;

      final absoluteDrift = drift.abs();

      if (absoluteDrift > 180) {
        _setPlayheadReference(realMs, updateVisual: true);

        return;
      }

      if (absoluteDrift > 5) {
        final correction = (drift * 0.18).round();

        _playheadAnchorMs += correction;
      }
    });

    _player.playerStateStream.listen((state) {
      if (!mounted) {
        return;
      }

      final nextPlaying = state.playing;

      if (_playing == nextPlaying) {
        return;
      }

      if (nextPlaying) {
        final realMs = _player.position.inMilliseconds
            .clamp(0, _durationMs)
            .toInt();

        _setPlayheadReference(realMs, updateVisual: true);

        _playheadClock
          ..reset()
          ..start();

        if (!_playheadTicker.isActive) {
          _playheadTicker.start();
        }
      } else {
        if (_playheadTicker.isActive) {
          _playheadTicker.stop();
        }

        _playheadClock.stop();

        final realMs = _player.position.inMilliseconds
            .clamp(0, _durationMs)
            .toInt();

        _setPlayheadReference(realMs, updateVisual: true);
      }

      setState(() {
        _playing = nextPlaying;
      });
    });
  }

  int _predictedPlayheadMs() {
    if (!_playing || !_playheadClock.isRunning) {
      return _playheadAnchorMs;
    }

    return (_playheadAnchorMs + _playheadClock.elapsedMilliseconds)
        .clamp(0, _durationMs)
        .toInt();
  }

  void _setPlayheadReference(int milliseconds, {required bool updateVisual}) {
    final safe = milliseconds.clamp(0, _durationMs).toInt();

    _playheadAnchorMs = safe;

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
      _playhead.value = safe;
    }
  }

  void _onPlayheadFrame(Duration elapsed) {
    if (!_playing || _seekInProgress || _scrubbing) {
      return;
    }

    final predicted = _predictedPlayheadMs();

    if (_playhead.value != predicted) {
      _playhead.value = predicted;
    }

    _autoScroll(predicted);

    if (predicted >= _durationMs) {
      if (_playheadTicker.isActive) {
        _playheadTicker.stop();
      }
    }
  }

  Future<void> _load() async {
    try {
      _editableJsonPath = await _lyricsStorage.editableJsonPath(
        widget.jsonPath,
      );
      final file = File(_editableJsonPath!);

      if (!await file.exists()) {
        throw StateError(
          'Lyrics JSON not found:\n'
          '${widget.jsonPath}',
        );
      }

      // On iOS allow bundled/offline operation before server configuration.
      // When configured, editing is authoritative on Windows.
      _remoteEditing =
          _server.enabled && (Platform.isMacOS || await _server.isConfigured());
      dynamic decoded;
      if (_remoteEditing) {
        // iOS local cache files may be named "02 - Song Title.json".
        // Their filesystem paths are not server IDs or "Artist - Title" names.
        // Resolve from the catalog by the full local title when the regular
        // path-based lookup cannot find a match. Only accept a unique match.
        var remoteSong = await _server.songForPath(widget.jsonPath);
        if (remoteSong == null) {
          final localData = jsonDecode(await file.readAsString(encoding: utf8));
          final localTitle = localData is Map
              ? (localData['title']?.toString().trim() ?? '')
              : '';
          if (localTitle.isNotEmpty) {
            final candidates = (await _server.songs()).where((song) =>
                (song['title']?.toString().trim().toLowerCase() ?? '') ==
                localTitle.toLowerCase()).toList();
            if (candidates.length == 1) remoteSong = candidates.single;
            if (candidates.length > 1) {
              throw StateError(
                'Hay varias canciones llamadas "$localTitle" en el servidor. '
                'No se puede elegir una automáticamente.',
              );
            }
          }
        }
        if (remoteSong == null) {
          throw StateError(
            'No se encontró una coincidencia única en Lyriko Server para '
            '${widget.jsonPath}. Comprueba el título y el catálogo.',
          );
        }
        _serverSongId = remoteSong['id']?.toString();
        final envelope = await _server.lyrics(_serverSongId!);
        _serverVersion = (envelope['version'] as num).toInt();
        decoded = envelope['lyrics'];
      } else {
        decoded = jsonDecode(await file.readAsString(encoding: utf8));
      }

      if (decoded is! Map<String, dynamic>) {
        throw StateError('Invalid JSON.');
      }

      final rawLines = decoded['lines'];

      if (rawLines is! List) {
        throw StateError('No lyric lines.');
      }

      _lines.clear();

      for (final raw in rawLines) {
        final data = Map<String, dynamic>.from(raw as Map);

        data['originalStartMs'] ??= data['startMs'] ?? 0;

        data['originalEndMs'] ??= data['endMs'] ?? data['startMs'] ?? 0;

        data['words'] ??= <dynamic>[];

        _lines.add(TimelineLyricLine(data: data));
      }

      _sortLines();

      _durationMs = (decoded['durationMs'] as num?)?.toInt() ?? 0;

      if (_lines.isNotEmpty) {
        _durationMs = math
            .max(_durationMs, _lines.map((line) => line.endMs).reduce(math.max))
            .toInt();
      }

      if (_durationMs <= 0) {
        _durationMs = 180000;
      }

      _title = decoded['title']?.toString() ?? '';

      _artist = decoded['artist']?.toString() ?? '';

      _audioPath = decoded['audioPath']?.toString() ?? '';

      _json = decoded;

      // Prefer previously imported audio; otherwise discover the bundled
      // development MP3 for this song without changing the lyrics JSON.
      if (!_remoteEditing &&
          (_audioPath.isEmpty || !await File(_audioPath).exists())) {
        final bundledAudio = await _bundledAudioForSong();
        if (bundledAudio != null) _audioPath = bundledAudio;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
      });

      await _loadAudio();

      await _loadWaveform();

      // First opening after import: align only clearly unsynchronized lines.
      // Never silently rewrite a track that already has valid timestamps.
      if (Platform.isMacOS && _lines.isNotEmpty &&
          _lines.every((line) =>
              line.data['manualLine'] == true &&
              (line.originalStartMs == 0 && line.originalEndMs == 0))) {
        _autoAlignApproximate(replaceExisting: true);
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
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

  Future<String?> _bundledAudioForSong() async {
    if (!(Platform.isIOS || Platform.isAndroid)) return null;
    final filename = widget.jsonPath
        .split('/')
        .last
        .replaceFirst(RegExp(r'\.json$', caseSensitive: false), '');
    // Read only the requested song to avoid copying all MP3s on first launch.
    final asset = 'assets/audio/$filename.mp3';
    try {
      final data = await rootBundle.load(asset);
      final folder = Directory(
        '${(await getApplicationSupportDirectory()).path}/lyriko_audio',
      );
      await folder.create(recursive: true);
      final file = File('${folder.path}/$filename.mp3');
      if (!await file.exists() || await file.length() != data.lengthInBytes) {
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      return file.path;
    } catch (_) {
      return null; // No MP3 bundled yet. Editing JSON remains available.
    }
  }

  Future<void> _loadAudio() async {
    if (_remoteEditing) {
      if (_serverSongId == null) return;
    } else {
      if (_audioPath.isEmpty || !await File(_audioPath).exists()) return;
    }

    try {
      final duration = _remoteEditing
          ? await _player.setUrl(await _server.audioUrl(_serverSongId!))
          : await _player.setFilePath(_audioPath);

      await _player.setVolume(_volume);

      if (!mounted) {
        return;
      }

      setState(() {
        _audioAvailable = true;

        if (duration != null && duration.inMilliseconds > 0) {
          _durationMs = math.max(_durationMs, duration.inMilliseconds).toInt();
        }
      });

      _setPlayheadReference(0, updateVisual: true);
    } catch (e) {
      debugPrint('Audio error: $e');
    }
  }

  Future<void> _loadWaveform() async {
    if (!mounted) {
      return;
    }

    setState(() {
      _waveformLoading = true;
    });

    try {
      final data = _remoteEditing
          ? WaveformData(samples: await _server.waveform(_serverSongId!))
          : await _waveformService.loadOrCreate(
              songJsonPath: widget.jsonPath,
              audioPath: _audioPath,
            );

      if (!mounted) {
        return;
      }

      setState(() {
        _waveform = data?.samples ?? [];

        _waveformLoading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _waveformLoading = false;
      });

      debugPrint('Waveform error: $e');
    }
  }

  void _sortLines() {
    _lines.sort((a, b) => a.startMs.compareTo(b.startMs));
  }

  double _msToPx(int ms) {
    return ms / 1000 * _pixelsPerSecond;
  }

  int _pxToMs(double px) {
    return (px / _pixelsPerSecond * 1000).round();
  }

  double get _timelineWidth {
    return math.max<double>(_msToPx(_durationMs) + 100, 1200);
  }

  void _selectSingle(int index) {
    setState(() {
      _selectedIndex = index;

      _selectedIndices
        ..clear()
        ..add(index);
    });
  }

  void _clearSelection() {
    if (_selectedIndex == null && _selectedIndices.isEmpty) return;
    setState(() {
      _selectedIndex = null;
      _selectedIndices.clear();
    });
  }

  void _selectGroup(Set<int> indices) {
    final clean = indices
        .where((index) => index >= 0 && index < _lines.length)
        .toSet();

    int? primary;

    if (clean.isNotEmpty) {
      if (_selectedIndex != null && clean.contains(_selectedIndex)) {
        primary = _selectedIndex;
      } else {
        final sorted = clean.toList()..sort();

        primary = sorted.first;
      }
    }

    setState(() {
      _selectedIndices
        ..clear()
        ..addAll(clean);

      _selectedIndex = primary;
    });
  }

  Future<void> _togglePlay() async {
    if (!_audioAvailable) {
      _message('Original MP3 unavailable.');

      return;
    }

    if (_playing) {
      await _player.pause();

      return;
    }

    if (_playhead.value >= _durationMs - 100) {
      await _seek(0);
    }

    final realMs = _player.position.inMilliseconds
        .clamp(0, _durationMs)
        .toInt();

    _setPlayheadReference(realMs, updateVisual: true);

    await _player.play();
  }

  Future<void> _setVolume(double value) async {
    final safe = value.clamp(0.0, 1.0).toDouble();

    setState(() {
      _volume = safe;
    });

    await _player.setVolume(safe);
  }

  Future<void> _seek(int ms) async {
    final value = ms.clamp(0, _durationMs).toInt();

    _playhead.value = value;

    _playheadAnchorMs = value;

    if (!_audioAvailable) {
      return;
    }

    _seekInProgress = true;

    _playheadClock.stop();

    try {
      await _player.seek(Duration(milliseconds: value));

      final confirmed = _player.position.inMilliseconds
          .clamp(0, _durationMs)
          .toInt();

      _setPlayheadReference(confirmed, updateVisual: true);
    } finally {
      _seekInProgress = false;

      if (_playing) {
        _playheadClock
          ..reset()
          ..start();

        if (!_playheadTicker.isActive) {
          _playheadTicker.start();
        }
      }
    }
  }

  Future<void> _skip(int delta) {
    return _seek(_playhead.value + delta);
  }

  void _autoScroll(int ms) {
    if (!_scrollController.hasClients) {
      return;
    }

    final now = DateTime.now();

    if (now.difference(_lastAutoScroll) < const Duration(milliseconds: 180)) {
      return;
    }

    final position = _scrollController.position;

    final viewport = position.viewportDimension;

    if (viewport <= 0) {
      return;
    }

    final x = _msToPx(ms);

    final leftBoundary = position.pixels + viewport * 0.12;

    final rightBoundary = position.pixels + viewport * 0.82;

    double? target;

    if (x > rightBoundary) {
      target = x - viewport * 0.35;
    } else if (x < leftBoundary) {
      target = x - viewport * 0.20;
    }

    if (target == null) {
      return;
    }

    _lastAutoScroll = now;

    _scrollController.jumpTo(
      target.clamp(0.0, position.maxScrollExtent).toDouble(),
    );
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }

    if (Platform.isMacOS &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      _zoom(event.localPosition.dx, event.scrollDelta.dy < 0 ? 1.18 : 1 / 1.18);

      return;
    }

    if (!_scrollController.hasClients) {
      return;
    }

    final delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;

    final target = (_scrollController.offset + delta).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    _scrollController.jumpTo(target.toDouble());
  }

  void _zoom(double pointerX, double factor) {
    final oldOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;

    final anchorMs = _pxToMs(oldOffset + pointerX);

    final newScale = (_pixelsPerSecond * factor).clamp(12.0, 350.0).toDouble();

    if (newScale == _pixelsPerSecond) {
      return;
    }

    setState(() {
      _pixelsPerSecond = newScale;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }

      final offset = _msToPx(anchorMs) - pointerX;

      _scrollController.jumpTo(
        offset
            .clamp(0.0, _scrollController.position.maxScrollExtent)
            .toDouble(),
      );
    });
  }

  _DragLineSnapshot _captureSnapshot(int index) {
    final line = _lines[index];

    final wordSnapshots = <_WordTimingSnapshot>[];

    final words = line.data['words'];

    if (words is List) {
      for (final raw in words) {
        if (raw is! Map) {
          continue;
        }

        wordSnapshots.add(
          _WordTimingSnapshot(
            word: raw,

            startMs: raw['startMs'] is num
                ? (raw['startMs'] as num).toInt()
                : null,

            endMs: raw['endMs'] is num ? (raw['endMs'] as num).toInt() : null,
          ),
        );
      }
    }

    return _DragLineSnapshot(
      startMs: line.startMs,

      endMs: line.endMs,

      words: wordSnapshots,
    );
  }

  void _moveStart(int index, DragStartDetails details) {
    if (!_selectedIndices.contains(index)) {
      _selectedIndices
        ..clear()
        ..add(index);
    }

    _selectedIndex = index;

    _dragStartX = details.globalPosition.dx;

    _dragSnapshots.clear();

    for (final selected in _selectedIndices) {
      _dragSnapshots[selected] = _captureSnapshot(selected);
    }

    setState(() {});
  }

  void _moveUpdate(int index, DragUpdateDetails details) {
    if (_dragSnapshots.isEmpty) {
      return;
    }

    final requestedDelta = _pxToMs(details.globalPosition.dx - _dragStartX);

    var minimumDelta = -0x3FFFFFFF;

    var maximumDelta = 0x3FFFFFFF;

    final moving = _dragSnapshots.keys.toSet();

    for (final entry in _dragSnapshots.entries) {
      final currentIndex = entry.key;

      final snapshot = entry.value;

      //
      // Timeline bounds.
      //
      minimumDelta = math.max(minimumDelta, -snapshot.startMs);

      maximumDelta = math.min(maximumDelta, _durationMs - snapshot.endMs);

      //
      // Previous clip that is NOT part of the group.
      //
      final previousIndex = currentIndex - 1;

      if (previousIndex >= 0 && !moving.contains(previousIndex)) {
        minimumDelta = math.max(
          minimumDelta,
          _lines[previousIndex].endMs - snapshot.startMs,
        );
      }

      //
      // Next clip that is NOT part of the group.
      //
      final nextIndex = currentIndex + 1;

      if (nextIndex < _lines.length && !moving.contains(nextIndex)) {
        maximumDelta = math.min(
          maximumDelta,
          _lines[nextIndex].startMs - snapshot.endMs,
        );
      }
    }

    final delta = requestedDelta.clamp(minimumDelta, maximumDelta).toInt();

    setState(() {
      for (final entry in _dragSnapshots.entries) {
        final selectedIndex = entry.key;

        final snapshot = entry.value;

        final line = _lines[selectedIndex];

        line.startMs = snapshot.startMs + delta;

        line.endMs = snapshot.endMs + delta;

        for (final wordSnapshot in snapshot.words) {
          if (wordSnapshot.startMs != null) {
            wordSnapshot.word['startMs'] = wordSnapshot.startMs! + delta;
          }

          if (wordSnapshot.endMs != null) {
            wordSnapshot.word['endMs'] = wordSnapshot.endMs! + delta;
          }
        }
      }

      _dirty = true;
    });
  }

  void _moveEnd() {
    _dragSnapshots.clear();
  }

  // LYRICS is the timing container for WORDS. Resizing the phrase scales
  // every word boundary proportionally, including manually edited timings.
  // The phrase's current coordinates are the source for every drag update,
  // avoiding stale CTC coordinates and cumulative drift.
  void _scaleWordsWithPhrase(
    TimelineLyricLine line, int nextStartMs, int nextEndMs,
  ) {
    final words = _editableWords(line);
    if (words.isEmpty) return;
    final previousStart = line.startMs;
    final previousEnd = line.endMs;
    final previousDuration = math.max(1, previousEnd - previousStart);
    final nextDuration = math.max(1, nextEndMs - nextStartMs);
    final originalDuration = line.originalEndMs - line.originalStartMs;

    int displayed(int rawMs) {
      if (line.data['wordsEdited'] == true) return rawMs;
      if (originalDuration <= 0) {
        return previousStart + rawMs - line.originalStartMs;
      }
      return previousStart +
          ((rawMs - line.originalStartMs) * previousDuration /
                  originalDuration)
              .round();
    }

    int scaled(int rawMs) {
      final relative = (displayed(rawMs) - previousStart)
          .clamp(0, previousDuration);
      return (nextStartMs + relative * nextDuration / previousDuration)
          .round()
          .clamp(nextStartMs, nextEndMs)
          .toInt();
    }

    for (final word in words) {
      final oldStart = (word['startMs'] as num?)?.toInt();
      final oldEnd = (word['endMs'] as num?)?.toInt();
      if (oldStart == null || oldEnd == null) continue;
      final nextStart = scaled(oldStart);
      final nextEnd = scaled(oldEnd);
      word['startMs'] = nextStart;
      word['endMs'] = math.max(nextStart, nextEnd);
    }
    line.data['words'] = words;
    line.data['wordsEdited'] = true;
  }

  void _resizeLeft(int index, DragUpdateDetails details) {
    final line = _lines[index];

    final min = index > 0 ? _lines[index - 1].endMs : 0;

    final max = line.endMs - _minClipMs;

    final value = (line.startMs + _pxToMs(details.delta.dx))
        .clamp(min, max)
        .toInt();

    setState(() {
      _scaleWordsWithPhrase(line, value, line.endMs);
      //
      // Resize always becomes a single-clip operation.
      //
      _selectedIndices
        ..clear()
        ..add(index);

      _selectedIndex = index;

      line.startMs = value;

      _dirty = true;
    });
  }

  void _resizeRight(int index, DragUpdateDetails details) {
    final line = _lines[index];

    final min = line.startMs + _minClipMs;

    final max = index < _lines.length - 1
        ? _lines[index + 1].startMs
        : _durationMs;

    final value = (line.endMs + _pxToMs(details.delta.dx))
        .clamp(min, max)
        .toInt();

    setState(() {
      _scaleWordsWithPhrase(line, line.startMs, value);
      _selectedIndices
        ..clear()
        ..add(index);

      _selectedIndex = index;

      line.endMs = value;

      _dirty = true;
    });
  }

  // Double-click a phrase handle to close the gap to its neighbor.
  // Word boundaries remain proportional to the resized parent phrase.
  void _snapPhraseEdge(int index, String edge) {
    if (!Platform.isMacOS || index < 0 || index >= _lines.length) return;
    final line = _lines[index];
    if (edge == 'start') {
      final boundary = index > 0 ? _lines[index - 1].endMs : 0;
      final nextStart = boundary.clamp(0, line.endMs - _minClipMs).toInt();
      if (nextStart == line.startMs) return;
      setState(() {
        _scaleWordsWithPhrase(line, nextStart, line.endMs);
        line.startMs = nextStart;
        _selectedIndex = index;
        _selectedIndices..clear()..add(index);
        _dirty = true;
      });
    } else if (edge == 'end') {
      final boundary = index + 1 < _lines.length
          ? _lines[index + 1].startMs : _durationMs;
      final nextEnd = boundary.clamp(line.startMs + _minClipMs, _durationMs).toInt();
      if (nextEnd == line.endMs) return;
      setState(() {
        _scaleWordsWithPhrase(line, line.startMs, nextEnd);
        line.endMs = nextEnd;
        _selectedIndex = index;
        _selectedIndices..clear()..add(index);
        _dirty = true;
      });
    }
  }

  // Word handles snap only inside their enclosing LYRICS phrase.
  void _snapWordEdge(int lineIndex, int wordIndex, String edge) {
    if (!Platform.isMacOS || lineIndex < 0 || lineIndex >= _lines.length) return;
    final line = _lines[lineIndex];
    final words = _editableWords(line);
    if (wordIndex < 0 || wordIndex >= words.length) return;
    // Convert legacy CTC word coordinates before modifying an individual word.
    if (line.data['wordsEdited'] != true) {
      final originalDuration = line.originalEndMs - line.originalStartMs;
      for (final word in words) {
        final start = (word['startMs'] as num?)?.toInt() ?? line.startMs;
        final end = (word['endMs'] as num?)?.toInt() ?? line.endMs;
        int project(int t) => originalDuration <= 0
            ? line.startMs + t - line.originalStartMs
            : line.startMs + ((t - line.originalStartMs) *
                line.durationMs / originalDuration).round();
        word['startMs'] = project(start).clamp(line.startMs, line.endMs).toInt();
        word['endMs'] = project(end).clamp(line.startMs, line.endMs).toInt();
      }
    }
    final word = words[wordIndex];
    final start = (word['startMs'] as num?)?.toInt() ?? line.startMs;
    final end = (word['endMs'] as num?)?.toInt() ?? line.endMs;
    if (edge == 'start') {
      final neighborEnd = wordIndex > 0
          ? (words[wordIndex - 1]['endMs'] as num?)?.toInt() ?? line.startMs
          : line.startMs;
      word['startMs'] = neighborEnd.clamp(line.startMs, end).toInt();
    } else if (edge == 'end') {
      final neighborStart = wordIndex + 1 < words.length
          ? (words[wordIndex + 1]['startMs'] as num?)?.toInt() ?? line.endMs
          : line.endMs;
      word['endMs'] = neighborStart.clamp(start, line.endMs).toInt();
    } else {
      return;
    }
    setState(() {
      line.data['words'] = words;
      line.data['wordsEdited'] = true;
      _selectedWordLine = lineIndex;
      _selectedWordIndex = wordIndex;
      _dirty = true;
    });
  }

  void _addInstrumental() {
    final index = _selectedIndex;

    if (index == null) {
      return;
    }

    final line = _lines[index];

    final next = index < _lines.length - 1
        ? _lines[index + 1].startMs
        : _durationMs;

    if (next - line.endMs < _minClipMs) {
      _message('Create a visible gap first.');

      return;
    }

    setState(() {
      _lines.insert(
        index + 1,
        TimelineLyricLine(
          data: {
            'text': '♪',

            'startMs': line.endMs,

            'endMs': next,

            'originalStartMs': line.endMs,

            'originalEndMs': next,

            'words': <dynamic>[],

            'manualLine': true,

            'lineType': 'instrumental',
          },
        ),
      );

      _selectedIndex = index + 1;

      _selectedIndices
        ..clear()
        ..add(index + 1);

      _dirty = true;
    });
  }

  Future<void> _editText() async {
    final index = _selectedIndex;

    if (index == null) {
      return;
    }

    final line = _lines[index];

    final controller = TextEditingController(text: line.text);

    final result = await showDialog<String>(
      context: context,

      builder: (context) => AlertDialog(
        title: const Text('Edit lyric'),

        content: TextField(
          controller: controller,

          autofocus: true,

          maxLines: 4,
        ),

        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),

            child: const Text('CANCEL'),
          ),

          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),

            child: const Text('SAVE'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (result == null || result.isEmpty || result == line.text) {
      return;
    }

    setState(() {
      line.text = result;

      if (!line.isInstrumental) {
        line.data['words'] = <dynamic>[];
      }

      _dirty = true;
    });
  }

  void _deleteSelected() {
    final index = _selectedIndex;

    if (index == null) {
      return;
    }

    setState(() {
      _lines.removeAt(index);

      _selectedIndex = null;

      _selectedIndices.clear();

      _dirty = true;
    });
  }

  Future<void> _replaceAllLyrics() async {
    final controller = TextEditingController();
    try {
      final replacement = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Replace all lyrics'),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: controller,
              autofocus: true,
              minLines: 8,
              maxLines: 16,
              decoration: const InputDecoration(
                hintText: 'Paste the correct lyrics, one line per phrase',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('CONTINUE'),
            ),
          ],
        ),
      );
      if (!mounted || replacement == null) return;
      final phrases = replacement
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (phrases.isEmpty) {
        _message('Paste at least one lyric line.');
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Replace existing lyrics?'),
          content: Text(
            'This will replace ${_lines.length} existing segments with '
            '${phrases.length} new phrases. Existing timings will not be reused '
            'because they belong to different lyrics. You must sync the new '
            'segments. Nothing is saved until you press SAVE.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('REPLACE'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      // Distribute placeholder segments for editing, not as synchronized lyrics.
      // Leave the first second as an intro and reserve at least 300ms per line.
      final availableMs = math.max(_durationMs - 1000, phrases.length * _minClipMs);
      final segmentMs = math.max(_minClipMs, availableMs ~/ phrases.length);
      setState(() {
        _lines.clear();
        for (var i = 0; i < phrases.length; i++) {
          final start = 1000 + i * segmentMs;
          final end = math.min(_durationMs, start + segmentMs);
          _lines.add(TimelineLyricLine(data: {
            'text': phrases[i],
            'startMs': start,
            'endMs': math.max(start + _minClipMs, end),
            'originalStartMs': 0,
            'originalEndMs': 0,
            'words': <dynamic>[],
            'manualLine': true,
          }));
        }
        _selectedIndex = null;
        _selectedIndices.clear();
        _dirty = true;
      });
      // A full replacement has no trustworthy old timestamps. Automatically
      // create a coarse proposal for macOS without saving it.
      if (Platform.isMacOS) _autoAlignApproximate(replaceExisting: true);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _save() async {
    if (_json == null || _saving) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      _sortLines();

      final output = Map<String, dynamic>.from(_json!);

      output['lines'] = _lines.map((line) => line.data).toList();

      output['durationMs'] = _durationMs;

      // Commit to Windows first. If authorization/version fails, keep the
      // editor dirty and do not incorrectly report a successful save.
      if (_remoteEditing) {
        if (_serverSongId == null || _serverVersion == null) {
          throw StateError('No se ha cargado la versión del servidor.');
        }
        _serverVersion = await _server.saveLyrics(
          _serverSongId!,
          _serverVersion!,
          output,
        );
      }

      await File(_editableJsonPath ?? widget.jsonPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(output),

        encoding: utf8,

        flush: true,
      );

      final txtPath = (_editableJsonPath ?? widget.jsonPath).replaceFirst(
        RegExp(r'\.json$', caseSensitive: false),
        '.txt',
      );

      await File(txtPath).writeAsString(
        '${_lines.map((line) => line.text).join('\n')}\n',

        encoding: utf8,

        flush: true,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _saving = false;

        _dirty = false;

        _json = output;
      });

      // The editor stays open after SAVE. Refresh MY MUSIC immediately;
      // never wait for a Navigator.pop that may happen much later.
      if (widget.onLyricsSaved != null) {
        try {
          await widget.onLyricsSaved!();
        } catch (refreshError) {
          debugPrint('Lyrics saved, but player refresh failed: $refreshError');
          if (mounted) {
            _message('Lyrics saved. MY MUSIC could not refresh yet; reopen the player.');
          }
        }
      }
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

  KeyEventResult _keyboard(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    if (Platform.isMacOS) {
      final keys = HardwareKeyboard.instance;
      if (keys.isMetaPressed || keys.isControlPressed) {
        if (event.logicalKey == LogicalKeyboardKey.keyC) {
          _copyPhrases(); return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyV) {
          _pastePhrases(); return KeyEventResult.handled;
        }
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _togglePlay();

      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _skip(-1000);

      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _skip(1000);

      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    if (_playheadTicker.isActive) {
      _playheadTicker.stop();
    }

    _playheadTicker.dispose();

    _playheadClock.stop();

    _player.dispose();

    _scrollController.dispose();

    _focusNode.dispose();

    _playhead.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF090A0F),
      ),
      child: Focus(
        focusNode: _focusNode,

        autofocus: true,

        onKeyEvent: _keyboard,

        child: Scaffold(
          backgroundColor: const Color(0xFF090A0F),

          appBar: AppBar(
            backgroundColor: const Color(0xFF090A0F),

            title: const Text('Lyrics Timeline'),

            actions: [
              IconButton(
                tooltip: 'Replace all lyrics',
                onPressed: _loading || _saving ? null : _replaceAllLyrics,
                icon: const Icon(Icons.library_music_outlined),
              ),
              FilledButton.icon(
                onPressed: !_dirty || _saving ? null : _save,

                icon: const Icon(Icons.save_rounded),

                label: const Text('SAVE'),
              ),

              const SizedBox(width: 12),
            ],
          ),

          body: _loading
              ? const Center(child: CircularProgressIndicator())
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
            const Icon(
              Icons.volume_up_rounded,
              size: 17,
              color: Color(0xFFD3BAFF),
            ),
            Expanded(
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
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
              icon: Icon(
                _volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
              ),
              onPressed: () =>
                  setState(() => _volumeSliderVisible = !_volumeSliderVisible),
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
                icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
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
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
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
    final compact = _compactIosTimeline;
    return Container(
      color: const Color(0xFF11131A),

      padding: EdgeInsets.all(compact ? 10 : 16),

      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  _title,

                  style: TextStyle(
                    color: const Color(0xFFFFFFFF),
                    fontSize: compact ? 14 : 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                Text(_artist, style: const TextStyle(color: Color(0xFFADB4C4))),
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
        child: Row(
          children: [
            IconButton(
              tooltip: 'Zoom out',
              onPressed: () => _zoom(140, 1 / 1.25),
              icon: const Icon(Icons.remove),
            ),
            Text(
              '${_pixelsPerSecond.round()} px/s',
              style: const TextStyle(fontSize: 12),
            ),
            IconButton(
              tooltip: 'Zoom in',
              onPressed: () => _zoom(140, 1.25),
              icon: const Icon(Icons.add),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Add instrumental segment',
              onPressed: _selectedIndex == null ? null : _addInstrumental,
              icon: const Icon(Icons.music_note_rounded),
            ),
            IconButton(
              tooltip: 'Edit text',
              onPressed: _selectedIndex == null ? null : _editText,
              icon: const Icon(Icons.edit_rounded),
            ),
            IconButton(
              tooltip: 'Delete segment',
              onPressed: _selectedIndex == null ? null : _deleteSelected,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      );
    }
    return _desktopToolbar();
  }

  Widget _desktopToolbar() {
    return Container(
      color: const Color(0xFF161924),

      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),

      child: Row(
        children: [
          IconButton(
            tooltip: 'Zoom out',

            onPressed: () => _zoom(450, 1 / 1.25),

            icon: const Icon(Icons.remove),
          ),

          SizedBox(
            width: 80,

            child: Center(child: Text('${_pixelsPerSecond.round()} px/s')),
          ),

          IconButton(
            tooltip: 'Zoom in',

            onPressed: () => _zoom(450, 1.25),

            icon: const Icon(Icons.add),
          ),

          const SizedBox(width: 10),

          const Text(
            'Ctrl + Wheel = Zoom',

            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),

          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _hasApproximateAlignmentInput ? _confirmAutoAlign : null,
            icon: const Icon(Icons.graphic_eq, size: 16),
            label: const Text('AUTO ALIGN'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _generateWordTimings,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('WORDS FROM LINES'),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('WORDS'),
            selected: _showWords,
            onSelected: (value) => setState(() => _showWords = value),
          ),
          const Spacer(),

          if (_selectedIndices.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: 12),

              child: Text(
                '${_selectedIndices.length} selected',

                style: const TextStyle(
                  color: Color(0xFFC4B4FF),

                  fontSize: 12,

                  fontWeight: FontWeight.w700,
                ),
              ),
            ),

          if (Platform.isMacOS) ...[
            IconButton(
              tooltip: 'Create automation clip for selected lyric',
              onPressed: _selectedIndices.length == 1 ? _createSweepClip : null,
              icon: const Icon(Icons.add_chart_rounded)),
            FilterChip(
              label: const Text('CURVE'),
              selected: _showCurveLane,
              onSelected: (v) => setState(() => _showCurveLane = v),
            ),
            IconButton(tooltip: 'Copy complete phrase (Cmd+C)',
              onPressed: _selectedIndices.isEmpty ? null : _copyPhrases,
              icon: const Icon(Icons.copy_rounded)),
            IconButton(tooltip: 'Paste at next free gap (Cmd+V)',
              onPressed: _copiedPhrases.isEmpty ? null : _pastePhrases,
              icon: const Icon(Icons.content_paste_rounded)),
            IconButton(tooltip: 'Add lyric phrase at playhead',
              onPressed: _addVocalPhrase,
              icon: const Icon(Icons.add_comment_outlined)),
            IconButton(tooltip: 'Move selected phrase after another (ripple reorder)',
              onPressed: _selectedIndices.length == 1 ? _reorderSelectedPhrase : null,
              icon: const Icon(Icons.swap_horiz_rounded)),
          ],
          OutlinedButton.icon(
            onPressed: _selectedIndex == null ? null : _addInstrumental,

            icon: const Icon(Icons.music_note_rounded, size: 17),

            label: const Text('ADD ♪ AFTER'),
          ),

          const SizedBox(width: 8),

          OutlinedButton.icon(
            onPressed: _selectedIndex == null ? null : _editText,

            icon: const Icon(Icons.edit_rounded, size: 17),

            label: const Text('TEXT'),
          ),

          IconButton(
            tooltip: 'Delete selected segment',

            onPressed: _selectedIndex == null ? null : _deleteSelected,

            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  Widget _timeline() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the lyrics lane compact; the remaining viewport is a karaoke
        // preview rather than a blank, oversized lyrics track.
        final lyricsTrackHeight =
            _compactIosTimeline ? _lyricsHeight * 0.85 : _lyricsHeight;
        final audioTrackHeight =
            _compactIosTimeline ? _audioHeight * 0.68 : _audioHeight;
        final trackLabelWidth =
            _compactIosTimeline ? 48.0 : _labelWidth;
        final wordLaneHeight = Platform.isMacOS && _showWords ? _wordsHeight : 0.0;
        final curveLaneHeight = Platform.isMacOS && _showCurveLane ? 88.0 : 0.0;
        final laneHeight = _rulerHeight + audioTrackHeight + lyricsTrackHeight + wordLaneHeight + curveLaneHeight;
        return Column(children: [
          SizedBox(height: laneHeight, child: Row(
          children: [
            SizedBox(
              width: trackLabelWidth,

              child: Column(
                children: [
                  SizedBox(height: _rulerHeight),

                  Container(
                    height: audioTrackHeight,

                    color: const Color(0xFF111722),

                    alignment: Alignment.center,

                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,

                      children: [
                        Icon(
                          Icons.graphic_eq_rounded,

                          color: Color(0xFF698AB6),
                        ),

                        if (!_compactIosTimeline) const SizedBox(height: 3),

                        if (!_compactIosTimeline) const Text(
                          'AUDIO',

                          style: TextStyle(
                            color: Color(0xFF8295B5),

                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Container(
                    height: lyricsTrackHeight,

                    color: const Color(0xFF15131D),

                    alignment: Alignment.center,

                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,

                      children: [
                        Icon(Icons.subtitles_rounded, color: Color(0xFF9D8AC4)),

                        if (!_compactIosTimeline) const SizedBox(height: 3),

                        if (!_compactIosTimeline) const Text(
                          'LYRICS',

                          style: TextStyle(
                            color: Color(0xFFAFA0CC),

                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (wordLaneHeight > 0)
                    Container(
                      height: wordLaneHeight,
                      color: const Color(0xFF141B24),
                      alignment: Alignment.center,
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.record_voice_over_outlined, color: Color(0xFF8FCFCB)),
                          Text('WORDS', style: TextStyle(fontSize: 11, color: Color(0xFF8FCFCB))),
                        ],
                      ),
                    ),
                  if (curveLaneHeight > 0)
                    Container(height: curveLaneHeight, color: const Color(0xFF211A30),
                      alignment: Alignment.center,
                      child: const Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.show_chart, color: Color(0xFFB28BFF)),
                        Text('CURVE', style: TextStyle(fontSize: 11, color: Color(0xFFB28BFF))),
                      ])),
                ],
              ),
            ),

            Expanded(
              child: Listener(
                key: _timelineAreaKey,
                onPointerSignal: _wheel,
                onPointerDown: _trackTouchDown,
                onPointerMove: _trackTouchMove,
                onPointerUp: _trackTouchEnd,
                onPointerCancel: _trackTouchEnd,

                child: Scrollbar(
                  controller: _scrollController,

                  thumbVisibility: true,

                  child: SingleChildScrollView(
                    controller: _scrollController,

                    scrollDirection: Axis.horizontal,
                    physics: (_pinchActive || _marqueeSelecting)
                        ? const NeverScrollableScrollPhysics()
                        : null,

                    child: SizedBox(
                      width: _timelineWidth,

                      child: Column(
                        children: [
                          TimelineRuler(
                            width: _timelineWidth,

                            height: _rulerHeight,

                            pixelsPerSecond: _pixelsPerSecond,

                            durationMs: _durationMs,

                            onSeekX: (x) => _seek(_pxToMs(x)),
                          ),

                          WaveformTrack(
                            width: _timelineWidth,

                            height: audioTrackHeight,

                            waveform: _waveform,

                            loading: _waveformLoading,

                            playhead: _playhead,

                            pixelsPerSecond: _pixelsPerSecond,

                            onSeekX: (x) => _seek(_pxToMs(x)),

                            onScrubX: (x) => _seek(_pxToMs(x)),

                            onScrubStart: () {
                              _scrubbing = true;
                            },

                            onScrubEnd: () {
                              _scrubbing = false;

                              if (_playing) {
                                _setPlayheadReference(
                                  _player.position.inMilliseconds,

                                  updateVisual: true,
                                );
                              }
                            },
                          ),

                          LyricsTrack(
                            width: _timelineWidth,

                            height: lyricsTrackHeight,

                            pixelsPerSecond: _pixelsPerSecond,

                            lines: _lines,

                            selectedIndices: _selectedIndices,

                            hoveredIndex: _hoveredIndex,

                            playhead: _playhead,

                            onSelect: _selectSingle,

                            onSelectionChanged: _selectGroup,

                            onClearSelection: _clearSelection,

                            onMarqueeStateChanged: _onMarqueeStateChanged,

                            onHover: (index) {
                              setState(() {
                                _hoveredIndex = index;
                              });
                            },

                            onExitHover: () {
                              setState(() {
                                _hoveredIndex = null;
                              });
                            },

                            onMoveStart: _moveStart,

                            onMoveUpdate: _moveUpdate,

                            onMoveEnd: _moveEnd,

                            onResizeLeft: _resizeLeft,

                            onResizeRight: _resizeRight,
                            onDoubleTapEdge: _snapPhraseEdge,
                          ),
                          if (wordLaneHeight > 0)
                            WordTimingTrack(
                              width: _timelineWidth,
                              height: wordLaneHeight,
                              pixelsPerSecond: _pixelsPerSecond,
                              lines: _lines,
                              selectedLine: _selectedWordLine,
                              selectedWord: _selectedWordIndex,
                              playhead: _playhead,
                              onSelect: (lineIndex, wordIndex) => setState(() {
                                _selectedWordLine = lineIndex;
                                _selectedWordIndex = wordIndex;
                                _selectedIndex = lineIndex;
                                _selectedIndices..clear()..add(lineIndex);
                              }),
                              onChange: _updateWord,
                              onDoubleTapEdge: _snapWordEdge,
                            ),
                          if (curveLaneHeight > 0)
                            SizedBox(
                              height: curveLaneHeight,
                              width: _timelineWidth,
                              child: Stack(children: [
                                const Positioned.fill(
                                  child: ColoredBox(color: Color(0xFF1D1929))),
                                for (var i = 0; i < _lines.length; i++)
                                  if (_hasSweepClip(_lines[i]))
                                    Positioned(
                                      left: _lines[i].startMs * _pixelsPerSecond / 1000,
                                      width: math.max(2.0, _lines[i].durationMs * _pixelsPerSecond / 1000),
                                      top: 7, bottom: 7,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () => _selectSingle(i),
                                        onDoubleTap: () {
                                          _selectSingle(i);
                                          _editSweepCurve(index: i);
                                        },
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF332440),
                                            borderRadius: BorderRadius.circular(5),
                                            border: Border.all(
                                              color: _selectedIndex == i
                                                ? const Color(0xFFD3B2FF)
                                                : const Color(0xFF795B9B)),
                                          ),
                                          child: ClipRect(child: Column(children: [
                                            Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                              child: Align(
                                                alignment: Alignment.centerLeft,
                                                child: Text(_lines[i].text,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    color: Color(0xFFE0C9FF))),
                                              ),
                                            ),
                                            Expanded(child: CustomPaint(
                                              painter: SweepCurvePainter(
                                                points: _sweepPointsFor(_lines[i])),
                                              child: const SizedBox.expand(),
                                            )),
                                          ])),
                                        ),
                                      ),
                                    ),
                              ]),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        )),
          Expanded(child: _editorKaraokePreview()),
        ]);
      },
    );
  }

  // Interpolate from CTC word boundaries when present; do not spread
  // the entire lyric uniformly across its calibrated line duration.
  bool _hasSweepClip(TimelineLyricLine line) =>
      line.text.trim() != '♪' &&
      line.data['sweepCurve'] != null &&
      line.data['sweepCurve'] != 'linear';

  List<List<double>> _sweepPointsFor(TimelineLyricLine line) {
    final mode = line.data['sweepCurve']?.toString() ?? 'linear';
    return mode == 'automation'
        ? LyricSweepCurve.parsePoints(line.data['sweepPoints'])
        : LyricSweepCurve.preset(mode);
  }

  void _createSweepClip() {
    if (!Platform.isMacOS || _selectedIndices.length != 1) return;
    final index = _selectedIndices.single;
    final line = _lines[index];
    if (line.text.trim() == '♪') {
      _message('Instrumental notes stay fully highlighted.');
      return;
    }
    if (_hasSweepClip(line)) {
      _message('Automation already exists. Double-click its CURVE clip to edit.');
      setState(() => _showCurveLane = true);
      return;
    }
    setState(() {
      line.data['sweepCurve'] = 'automation';
      line.data['sweepPoints'] = LyricSweepCurve.preset('linear');
      _showCurveLane = true;
      _dirty = true;
    });
    _message('Automation clip created. Double-click in CURVE to edit.');
  }

  Future<void> _editSweepCurve({int? index}) async {
    if (!Platform.isMacOS) return;
    final target = index ?? _selectedIndex;
    if (target == null || target < 0 || target >= _lines.length) return;
    final line = _lines[target];
    if (line.text.trim() == '♪') {
      _message('Instrumental notes remain fully highlighted while active.');
      return;
    }
    final existing = line.data['sweepCurve']?.toString() ?? 'linear';
    final initial = existing == 'automation'
        ? LyricSweepCurve.parsePoints(line.data['sweepPoints'])
        : LyricSweepCurve.preset(existing);
    final result = await showDialog<List<List<double>>>(
      context: context,
      builder: (_) => SweepAutomationEditor(
        phrase: line.text, durationMs: line.endMs - line.startMs,
        initialPoints: initial),
    );
    if (result == null || !mounted) return;
    setState(() {
      line.data['sweepCurve'] = 'automation';
      line.data['sweepPoints'] = result;
      _dirty = true;
    });
  }

  double _applyEditorSweep(TimelineLyricLine line, double fraction,
      {String? word}) {
    final mode = line.data['sweepCurve']?.toString() ?? 'linear';
    // Custom syllables apply only to the single WORD they were authored for.
    final target = word ?? line.text.trim();
    return LyricSweepCurve.transform(fraction, mode,
      text: target,
      syllables: line.data['sweepSyllables']?.toString() ?? '',
      weights: LyricSweepCurve.parseWeights(line.data['sweepWeights']),
      points: LyricSweepCurve.parsePoints(line.data['sweepPoints']));
  }

  double _editorVocalProgress(TimelineLyricLine line, int positionMs) {
    final duration = line.endMs - line.startMs;
    if (line.text.trim() == '♪') return positionMs >= line.startMs && positionMs < line.endMs ? 1.0 : 0.0;
    final isAutomation = line.data['sweepCurve'] == 'automation';
    if (isAutomation && duration > 0 && positionMs > line.startMs && positionMs < line.endMs) {
      final progress = LyricSweepCurve.transform(
        (positionMs - line.startMs) / duration, 'automation',
        points: LyricSweepCurve.parsePoints(line.data['sweepPoints']));
      positionMs = line.startMs + (duration * progress).round();
    }
    if (positionMs <= line.startMs) return 0.0;
    if (duration <= 0 || positionMs >= line.endMs) return 1.0;
    final source = line.data['words'];
    if (source is! List || source.isEmpty) {
      return (isAutomation ? (positionMs - line.startMs) / duration : _applyEditorSweep(line, (positionMs - line.startMs) / duration));
    }
    final originalLength = line.originalEndMs - line.originalStartMs;
    int adjusted(int ms) => line.data['wordsEdited'] == true
        ? ms
        : originalLength <= 0
        ? line.startMs + ms - line.originalStartMs
        : line.startMs + ((ms - line.originalStartMs) * duration / originalLength).round();
    final text = line.text.toLowerCase();
    var cursor = 0;
    var previous = 0.0;
    var matches = 0;
    for (final raw in source) {
      if (raw is! Map) continue;
      final token = (raw['text'] ?? '').toString().trim().toLowerCase();
      final wordStart = raw['startMs'];
      final wordEnd = raw['endMs'];
      if (token.isEmpty || wordStart is! num || wordEnd is! num) continue;
      var index = text.indexOf(token, cursor);
      var size = token.length;
      if (index < 0) {
        final simplified = token.replaceAll(RegExp(r"[^a-z0-9']"), '');
        index = text.indexOf(simplified, cursor);
        size = simplified.length;
      }
      if (index < 0 || size == 0) continue;
      matches++;
      final start = adjusted(wordStart.toInt());
      final end = adjusted(wordEnd.toInt());
      if (positionMs < start) return previous;
      if (positionMs <= end) {
        final fraction = ((positionMs - start) / (end - start).clamp(1, 100000000)).clamp(0.0, 1.0);
        return ((index + size * (isAutomation ? fraction : _applyEditorSweep(line, fraction,
          word: text.substring(index, index + size)))) / text.length).clamp(0.0, 1.0);
      }
      cursor = index + size;
      previous = cursor / text.length;
    }
    if (matches == 0) {
      return (isAutomation ? (positionMs - line.startMs) / duration : _applyEditorSweep(line, (positionMs - line.startMs) / duration));
    }
    // Once the final word ends, the complete phrase must be highlighted.
    return 1.0;
  }

  Widget _editorKaraokePreview() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF090A0F),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
      child: ValueListenableBuilder<int>(
        valueListenable: _playhead,
        builder: (context, positionMs, _) {
          if (_lines.isEmpty) {
            return const Center(
              child: Text('No synchronized lyrics', style: TextStyle(color: Colors.white38)),
            );
          }
          var active = -1;
          for (var i = _lines.length - 1; i >= 0; i--) {
            if (positionMs >= _lines[i].startMs) {
              active = i;
              break;
            }
          }
          if (active < 0) active = 0;

          Widget lineAt(int index, {required bool prominent}) {
            if (index < 0 || index >= _lines.length) {
              return const SizedBox.shrink();
            }
            final line = _lines[index];
            if (!prominent) {
              return Text(
                line.text,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w400,
                  height: 1.15, color: Colors.white38,
                ),
              );
            }
            // Use one text layout for the whole phrase. The previous
            // overlay clipped a second, independently laid-out Text widget;
            // its highlight could disappear or shift on wrapped lines.
            final progress = _editorVocalProgress(line, positionMs);
            final boundary = line.text.length * progress;
            final spans = <TextSpan>[];
            for (var i = 0; i < line.text.length; i++) {
              final fraction = (boundary - i).clamp(0.0, 1.0);
              spans.add(TextSpan(
                text: line.text[i],
                style: TextStyle(
                  color: Color.lerp(Colors.white38, Colors.white, fraction),
                ),
              ));
            }
            return Text.rich(
              TextSpan(children: spans),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.w800,
                height: 1.15,
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, size) {
              final short = size.maxHeight < 180;
              return Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Flexible(child: Center(child: lineAt(active - 1, prominent: false))),
                  Flexible(flex: short ? 2 : 3,
                    child: Center(child: lineAt(active, prominent: true))),
                  Flexible(child: Center(child: lineAt(active + 1, prominent: false))),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _inspector() {
    if (MediaQuery.sizeOf(context).width < 600) {
      final index = _selectedIndex;
      if (index == null || index >= _lines.length) {
        return Container(
          height: 48,
          color: const Color(0xFF11131A),
          alignment: Alignment.center,
          child: const Text(
            'Select a lyric segment',
            style: TextStyle(color: Color(0xFFB2B9C8)),
          ),
        );
      }
      final line = _lines[index];
      return Container(
        color: const Color(0xFF11131A),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              line.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              'START ${line.startMs} ms    END ${line.endMs} ms    ORIGINAL ${line.originalStartMs} ms',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFADB4C4), fontSize: 11),
            ),
          ],
        ),
      );
    }
    return _desktopInspector();
  }

  Widget _desktopInspector() {
    final index = _selectedIndex;

    if (index == null || index >= _lines.length) {
      return Container(
        height: 70,

        color: const Color(0xFF161924),

        alignment: Alignment.center,

        child: const Text(
          'Select a lyric segment',

          style: TextStyle(color: Colors.white38),
        ),
      );
    }

    final line = _lines[index];

    return Container(
      height: 76,

      color: const Color(0xFF161924),

      padding: const EdgeInsets.symmetric(horizontal: 20),

      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                if (_selectedIndices.length > 1)
                  Container(
                    margin: const EdgeInsets.only(right: 10),

                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,

                      vertical: 4,
                    ),

                    decoration: BoxDecoration(
                      color: const Color(0xFF4B3F72),

                      borderRadius: BorderRadius.circular(8),
                    ),

                    child: Text(
                      '${_selectedIndices.length} clips',

                      style: const TextStyle(
                        color: Color(0xFFE0D7FF),

                        fontSize: 11,

                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),

                Expanded(
                  child: Text(
                    line.text,

                    maxLines: 2,

                    overflow: TextOverflow.ellipsis,

                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),

          _InspectorValue(title: 'START', value: '${line.startMs} ms'),

          const SizedBox(width: 20),

          _InspectorValue(title: 'END', value: '${line.endMs} ms'),

          const SizedBox(width: 20),

          _InspectorValue(title: 'CTC', value: '${line.originalStartMs} ms'),
        ],
      ),
    );
  }
}

class _DragLineSnapshot {
  final int startMs;

  final int endMs;

  final List<_WordTimingSnapshot> words;

  const _DragLineSnapshot({
    required this.startMs,
    required this.endMs,
    required this.words,
  });
}

class _WordTimingSnapshot {
  final Map<dynamic, dynamic> word;

  final int? startMs;

  final int? endMs;

  const _WordTimingSnapshot({
    required this.word,
    required this.startMs,
    required this.endMs,
  });
}

class _InspectorValue extends StatelessWidget {
  final String title;

  final String value;

  const _InspectorValue({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,

      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        Text(
          title,

          style: const TextStyle(
            color: Colors.white38,

            fontSize: 10,

            fontWeight: FontWeight.w700,
          ),
        ),

        const SizedBox(height: 2),

        Text(
          value,

          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _EditorLyricSweepClipper extends CustomClipper<Path> {
  const _EditorLyricSweepClipper({
    required this.text,
    required this.progress,
    required this.direction,
    required this.textScaler,
  });

  final String text;
  final double progress;
  final TextDirection direction;
  final TextScaler textScaler;

  @override
  Path getClip(Size size) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(
        fontSize: 28, fontWeight: FontWeight.w800, height: 1.15,
      )),
      textAlign: TextAlign.center,
      textDirection: direction,
      textScaler: textScaler,
      maxLines: 3,
      ellipsis: '…',
    )..layout(maxWidth: size.width);
    final bound = (text.length * progress.clamp(0.0, 1.0)).clamp(0.0, text.length.toDouble());
    final count = bound.floor();
    final partial = bound - count;
    final offsetY = (size.height - painter.height) / 2;
    final path = Path();
    void box(TextBox b, double amount) {
      final width = b.right - b.left;
      if (width <= 0 || amount <= 0) return;
      final left = direction == TextDirection.rtl
          ? b.right - width * amount : b.left;
      path.addRect(Rect.fromLTRB(
        left, b.top + offsetY,
        left + width * amount, b.bottom + offsetY,
      ).inflate(.2));
    }
    for (var i = 0; i < count; i++) {
      if (text[i].trim().isEmpty) continue;
      for (final b in painter.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1))) {
        box(b, 1.0);
      }
    }
    if (partial > 0 && count < text.length && text[count].trim().isNotEmpty) {
      for (final b in painter.getBoxesForSelection(
          TextSelection(baseOffset: count, extentOffset: count + 1))) {
        box(b, partial);
      }
    }
    painter.dispose();
    return path;
  }

  @override
  bool shouldReclip(covariant _EditorLyricSweepClipper old) =>
      old.progress != progress || old.text != text ||
      old.direction != direction || old.textScaler != textScaler;
}
