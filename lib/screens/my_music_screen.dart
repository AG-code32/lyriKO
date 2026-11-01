import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../services/lyriko_server_client.dart';
import '../services/synced_lyrics_service.dart';
import '../services/lyric_sweep_curve.dart';
import 'lyrics_edit_screen.dart';

// Matches Lyrics Timeline's _editorVocalProgress algorithm. In particular,
// after the final timed WORD, the entire phrase is lit immediately; it must
// NOT interpolate an artificial final anchor to the end of the lyric block.
// The same progress is sent to native PiP and drawn in MY MUSIC.
// Mirrors Lyrics Timeline's _editorVocalProgress, including its saved
// wordsEdited flag and automation. No player-specific timing interpolation.
double _editorMatchedSweep(SyncedLyricLine line, int positionMs) {
  final duration = line.endMs - line.startMs;
  if (line.text.trim() == '♪') {
    return positionMs >= line.startMs && positionMs < line.endMs ? 1.0 : 0.0;
  }
  final isAutomation = line.sweepCurve == 'automation';
  double applyCurve(double fraction, {String? word}) =>
      LyricSweepCurve.transform(fraction, line.sweepCurve,
        text: word ?? line.text.trim(),
        syllables: line.sweepSyllables?.toString() ?? '',
        weights: LyricSweepCurve.parseWeights(line.sweepWeights),
        points: LyricSweepCurve.parsePoints(line.sweepPoints));
  if (isAutomation && duration > 0 &&
      positionMs > line.startMs && positionMs < line.endMs) {
    final progress = LyricSweepCurve.transform(
        (positionMs - line.startMs) / duration, 'automation',
        points: LyricSweepCurve.parsePoints(line.sweepPoints));
    positionMs = line.startMs + (duration * progress).round();
  }
  if (positionMs <= line.startMs) return 0.0;
  if (duration <= 0 || positionMs >= line.endMs) return 1.0;
  double fallback() => isAutomation
      ? (positionMs - line.startMs) / duration
      : applyCurve((positionMs - line.startMs) / duration);
  if (line.words.isEmpty) return fallback().clamp(0.0, 1.0);
  final originalLength = line.originalEndMs - line.originalStartMs;
  int adjusted(int ms) => line.wordsEdited
      ? ms
      : originalLength <= 0
          ? line.startMs + ms - line.originalStartMs
          : line.startMs +
              ((ms - line.originalStartMs) * duration / originalLength).round();
  final text = line.text.toLowerCase();
  var cursor = 0;
  var previous = 0.0;
  var matches = 0;
  for (final word in line.words) {
    final token = word.text.trim().toLowerCase();
    if (token.isEmpty) continue;
    var index = text.indexOf(token, cursor);
    var size = token.length;
    if (index < 0) {
      final simplified = token.replaceAll(RegExp(r"[^a-z0-9']"), '');
      index = text.indexOf(simplified, cursor);
      size = simplified.length;
    }
    if (index < 0 || size == 0) continue;
    matches++;
    final start = adjusted(word.startMs);
    final end = adjusted(word.endMs);
    if (positionMs < start) return previous;
    if (positionMs <= end) {
      final fraction = ((positionMs - start) /
          (end - start).clamp(1, 100000000)).clamp(0.0, 1.0);
      return ((index + size * (isAutomation ? fraction :
          applyCurve(fraction, word: text.substring(index, index + size)))) /
          text.length).clamp(0.0, 1.0);
    }
    cursor = index + size;
    previous = cursor / text.length;
  }
  if (matches == 0) return fallback().clamp(0.0, 1.0);
  return 1.0;
}

class MyMusicScreen extends StatefulWidget {
  const MyMusicScreen({super.key, required this.songsListenable, this.onExit, this.nowPlaying});

  final VoidCallback? onExit;
  final ValueNotifier<MusicPlaybackSnapshot?>? nowPlaying;

  static Future<void> preloadCatalog() => _MyMusicScreenState.preloadCatalog();
  static void Function(String)? playbackCommand;
  static VoidCallback? showLyricsCommand;


  final ValueListenable<List<SyncedLyricsSong>> songsListenable;

  @override
  State<MyMusicScreen> createState() => _MyMusicScreenState();
}

class MusicPlaybackSnapshot {
  final String title, artist;
  final Duration position, duration;
  final bool playing;
  final DateTime observedAt;
  MusicPlaybackSnapshot(this.title, this.artist, this.position, this.duration, this.playing)
      : observedAt = DateTime.now();

  Duration get displayedPosition {
    if (!playing) return position;
    final elapsed = DateTime.now().difference(observedAt);
    final estimate = position + (elapsed.isNegative ? Duration.zero : elapsed);
    return duration > Duration.zero && estimate > duration ? duration : estimate;
  }
}

class _MyMusicScreenState extends State<MyMusicScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _mediaChannel = MethodChannel('lyriko/media_controls');
  static const _pipChannel = MethodChannel('lyriko/ios_pip_prototype');
  Timer? _pipSyncTimer;
  String? _pipCachedSongId;
  List<Map<String, dynamic>>? _pipCachedLines;
  bool _pipActive = false;
  bool _pipOpening = false;
  // Temporary user-visible native PiP lifecycle indicator.
  String _pipVisualStatus = 'Checking';
  bool _pipHadTimeout = false;

  bool get _pipIsTransitioning => _pipOpening ||
      _pipVisualStatus == 'Preparing' ||
      _pipVisualStatus == 'Closing' ||
      _pipVisualStatus == 'Checking';

  void _applyNativePipState(Map<String, dynamic> state) {
    if (!mounted) return;
    final active = state['active'] == true;
    final opening = state['opening'] == true;
    final stopping = state['stopping'] == true || state['restorationRequested'] == true;
    final nativeEvent = (state['lastEvent'] ?? '').toString();
    if (nativeEvent.contains('timeout') || nativeEvent.contains('failed')) {
      _pipHadTimeout = true;
    }
    final next = stopping
        ? 'Closing'
        : opening
            ? 'Preparing'
            : active
                ? 'Active'
                : _pipHadTimeout
                    ? 'Retry'
                    : 'Ready';
    if (_pipVisualStatus != next || _pipActive != active) {
      setState(() {
        _pipVisualStatus = next;
        _pipActive = active;
      });
    }
    if (!active) _pipSyncTimer?.cancel();
  }
  // TEMPORARY: player-level PiP diagnostics. Remove after validation.
  final List<String> _pipDiagnosticEvents = <String>[];
  Timer? _pipDiagnosticPoll;
  DateTime? _pipDiagnosticLastTick;
  String _pipDiagnosticLastState = '';
  int _pipDiagnosticAttempts = 0;
  bool _pipDiagnosticPolling = false;

  void _pipDiagnosticTrace(String event) {
    if (!Platform.isIOS) return;
    final row = '${DateTime.now().toIso8601String()} | $event';
    _pipDiagnosticEvents.add(row);
    if (_pipDiagnosticEvents.length > 350) {
      _pipDiagnosticEvents.removeRange(0, _pipDiagnosticEvents.length - 350);
    }
    debugPrint('LYRIKO_MUSIC_PIP_DIAG $row');
  }

  // Separate bounded native snapshot: survives Flutter suspension in the native buffer.
  Map<String, dynamic>? _pipNativeDiagnostics;
  Future<void>? _pipNativeDiagnosticsFetch;

  Future<void> _fetchNativePiPDiagnostics() {
    final pending = _pipNativeDiagnosticsFetch;
    if (pending != null) return pending;
    final fetch = _readNativePiPDiagnostics();
    _pipNativeDiagnosticsFetch = fetch;
    return fetch.whenComplete(() => _pipNativeDiagnosticsFetch = null);
  }

  Future<void> _readNativePiPDiagnostics() async {
    try {
      final diagnostics = await _pipChannel.invokeMapMethod<String, dynamic>(
        'diagnosticsAVPlayerV2',
      );
      if (diagnostics != null) _pipNativeDiagnostics = diagnostics;
    } catch (error) {
      _pipDiagnosticTrace('NATIVE_EVENTS_READ_ERROR $error');
    }
  }

  Future<void> _pipDiagnosticSnapshot() async {
    if (!Platform.isIOS || _pipDiagnosticPolling) return;
    _pipDiagnosticPolling = true;
    try {
      final now = DateTime.now();
      final previous = _pipDiagnosticLastTick;
      _pipDiagnosticLastTick = now;
      if (previous != null) {
        final gap = now.difference(previous).inMilliseconds;
        if (gap > 1800) _pipDiagnosticTrace('TIMER_GAP ${gap}ms');
      }
      final state = await _pipChannel.invokeMapMethod<String, dynamic>(
        'stateAVPlayerV2',
      );
      if (state != null) _applyNativePipState(state);
      final snapshot = state.toString();
      if (snapshot != _pipDiagnosticLastState) {
        _pipDiagnosticLastState = snapshot;
        _pipDiagnosticTrace('NATIVE_STATE $snapshot');
      }
    } catch (error) {
      _pipDiagnosticTrace('POLL_ERROR $error');
    } finally {
      await _fetchNativePiPDiagnostics();
      _pipDiagnosticPolling = false;
    }
  }

  String _pipDiagnosticReport() => <String>[
    'LyriKO MY MUSIC PiP diagnosis',
    'Created: ${DateTime.now().toIso8601String()}',
    'Track: ${_playing?.title ?? "none"}',
    'Flutter: active=$_pipActive opening=$_pipOpening',
    'Audio: playing=${_player.playing} positionMs=${_player.position.inMilliseconds}',
    'Events: ${_pipDiagnosticEvents.length}',
    '---',
    ..._pipDiagnosticEvents,
    '--- Native PiP events (native timestamps; reads do not clear) ---',
    if (_pipNativeDiagnostics == null) 'Native instrumentation: not retrieved',
    if (_pipNativeDiagnostics != null) ...[
      'Native metadata: ${{..._pipNativeDiagnostics!}..remove("events")}',
      for (final event in (_pipNativeDiagnostics!['events'] as List? ?? const []))
        '$event',
    ],
  ].join('\n');

  void _showMusicPipDiagnostics() {
    _pipDiagnosticTrace('REPORT_OPEN');
    unawaited(_pipDiagnosticSnapshot());
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Temporary PiP diagnostics'),
        content: SizedBox(
          width: 560,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(_pipDiagnosticReport(),
                style: const TextStyle(fontSize: 11)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _pipDiagnosticEvents.clear();
              _pipDiagnosticLastState = '';
              _pipDiagnosticTrace('REPORT_RESET');
              Navigator.pop(dialogContext);
            },
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () async {
              await _fetchNativePiPDiagnostics();
              await Clipboard.setData(
                ClipboardData(text: _pipDiagnosticReport()),
              );
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Copy report'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // The native PiP owns its clock between updates, including while Flutter is
  // suspended. The audio player remains the sole playback authority.
  int? _pipLastSyncedPositionMs;
  DateTime? _pipLastSyncAt;
  bool? _pipLastPlaying;
  bool _pipSyncInFlight = false;

  Future<void> _syncMusicPiP() async {
    final song = _playing;
    if (!Platform.isIOS || !_pipActive || song == null || _pipSyncInFlight) {
      return;
    }
    final now = DateTime.now();
    final positionMs = _karaokePosition.value;
    final playing = _player.playing;
    final elapsedMs = _pipLastSyncAt == null
        ? 0
        : now.difference(_pipLastSyncAt!).inMilliseconds;
    final expected = (_pipLastSyncedPositionMs ?? positionMs) +
        ((_pipLastPlaying ?? playing) ? elapsedMs : 0);
    // A seek is a discontinuity, not ordinary time progression. In particular,
    // never correct AVPlayer for small clock drift on each Flutter timer tick.
    final seekRequested = _pipLastSyncedPositionMs != null &&
        (positionMs - expected).abs() > 2200;
    _pipSyncInFlight = true;
    try {
      await _pipChannel.invokeMethod<bool>('updateAVPlayerV2',
          <String, dynamic>{
            'playing': playing,
            if (seekRequested) 'positionMs': positionMs,
            if (seekRequested) 'seekRequested': true,
          });
      if (seekRequested) {
        _pipDiagnosticTrace('EXPLICIT_SEEK positionMs=$positionMs');
      }
      _pipLastSyncedPositionMs = positionMs;
      _pipLastSyncAt = now;
      _pipLastPlaying = playing;
    } catch (error) {
      _pipDiagnosticTrace('SYNC_ERROR $error');
      debugPrint('MY MUSIC PiP sync: $error');
    } finally {
      _pipSyncInFlight = false;
    }
  }

  // The floating player and the in-app player use the SAME editor-derived
  // progression function; no independent PiP timing interpolation.
  double _musicPiPSweep(SyncedLyricLine line, int positionMs) =>
      _editorMatchedSweep(line, positionMs);

  Map<String, dynamic> _musicPiPPayload(SyncedLyricsSong song) {
    if (_pipCachedSongId != song.songId || _pipCachedLines == null) {
      _pipCachedSongId = song.songId;
      _pipCachedLines = song.lines.map((line) => <String, dynamic>{
        'text': line.text,
        'startMs': line.startMs,
        'endMs': line.endMs,
        'sweepSamples': List<double>.generate(61, (i) => _musicPiPSweep(
          line, line.startMs + ((line.endMs - line.startMs) * i / 60).round())),
      }).toList();
    }
    return {
    'title': song.title,
    'artist': song.artist,
    'positionMs': _karaokePosition.value,
    'playing': _player.playing,
    'background': 10,
    'lines': _pipCachedLines,
    };
  }

  Future<void> _prewarmMusicPiP(SyncedLyricsSong song) async {
    try {
      final payload = _musicPiPPayload(song);
      final ready = await _pipChannel.invokeMethod<bool>(
        'prepareAVPlayerV2', payload,
      );
      _pipDiagnosticTrace('PREWARM_COMPLETED ready=$ready songId=${song.songId}');
    } catch (error) {
      _pipDiagnosticTrace('PREWARM_ERROR $error');
      // A failed prewarm must not interrupt music playback. The button still
      // has its normal preparation path for an explicit retry.
    }
  }

  Future<void> _toggleMusicPiP() async {
    if (!Platform.isIOS || _pipOpening) return;
    _pipDiagnosticAttempts++;
    _pipDiagnosticTrace('TOGGLE #$_pipDiagnosticAttempts flutterActive=$_pipActive');
    setState(() { _pipOpening = true; _pipVisualStatus = 'Preparing'; });
    try {
      // Native AVKit state is authoritative, not a cached Flutter boolean.
      final before = await _pipChannel
          .invokeMapMethod<String, dynamic>('stateAVPlayerV2');
      _pipDiagnosticTrace('PRE_TOGGLE_NATIVE_STATE $before');
      if (before == null) {
        throw PlatformException(code: 'PIP_NO_STATE',
            message: 'iOS did not return its PiP controller state');
      }
      final active = before['active'] == true;
      final opening = before['opening'] == true;
      final stopping = before['stopping'] == true;
      if (mounted && _pipActive != active) {
        setState(() => _pipActive = active);
        _pipDiagnosticTrace('FLUTTER_STATE_CORRECTED active=$active');
      }
      if (opening || stopping) {
        _pipDiagnosticTrace('BLOCKED_NATIVE_TRANSITION');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('iOS is still changing PiP state')));
        return;
      }
      if (active) {
        if (mounted) setState(() => _pipVisualStatus = 'Closing');
        _pipDiagnosticTrace('STOP_REQUEST');
        await _pipChannel.invokeMethod('stopAVPlayerV2');
        _pipDiagnosticTrace('STOP_RETURNED');
        _pipSyncTimer?.cancel();
        // The native stop is asynchronous; do not fake a completed stop.
        await _refreshMusicPiPState();
      } else {
        final song = _playing;
        if (song == null) return;
        _pipDiagnosticTrace('UPDATE_PAYLOAD_START');
        await _pipChannel.invokeMethod<bool>(
            'updateAVPlayerV2', _musicPiPPayload(song));
        _pipDiagnosticTrace('UPDATE_PAYLOAD_OK');
        if (mounted) setState(() => _pipVisualStatus = 'Preparing');
        _pipDiagnosticTrace('START_REQUEST');
        final started = await _pipChannel
            .invokeMethod<bool>('startAVPlayerV2');
        _pipDiagnosticTrace('START_RETURNED $started');
        if (started != true) {
          throw PlatformException(code: 'PIP_NOT_STARTED',
              message: 'iOS did not confirm PiP startup');
        }
        if (!mounted) return;
        final confirmed = await _pipChannel
            .invokeMapMethod<String, dynamic>('stateAVPlayerV2');
        _pipDiagnosticTrace('CONFIRMED_STATE $confirmed');
        if (confirmed?['active'] != true) {
          throw PlatformException(code: 'PIP_NOT_ACTIVE',
              message: 'iOS has not activated the floating window');
        }
        _pipHadTimeout = false;
        setState(() { _pipActive = true; _pipVisualStatus = 'Active'; });
        _pipLastSyncedPositionMs = _karaokePosition.value;
        _pipLastSyncAt = DateTime.now();
        _pipLastPlaying = _player.playing;
        _pipSyncTimer?.cancel();
        _pipSyncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          unawaited(_syncMusicPiP());
        });
      }
    } on PlatformException catch (error) {
      _pipHadTimeout = true;
      if (mounted) setState(() => _pipVisualStatus = 'Retry');
      _pipDiagnosticTrace('TOGGLE_ERROR ${error.code}: ${error.message}');
      try {
        final failure = await _pipChannel
            .invokeMapMethod<String, dynamic>('stateAVPlayerV2');
        _pipDiagnosticTrace('ERROR_NATIVE_STATE $failure');
      } catch (snapshotError) {
        _pipDiagnosticTrace('ERROR_STATE_FAILED $snapshotError');
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PiP: ${error.message ?? error.code}')));
    } finally {
      _pipDiagnosticTrace('TOGGLE_FINISHED');
      if (mounted) {
        setState(() => _pipOpening = false);
        unawaited(_pipDiagnosticSnapshot());
      }
    }
  }

  Future<void> _refreshMusicPiPState() async {
    if (!Platform.isIOS) return;
    try {
      final state = await _pipChannel.invokeMapMethod<String, dynamic>('stateAVPlayerV2');
      if (!mounted || state == null) return;
      final active = state['active'] == true;
      _applyNativePipState(state);
    } catch (error) {
      _pipDiagnosticTrace('RESUME_STATE_ERROR $error');
      debugPrint('MY MUSIC PiP state: $error');
    }
  }

  Timer? _browseTimer;
  bool _browsingLyrics = false;
  final ItemScrollController _lyricsScroll = ItemScrollController();
  int _lastMediaSecond = -1;
  String? _lastMediaSong;

  void _sendPlaybackState({bool force = false}) {
    final song = _playing;
    if (song == null) return;
    widget.nowPlaying?.value = MusicPlaybackSnapshot(
      song.title, song.artist, Duration(milliseconds: _positionMs),
      _duration, _isPlaying);
    if (!Platform.isIOS) return;
    final second = _positionMs ~/ 1000;
    if (!force && second == _lastMediaSecond && _lastMediaSong == song.songId) return;
    _lastMediaSecond = second;
    _lastMediaSong = song.songId;
    unawaited(_mediaChannel.invokeMethod<void>('update', <String, dynamic>{
      'title': song.title, 'artist': song.artist,
      'position': _positionMs / 1000.0,
      'duration': (_duration.inMilliseconds > 0 ? _duration.inMilliseconds : song.durationMs) / 1000.0,
      'playing': _isPlaying,
    }).catchError((Object error) { debugPrint('Media controls: $error'); }));
  }

  // Unlike the former five fixed slots, this is a real pixel-scrolling list.
  // Dragging NEVER seeks audio. Following resumes two seconds after the fling ends.
  bool _onLyricsScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification && notification.dragDetails != null) {
      _browseTimer?.cancel();
      _browsingLyrics = true;
    } else if (notification is ScrollEndNotification && _browsingLyrics) {
      _browseTimer?.cancel();
      _browseTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        _browsingLyrics = false;
        _lastActive = -1;
        _scrollActive();
      });
    }
    return false;
  }

  static final Map<String, Map<String, Map<String, dynamic>>> _indexes = {};
  static final Map<String, Future<Map<String, Map<String, dynamic>>>> _pending = {};
  static final Map<String, Map<String, String>> _metadataOverrides = {};

  static String _identity(String artist, String title) =>
      '${artist.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), "")}::${title.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), "")}';

  static Future<Map<String, Map<String, dynamic>>> _catalog({bool force = false}) async {
    final client = LyrikoServerClient();
    final base = await client.getBaseUrl();
    if (base.isEmpty) {
      throw StateError('Configure server URL in Settings.');
    }
    if (!force && _indexes.containsKey(base)) return _indexes[base]!;
    if (!force && _pending.containsKey(base)) return _pending[base]!;

    final task = () async {
      final rows = await client.songs();
      final map = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        map[_identity(row['artist']?.toString() ?? '', row['title']?.toString() ?? '')] = row;
        map['id::$id'] = row;
      }
      _indexes[base] = map;
      return map;
    }();
    _pending[base] = task;
    try {
      return await task;
    } finally {
      _pending.remove(base);
    }
  }

  static Future<void> preloadCatalog() async {
    try {
      await _catalog();
    } catch (_) {}
  }

  final _server = LyrikoServerClient();
  final ValueNotifier<int> _karaokePosition = ValueNotifier<int>(0);
  late final Ticker _karaokeTicker;
  final Stopwatch _karaokeClock = Stopwatch();
  int _karaokeAnchorMs = 0;

  void _syncKaraokeClock(int positionMs) {
    final predicted = _karaokeAnchorMs + _karaokeClock.elapsedMilliseconds;
    final drift = positionMs - predicted;
    if (!_player.playing || !_karaokeClock.isRunning || drift.abs() > 90) {
      _karaokeAnchorMs = positionMs;
      _karaokeClock.reset();
    } else {
      // Small timestamp jitter should not make the highlight jump.
      _karaokeAnchorMs += (drift * 0.18).round();
    }
    if (_player.playing) {
      if (!_karaokeClock.isRunning) _karaokeClock.start();
    } else {
      _karaokeClock.stop();
      _karaokeAnchorMs = positionMs;
      _karaokeClock.reset();
    }
    if (!_player.playing) _karaokePosition.value = positionMs;
  }

  void _tickKaraoke(Duration _) {
    if (!_player.playing) return;
    final position = _karaokeAnchorMs + _karaokeClock.elapsedMilliseconds;
    final end = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds : (_playing?.durationMs ?? position);
    final now = position.clamp(0, math.max(0, end)).toInt();
    if (_karaokePosition.value != now) _karaokePosition.value = now;
  }

  final _player = AudioPlayer();
  final _search = TextEditingController();
  final List<StreamSubscription<dynamic>> _subs = [];
  final FocusNode _focusNode = FocusNode();

  List<SyncedLyricsSong> _songs = [];
  // Saved lyric edits stay local to this screen; songsListenable is read-only.
  final Map<String, SyncedLyricsSong> _editedLyrics = {};
  Map<String, Map<String, dynamic>> _remoteIndex = {};

  String? _selectedArtist;
  SyncedLyricsSong? _playing;
  bool _loading = false;
  bool _opening = false;
  bool _repeatOne = false;
  bool _shuffle = false;
  String? _error;
  int _positionMs = 0;
  Duration _duration = Duration.zero;
  double? _dragSeconds;
  bool _isPlaying = false;
  bool _showLyrics = true;
  double? _edgeSwipeStartX;

  int _lastActive = -1;
  double _volume = 1.0;

  @override
  void initState() {
    super.initState();
    _karaokeTicker = createTicker(_tickKaraoke)..start();
    WidgetsBinding.instance.addObserver(this);
    _subs.add(_player.positionStream.listen((position) {
      if (!mounted) return;
      _syncKaraokeClock(position.inMilliseconds);
      setState(() => _positionMs = position.inMilliseconds);
      _scrollActive();
      _sendPlaybackState();
    }));
    _subs.add(_player.durationStream.listen((value) {
      if (mounted) { setState(() => _duration = value ?? Duration.zero); _sendPlaybackState(force: true); }
    }));
    _subs.add(_player.playerStateStream.listen((state) async {
      if (!mounted) return;
      _syncKaraokeClock(_player.position.inMilliseconds);
      setState(() => _isPlaying = state.playing);
      _sendPlaybackState(force: true);
      if (state.processingState == ProcessingState.completed) {
        if (_repeatOne) {
          await _player.seek(Duration.zero);
          await _player.play();
        } else {
          _next();
        }
      }
    }));
    _songs = _displaySongs();
    widget.songsListenable.addListener(_onHomeLibrary);
    if (Platform.isIOS) {
      _mediaChannel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'toggle': await _togglePlayPause(); break;
          case 'play': if (!_player.playing) await _player.play(); break;
          case 'pause': await _player.pause(); break;
          case 'next': _next(); break;
          case 'previous': _previous(); break;
        }
      });
    }
    MyMusicScreen.showLyricsCommand = () {
      if (!mounted || _playing == null) return;
      setState(() => _showLyrics = true);
      _lastActive = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _scrollActive(); });
    };
    MyMusicScreen.playbackCommand = (command) {
      if (!mounted) return;
      switch (command) {
        case 'toggle': _togglePlayPause(); break;
        case 'next': _next(); break;
        case 'previous': _previous(); break;
      }
    };
    if (Platform.isIOS) {
      _pipDiagnosticTrace('PLAYER_INIT');
      _pipDiagnosticPoll = Timer.periodic(
        const Duration(milliseconds: 600),
        (_) => unawaited(_pipDiagnosticSnapshot()),
      );
      unawaited(_pipDiagnosticSnapshot());
    }
    _loadSavedMetadata();
    _warmIndex();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _pipDiagnosticTrace('APP_LIFECYCLE $state');
    if (state == AppLifecycleState.resumed) {
      unawaited(_pipDiagnosticSnapshot());
    }
    if (state != AppLifecycleState.resumed || !mounted || _playing == null) return;
    // Refresh the Flutter mini player from the actual native player on resume.
    setState(() {
      _positionMs = _player.position.inMilliseconds;
      _isPlaying = _player.playing;
    });
    _sendPlaybackState(force: true);
    unawaited(_refreshMusicPiPState());
    _lastActive = -1;
    _scrollActive();
  }

  static List<SyncedLyricsSong> _sorted(List<SyncedLyricsSong> input) {
    // Legacy and ID-based JSON caches may both contain the same recording.
    // Never expose both to the playlist: duplicates break skip next/previous.
    final unique = <String, SyncedLyricsSong>{};
    for (final song in input) {
      final key = _identity(song.artist, song.title);
      unique.putIfAbsent(key, () => song);
    }
    final result = unique.values.toList();
    result.sort((a, b) {
      final artist = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
      return artist != 0 ? artist : a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return result;
  }

  Future<File> _metadataCacheFile() async {
    final folder = await getApplicationSupportDirectory();
    return File('${folder.path}/lyriko_my_music_metadata.json');
  }

  Future<void> _loadSavedMetadata() async {
    try {
      final file = await _metadataCacheFile();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      for (final item in raw.entries) {
        if (item.value is! Map) continue;
        final value = Map<String, dynamic>.from(item.value as Map);
        _metadataOverrides[item.key.toString()] = {
          if (value['title'] != null) 'title': value['title'].toString(),
          if (value['artist'] != null) 'artist': value['artist'].toString(),
        };
      }
      _onHomeLibrary();
    } catch (_) {
      // Metadata is also available from Windows; a corrupt local cache must
      // not prevent loading the music library.
    }
  }

  Future<void> _saveMetadataOverrides() async {
    final file = await _metadataCacheFile();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(_metadataOverrides), flush: true);
    await temp.rename(file.path);
  }

  SyncedLyricsSong _applyOverride(SyncedLyricsSong song) {
    final info = _metadataOverrides[song.songId];
    if (info == null) return song;
    return SyncedLyricsSong(
      songId: song.songId,
      title: info['title'] ?? song.title,
      artist: info['artist'] ?? song.artist,
      jsonPath: song.jsonPath, audioPath: song.audioPath,
      lines: song.lines, durationMs: song.durationMs,
      modifiedAt: song.modifiedAt,
    );
  }

  // Local lyric JSONs can contain a track number in the artist field.
  // Correct only when the server has exactly one matching title; never guess.
  String _normalizedTitle(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  bool _invalidArtist(String value) {
    final artist = value.trim();
    return artist.isEmpty ||
        RegExp(r'^\d{1,3}$').hasMatch(artist) ||
        artist.toLowerCase() == 'unknown artist';
  }

  SyncedLyricsSong _canonicalSong(SyncedLyricsSong song) {
    final key = _normalizedTitle(song.title);
    if (key.isEmpty) return song;
    Map<String, dynamic>? matched = _remoteIndex['id::${song.songId}'];
    if (matched == null) {
      final candidates = <String, Map<String, dynamic>>{};
      for (final row in _remoteIndex.values) {
        if (_normalizedTitle(row['title']?.toString() ?? '') != key) continue;
        final id = row['id']?.toString() ?? '';
        if (id.isNotEmpty) candidates[id] = row;
      }
      if (candidates.length == 1) matched = candidates.values.single;
    }
    if (matched == null) return song;
    final serverArtist = matched['artist']?.toString().trim() ?? '';
    if (_invalidArtist(serverArtist)) return song;
    // Server is authoritative for artist; ignore stale local overrides.
    if (serverArtist == song.artist) return song;
    return SyncedLyricsSong(
      songId: song.songId,
      title: song.title,
      artist: serverArtist,
      jsonPath: song.jsonPath,
      audioPath: song.audioPath,
      lines: song.lines,
      durationMs: song.durationMs,
      modifiedAt: song.modifiedAt,
    );
  }

  List<SyncedLyricsSong> _displaySongs() => _sorted(
    widget.songsListenable.value.map((song) {
      final edited = _editedLyrics[song.jsonPath];
      if (edited == null) return song;
      // Preserve current catalog metadata, but retain freshly saved timings.
      return SyncedLyricsSong(
        songId: song.songId,
        title: song.title,
        artist: song.artist,
        jsonPath: song.jsonPath,
        audioPath: song.audioPath,
        lines: edited.lines,
        durationMs: edited.durationMs,
        modifiedAt: edited.modifiedAt,
      );
    }).map(_applyOverride).map(_canonicalSong).toList());

  void _onHomeLibrary() {
    if (!mounted) return;
    setState(() => _songs = _displaySongs());
  }

  Future<void> _updateLocalSongMetadata(SyncedLyricsSong song, Map<String, dynamic> payload) async {
    // Keep already-downloaded lyrics consistent after a successful server write.
    // Never attempt to modify Flutter's read-only bundled assets.
    if (song.jsonPath.startsWith('assets/')) return;
    final file = File(song.jsonPath);
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return;
    final doc = Map<String, dynamic>.from(json);
    for (final field in ['title', 'artist', 'album', 'year', 'genre', 'trackNumber']) {
      if (payload.containsKey(field)) doc[field] = payload[field];
    }
    final temp = File('${file.path}.metadata.tmp');
    await temp.writeAsString(jsonEncode(doc), flush: true);
    // Avoid leaving a truncated JSON when disk writes fail.
    await temp.rename(file.path);
  }

  Future<void> _warmIndex({bool force = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final index = await _catalog(force: force);
      if (mounted) {
        setState(() {
          _remoteIndex = index;
          _songs = _displaySongs();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Server song index unavailable: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async => _warmIndex(force: true);

  /// Reload the saved lyrics JSON without touching the AudioPlayer.
  /// Keep the canonical artist/title, server song ID and audio path from the
  /// existing library entry: only lyric lines and duration are refreshed.
  Future<void> _reloadEditedLyrics(SyncedLyricsSong editedSong) async {
    final lyricsService = SyncedLyricsService();
    final fresh = await lyricsService.loadSong(editedSong.jsonPath);
    final playerLines = fresh.lines;
    if (!mounted) return;

    SyncedLyricsSong refreshed(SyncedLyricsSong current) => SyncedLyricsSong(
      songId: current.songId,
      title: current.title,
      artist: current.artist,
      jsonPath: current.jsonPath,
      audioPath: current.audioPath,
      lines: playerLines,
      durationMs: fresh.durationMs,
      modifiedAt: fresh.modifiedAt,
    );

    if (!mounted) return;
    setState(() {
      // A ValueListenable cannot be assigned to. Retain this screen's edited
      // lyrics across catalog refreshes without changing the widget API.
      _editedLyrics[editedSong.jsonPath] = refreshed(editedSong);
      _songs = _sorted(_songs.map((item) =>
          item.songId == editedSong.songId ||
          item.jsonPath == editedSong.jsonPath
              ? refreshed(item) : item).toList());
      if (_playing != null &&
          (_playing!.songId == editedSong.songId ||
           _playing!.jsonPath == editedSong.jsonPath)) {
        _playing = refreshed(_playing!);
      }
      _lastActive = -1;
    });
    // Keep current position and playing/paused state exactly as they are.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollActive();
    });
  }

  Future<void> _editInfo(SyncedLyricsSong song) async {
    var entry = _remoteIndex['id::${song.songId}'] ??
        _remoteIndex[_identity(song.artist, song.title)];
    if (entry == null) {
      try {
        _remoteIndex = await _catalog(force: true);
        entry = _remoteIndex['id::${song.songId}'] ??
            _remoteIndex[_identity(song.artist, song.title)];
      } catch (error) {
        if (mounted) setState(() => _error = 'Cannot load metadata: $error');
        return;
      }
    }
    if (entry == null) return;
    final id = entry['id']?.toString() ?? '';
    // Synchronized imported recordings have the same server ID in the
    // imported-audio table only when the song ID maps to its import ID.
    final fields = <String, TextEditingController>{
      for (final key in ['title', 'artist', 'album', 'year', 'genre', 'trackNumber'])
        key: TextEditingController(text: entry[key]?.toString() ??
            (key == 'title' ? song.title : key == 'artist' ? song.artist : '')),
    };
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Edit song information'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final key in fields.keys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: fields[key],
                      decoration: InputDecoration(labelText: key),
                      keyboardType: ['year', 'trackNumber'].contains(key)
                          ? TextInputType.number : TextInputType.text,
                    ),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      );
      if (save != true || !mounted) return;
      final importId = entry['importId']?.toString() ?? '';
      if (importId.isEmpty) {
        setState(() => _error = 'This server song has no imported-audio ID. Metadata cannot be saved safely.');
        return;
      }
      final payload = <String, dynamic>{};
      for (final key in fields.keys) {
        final value = fields[key]!.text.trim();
        if (['year', 'trackNumber'].contains(key)) {
          if (value.isNotEmpty && int.tryParse(value) == null) {
            setState(() => _error = '$key must be a number');
            return;
          }
          payload[key] = value.isEmpty ? null : int.parse(value);
        } else {
          payload[key] = value;
        }
      }
      await _server.updateImportedMetadataFields(importId, payload);
      _remoteIndex = await _catalog(force: true);
      try {
        await _updateLocalSongMetadata(song, payload);
      } catch (cacheError) {
        // Server has saved the edit; report local cache issue separately.
        if (mounted) setState(() => _error = 'Saved on server; local cache update failed: $cacheError');
      }
      _metadataOverrides[song.songId] = {
        'title': payload['title']?.toString() ?? song.title,
        'artist': payload['artist']?.toString() ?? song.artist,
      };
      await _saveMetadataOverrides();
      if (mounted) {
        final updated = SyncedLyricsSong(
          songId: song.songId,
          title: payload['title']?.toString() ?? song.title,
          artist: payload['artist']?.toString() ?? song.artist,
          jsonPath: song.jsonPath,
          audioPath: song.audioPath,
          lines: song.lines,
          durationMs: song.durationMs,
          modifiedAt: song.modifiedAt,
        );
        setState(() {
          _songs = _sorted(_songs.map((item) =>
              item.songId == song.songId ? updated : item).toList());
          if (_playing?.songId == song.songId) _playing = updated;
          _selectedArtist = updated.artist;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not save metadata: $error');
    } finally {
      for (final controller in fields.values) {
        controller.dispose();
      }
    }
  }


  Future<void> _play(SyncedLyricsSong song) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      var entry = _remoteIndex['id::${song.songId}'] ?? _remoteIndex[_identity(song.artist, song.title)];
      if (entry == null) {
        _remoteIndex = await _catalog(force: true);
        entry = _remoteIndex['id::${song.songId}'] ?? _remoteIndex[_identity(song.artist, song.title)];
      }
      // Older downloaded lyric JSONs can use a legacy ID and incorrect artist
      // (e.g. "02" instead of "Avenged Sevenfold"). Resolve conservatively:
      // try stable IDs, then only a UNIQUE matching title with audio available.
      if (entry == null) {
        final filename = song.jsonPath.split('/').last;
        final cachedId = filename.toLowerCase().endsWith('.json')
            ? filename.substring(0, filename.length - 5) : filename;
        entry = _remoteIndex['id::$cachedId'];
      }
      if (entry == null) {
        final normalizedTitle = _identity('', song.title).split('::').last;
        final candidates = <String, Map<String, dynamic>>{};
        for (final candidate in _remoteIndex.values) {
          if (candidate['audioAvailable'] != true) continue;
          final candidateTitle = _identity('', candidate['title']?.toString() ?? '').split('::').last;
          if (candidateTitle == normalizedTitle) {
            final candidateId = candidate['id']?.toString() ?? '';
            if (candidateId.isNotEmpty) candidates[candidateId] = candidate;
          }
        }
        if (candidates.length == 1) entry = candidates.values.single;
      }
      if (entry == null) throw StateError('Cannot resolve a unique MP3 on Windows for this song. Check its metadata and server index.');
      if (entry['audioAvailable'] != true) throw StateError('MP3 unavailable on Windows server.');
      final id = entry['id']?.toString() ?? '';
      if (id.isEmpty) throw StateError('Server ID missing.');
      final mp3 = await _cachedAudio(entry, id);
      await _player.stop();
      await _player.setFilePath(mp3.path);
      await _player.setVolume(_volume);
      if (!mounted) return;
      _browseTimer?.cancel();
      setState(() {
        _playing = song;
        _showLyrics = true;
        _browsingLyrics = false;
        _positionMs = 0;
        _lastActive = -1;
        _dragSeconds = null;
      });
      _sendPlaybackState(force: true);
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _scrollActive(); });
      // Pre-render the PiP video while the song is already playing, not when
      // the PiP button is pressed. This does not block playback or the UI.
      if (Platform.isIOS) {
        unawaited(_prewarmMusicPiP(song));
      }
      unawaited(_player.play());
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not play ${song.title}: $e');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  static String _cacheKey(String value) {
    var hash = 0xcbf29ce484222325;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Future<File> _cachedAudio(Map<String, dynamic> entry, String id) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/LyriKO/PrivateAudio');
    await directory.create(recursive: true);
    final base = await _server.getBaseUrl();
    final revision = entry['audioRevision'] ?? entry['audio_revision'] ??
        entry['audioModified'] ?? entry['audioSize'] ?? entry['version'] ?? 'unversioned';
    final key = _cacheKey('$base\n$id\n$revision');
    final file = File('${directory.path}/$key.mp3');
    if (await file.exists() && await file.length() > 4096) return file;

    // Signed audio links are short-lived. Request a NEW link for each attempt.
    // Never cache or display a signed URL in the user-facing error message.
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      final partial = File('${file.path}.partial');
      HttpClient? client;
      IOSink? sink;
      try {
        final url = await _server.audioUrl(id);
        final token = await _server.getAuthToken();
        if (token.isEmpty) throw StateError('Missing server token.');
        client = HttpClient()..connectionTimeout = const Duration(seconds: 18);
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        final response = await request.close().timeout(const Duration(seconds: 30));
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw StateError('Audio HTTP ${response.statusCode}');
        }
        const maxBytes = 100 * 1024 * 1024;
        var downloaded = 0;
        sink = partial.openWrite();
        await for (final chunk in response.timeout(const Duration(seconds: 45))) {
          downloaded += chunk.length;
          if (downloaded > maxBytes) throw StateError('MP3 exceeds 100 MB cache limit.');
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (downloaded < 4096 ||
            (response.contentLength >= 0 && downloaded != response.contentLength)) {
          throw const FormatException('Incomplete MP3 download.');
        }
        if (await file.exists()) await file.delete();
        return await partial.rename(file.path);
      } catch (error) {
        lastError = error;
        try { await sink?.close(); } catch (_) {}
        try { if (await partial.exists()) await partial.delete(); } catch (_) {}
        if (attempt < 2) await Future<void>.delayed(Duration(seconds: attempt + 1));
      } finally {
        client?.close(force: true);
      }
    }
    throw StateError('Audio download failed after 3 attempts. Check the Windows server or Cloudflare connection. (${lastError.runtimeType})');
  }

  List<SyncedLyricsSong> get _playlist => _songs;

  void _next() {
    if (_opening || _playing == null || _playlist.isEmpty) return;
    if (_shuffle && _playlist.length > 1) {
      final currentIndex = _playlist.indexWhere((s) => s.songId == _playing!.songId);
      var nextIndex = currentIndex;
      while (nextIndex == currentIndex) {
        nextIndex = math.Random().nextInt(_playlist.length);
      }
      unawaited(_play(_playlist[nextIndex]));
      return;
    }
    final index = _playlist.indexWhere((s) => s.songId == _playing!.songId);
    if (index < 0) return;
    unawaited(_play(_playlist[(index + 1) % _playlist.length]));
  }

  void _previous() {
    if (_opening || _playing == null || _playlist.isEmpty) return;
    final index = _playlist.indexWhere((s) => s.songId == _playing!.songId);
    if (index < 0) return;
    unawaited(_play(_playlist[(index - 1 + _playlist.length) % _playlist.length]));
  }

  int get _activeIndex {
    final lines = _playing?.lines;
    if (lines == null || lines.isEmpty) return -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (_karaokePosition.value >= lines[i].startMs) return i;
    }
    return -1;
  }

  void _scrollActive() {
    if (_browsingLyrics || _playing == null || !_showLyrics) return;
    final index = _activeIndex;
    if (index < 0 || index == _lastActive) return;
    _lastActive = index;
    if (!_lyricsScroll.isAttached) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lyricsScroll.isAttached && !_browsingLyrics) {
          _lyricsScroll.jumpTo(index: index, alignment: 0.45);
        }
      });
      return;
    }
    unawaited(_lyricsScroll.scrollTo(
      index: index,
      alignment: 0.45,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    ));
  }

  Future<void> _skipSeconds(int seconds) async {
    final durationMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : (_playing?.durationMs ?? 0);
    final requested = _positionMs + seconds * 1000;
    await _player.seek(Duration(milliseconds: requested.clamp(0, durationMs > 0 ? durationMs : 86400000).toInt()));
    _lastActive = -1;
    _scrollActive();
  }

  Future<void> _togglePlayPause() async {
    if (_playing == null) return;
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  String _format(Duration d) {
    final seconds = d.inSeconds.clamp(0, 86400);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _karaokeTicker.dispose();
    _karaokeClock.stop();
    _karaokePosition.dispose();
    for (final sub in _subs) {
      sub.cancel();
    }
    if (MyMusicScreen.playbackCommand != null) MyMusicScreen.playbackCommand = null;
    MyMusicScreen.showLyricsCommand = null;
    widget.songsListenable.removeListener(_onHomeLibrary);
    _browseTimer?.cancel();
    _pipSyncTimer?.cancel();
    _pipDiagnosticPoll?.cancel();
    if (Platform.isIOS) {
      unawaited(_pipChannel.invokeMethod('disposeAVPlayerV2'));
      _mediaChannel.setMethodCallHandler(null);
    }
    _focusNode.dispose();
    _player.dispose();
    _search.dispose();
    super.dispose();
  }

  void _exitMusic() {
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _search.clearComposing();
    if (widget.onExit != null) {
      widget.onExit!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _search.text.toLowerCase().trim();
    final filtered = _songs.where((s) => '${s.artist} ${s.title}'.toLowerCase().contains(q)).toList();
    final groups = <String, List<SyncedLyricsSong>>{};
    for (final item in filtered) {
      groups.putIfAbsent(item.artist.trim().isEmpty ? 'Unknown artist' : item.artist.trim(), () => []).add(item);
    }
    final names = groups.keys.toList();
    final activeArtist = _selectedArtist != null && names.contains(_selectedArtist) ? _selectedArtist! : (names.isEmpty ? '' : names.first);
    final song = _playing;
    final totalMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : (song?.durationMs ?? 1).clamp(1, 86400000);
    final value = (_dragSeconds ?? _positionMs / 1000).clamp(0.0, totalMs / 1000);

    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.space): const ActivateIntent(),
      const SingleActivator(LogicalKeyboardKey.keyA, control: true): const _SeekIntent(-5),
      const SingleActivator(LogicalKeyboardKey.keyD, control: true): const _SeekIntent(5),
      const SingleActivator(LogicalKeyboardKey.keyJ, control: true): const _TrackIntent(false),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): const _TrackIntent(true),
    };

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _togglePlayPause()),
          _SeekIntent: CallbackAction<_SeekIntent>(onInvoke: (intent) => _skipSeconds(intent.seconds)),
          _TrackIntent: CallbackAction<_TrackIntent>(onInvoke: (intent) => intent.next ? _next() : _previous()),
        },
        child: Focus(
          autofocus: true,
          focusNode: _focusNode,
          child: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (didPop || !mounted) return;
              if (_playing != null && _showLyrics && !wideForControls(context)) {
                setState(() => _showLyrics = false);
              } else {
                _exitMusic();
              }
            },
            child: Scaffold(
            appBar: _buildAppBar(context, song),
            body: Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 860;
                      if (wide) {
                        return Row(
                          children: [
                            SizedBox(
                              width: (constraints.maxWidth * .28).clamp(300.0, 380.0),
                              child: _buildBrowser(theme, names, activeArtist, groups, song),
                            ),
                            VerticalDivider(width: 1, color: theme.dividerColor),
                            Expanded(
                              child: song == null
                                  ? _buildEmpty(theme)
                                  : _buildLyricsPane(theme, song, compact: false),
                            ),
                          ],
                        );
                      }

                      if (song != null && _showLyrics) {
                        return GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragEnd: (details) {
                            if ((details.primaryVelocity ?? 0) > 250 && mounted) {
                              setState(() => _showLyrics = false);
                            }
                          },
                          child: _buildLyricsPane(theme, song, compact: true),
                        );
                      }
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragStart: (details) {
                          _edgeSwipeStartX = details.globalPosition.dx;
                        },
                        onHorizontalDragEnd: (details) {
                          final fromEdge = (_edgeSwipeStartX ?? double.infinity) < 35;
                          _edgeSwipeStartX = null;
                          if (fromEdge && (details.primaryVelocity ?? 0) > 220) {
                            _exitMusic();
                          }
                        },
                        onHorizontalDragCancel: () => _edgeSwipeStartX = null,
                        child: _buildBrowser(theme, names, activeArtist, groups, song),
                      );
                    },
                  ),
                ),
                if (song != null) (_showLyrics || wideForControls(context))
                    ? _buildControls(theme, song, totalMs, value)
                    : _buildMiniPlayer(theme, song),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }

  bool wideForControls(BuildContext context) => MediaQuery.of(context).size.width >= 860;

  Widget _buildMiniPlayer(ThemeData theme, SyncedLyricsSong song) {
    final duration = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : song.durationMs;
    String clock(int ms) => '${(ms ~/ 60000).toString()}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';
    return SafeArea(
      top: false,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (duration > 0) LinearProgressIndicator(
            value: (_positionMs / duration).clamp(0.0, 1.0), minHeight: 3),
          Row(children: [
            const SizedBox(width: 10),
            IconButton(onPressed: () {
                setState(() => _showLyrics = true);
                _lastActive = -1;
                WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _scrollActive(); });
              },
              icon: const Icon(Icons.expand_less_rounded), tooltip: 'Open lyrics'),
            Expanded(child: InkWell(
              onTap: () {
                setState(() => _showLyrics = true);
                _lastActive = -1;
                WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _scrollActive(); });
              },
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('${song.artist} • ${clock(_positionMs)} / ${clock(duration)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
              ]))),
            IconButton(onPressed: _previous, icon: const Icon(Icons.skip_previous_rounded)),
            IconButton(onPressed: _togglePlayPause,
              icon: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded)),
            IconButton(onPressed: _next, icon: const Icon(Icons.skip_next_rounded)),
          ]),
        ]),
      ),
    );
  }

  PreferredSizeWidget? _buildAppBar(BuildContext context, SyncedLyricsSong? song) {
    final narrowPlayback = song != null && _showLyrics && MediaQuery.of(context).size.width < 860;
    if (narrowPlayback) return null;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: _exitMusic,
      ),
      title: const Text('MY MUSIC'),
      actions: [
        IconButton(
          onPressed: _loading ? null : _refresh,
          tooltip: 'Refresh server index',
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }

  Widget _buildBrowser(
    ThemeData theme,
    List<String> names,
    String activeArtist,
    Map<String, List<SyncedLyricsSong>> groups,
    SyncedLyricsSong? song,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: 'Search your music',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainer,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
          child: Row(
            children: [
              const Text(
                'ARTISTS',
                style: TextStyle(fontSize: 11, letterSpacing: 1.7, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text('${_songs.length} tracks', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              for (final artist in names)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: activeArtist == artist,
                    label: Text('$artist  ·  ${groups[artist]!.length}'),
                    onSelected: (_) => setState(() => _selectedArtist = artist),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: names.isEmpty
              ? const Center(child: Text('No songs found'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: groups[activeArtist]!.length,
                  itemBuilder: (context, i) {
                    final item = groups[activeArtist]![i];
                    final selected = song?.songId == item.songId;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: selected ? theme.colorScheme.surfaceContainerHigh : Colors.transparent,
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: _opening ? null : () => _play(item),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            child: Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surfaceContainer,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    selected ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    item.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _editInfo(item),
                                  tooltip: 'Edit title, artist, album, year, genre and track number',
                                  icon: const Icon(Icons.tune_rounded),
                                ),
                                Icon(
                                  selected ? Icons.equalizer_rounded : Icons.play_arrow_rounded,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  size: 22,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_music_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          const Text('Select a track to listen', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 5),
          Text('Your synchronized lyrics will appear here', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _buildLyricsPane(ThemeData theme, SyncedLyricsSong song, {required bool compact}) {
    final topPad = compact ? 8.0 : 24.0;
    final titleSize = compact ? 18.0 : 30.0;
    final artistSize = compact ? 13.0 : 16.0;
    final active = _activeIndex;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, topPad, 16, compact ? 4 : 10),
            child: Row(
              children: [
                if (compact)
                  IconButton(
                    onPressed: () => setState(() => _showLyrics = false),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    tooltip: 'Back to library',
                  )
                else
                  const SizedBox(width: 48),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        song.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: titleSize,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        song.artist,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontSize: artistSize),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    // Pause during editing so the editor's own audio player
                    // cannot overlap MY MUSIC. Do not stop/seek/recreate audio.
                    final wasPlaying = _player.playing;
                    if (wasPlaying) await _player.pause();
                    if (!mounted) return;
                    try {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => LyricsEditScreen(
                            jsonPath: song.jsonPath,
                            onLyricsSaved: () => _reloadEditedLyrics(song),
                          ),
                        ),
                      );
                      // Also refresh on exit, including edits saved before
                      // the callback existed or changes made elsewhere.
                      if (mounted) await _reloadEditedLyrics(song);
                    } catch (error) {
                      if (mounted) setState(() =>
                          _error = 'Could not refresh edited lyrics: $error');
                    } finally {
                      // Resume from the exact paused position, never from 0.
                      if (mounted && wasPlaying && !_player.playing) {
                        unawaited(_player.play());
                      }
                    }
                  },
                  icon: const Icon(Icons.edit_note_rounded),
                  tooltip: 'Edit synchronized lyrics',
                ),
                IconButton(
                  onPressed: song == null ? null : () => _editInfo(song),
                  icon: const Icon(Icons.tune_rounded),
                  tooltip: 'Edit song metadata',
                ),
                IconButton(
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onLyricsScroll,
              child: ScrollablePositionedList.builder(
                key: ValueKey('lyrics-scroll-${song.songId}'),
                itemScrollController: _lyricsScroll,
                padding: EdgeInsets.symmetric(vertical: compact ? 140 : 170),
                itemCount: song.lines.length,
                itemBuilder: (context, index) {
                  final line = song.lines[index];
                  final distance = (index - active).abs().clamp(0, 2).toInt();
                  return LayoutBuilder(builder: (context, constraints) {
                    final availableWidth = math.min(
                      math.max(1.0, constraints.maxWidth - (compact ? 24 : 48)),
                      compact ? constraints.maxWidth : 900.0,
                    );
                    final size = compact
                        ? (index == active ? 34.0 : distance == 1 ? 24.0 : 21.0)
                        : (index == active ? 44.0 : distance == 1 ? 30.0 : 26.0);
                    final painter = TextPainter(
                      text: TextSpan(text: line.text.trim(),
                        style: TextStyle(fontSize: size, height: index == active ? 1.08 : 1.15,
                          fontWeight: index == active ? FontWeight.w800 : FontWeight.w500)),
                      textAlign: TextAlign.center,
                      textDirection: Directionality.of(context),
                      textScaler: MediaQuery.textScalerOf(context),
                    )..layout(maxWidth: availableWidth);
                    final height = math.max(compact ? 104.0 : 125.0, painter.height + 30.0);
                    painter.dispose();
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24),
                      child: SizedBox(
                        height: height,
                        child: InkWell(
                          onTap: () async {
                            _browseTimer?.cancel();
                            _browsingLyrics = false;
                            await _player.seek(Duration(milliseconds: line.startMs));
                            if (!mounted) return;
                            _syncKaraokeClock(line.startMs);
                            setState(() => _positionMs = line.startMs);
                            _lastActive = -1;
                            _scrollActive();
                            _sendPlaybackState(force: true);
                          },
                          child: Center(
                            child: index == active
                                ? ValueListenableBuilder<int>(
                                    valueListenable: _karaokePosition,
                                    builder: (context, now, _) => _VoiceTimedLyric(
                                      key: ValueKey('${song.songId}-$index'),
                                      line: line,
                                      positionMs: now,
                                      active: true,
                                      done: false,
                                      distance: 0,
                                      baseColor: theme.colorScheme.onSurface,
                                      direction: Directionality.of(context),
                                      compact: compact,
                                    ),
                                  )
                                : _VoiceTimedLyric(
                                    key: ValueKey('${song.songId}-$index'),
                                    line: line,
                                    positionMs: _positionMs,
                                    active: false,
                                    done: index < active,
                                    distance: distance,
                                    baseColor: theme.colorScheme.onSurface,
                                    direction: Directionality.of(context),
                                    compact: compact,
                                  ),
                          ),
                        ),
                      ),
                    );
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(ThemeData theme, SyncedLyricsSong song, int totalMs, double value) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              value: value,
              min: 0,
              max: (totalMs / 1000).clamp(.001, 86400.0),
              onChanged: (v) => setState(() => _dragSeconds = v),
              onChangeEnd: (v) async {
                await _player.seek(Duration(milliseconds: (v * 1000).round()));
                if (mounted) {
                  setState(() {
                    _dragSeconds = null;
                    _lastActive = -1;
                  });
                }
                _scrollActive();
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: [
                  Text(_format(Duration(milliseconds: (_dragSeconds == null ? _positionMs : (_dragSeconds! * 1000).round()))), style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text(_format(Duration(milliseconds: totalMs)), style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _controlButton(
                  icon: Icons.skip_previous_rounded,
                  onPressed: _opening ? null : _previous,
                  tooltip: 'Previous track',
                  size: 32,
                ),
                _controlButton(
                  icon: Icons.replay_5_rounded,
                  onPressed: () => _skipSeconds(-5),
                  tooltip: 'Back 5 seconds',
                  size: 30,
                ),
                IconButton(
                  onPressed: _opening ? null : _togglePlayPause,
                  tooltip: _isPlaying ? 'Pause' : 'Play',
                  icon: Icon(_isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded),
                  iconSize: 68,
                ),
                _controlButton(
                  icon: Icons.forward_5_rounded,
                  onPressed: () => _skipSeconds(5),
                  tooltip: 'Forward 5 seconds',
                  size: 30,
                ),
                _controlButton(
                  icon: Icons.skip_next_rounded,
                  onPressed: _opening ? null : _next,
                  tooltip: 'Next track',
                  size: 32,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _toggleIcon(
                  active: _shuffle,
                  icon: Icons.shuffle_rounded,
                  onTap: () => setState(() => _shuffle = !_shuffle),
                  tooltip: 'Shuffle',
                ),
                const SizedBox(width: 26),
                _toggleIcon(
                  active: _repeatOne,
                  icon: Icons.repeat_one_rounded,
                  onTap: () => setState(() => _repeatOne = !_repeatOne),
                  tooltip: 'Repeat current song',
                ),
                const SizedBox(width: 26),
                _buildVolumeButton(theme),
                if (Platform.isIOS) ...[
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: 'PiP diagnostics · copy report',
                    onPressed: _showMusicPipDiagnostics,
                    icon: const Icon(Icons.bug_report_outlined),
                  ),
                  const SizedBox(width: 4),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'PiP: $_pipVisualStatus',
                        onPressed: _pipIsTransitioning ? null : _toggleMusicPiP,
                        icon: _pipIsTransitioning
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(_pipActive
                                ? Icons.picture_in_picture_alt_rounded
                                : Icons.picture_in_picture_rounded),
                      ),
                      Text(
                        _pipVisualStatus,
                        style: const TextStyle(fontSize: 9),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlButton({required IconData icon, required VoidCallback? onPressed, required String tooltip, required double size}) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon),
      iconSize: size,
    );
  }

  Widget _toggleIcon({required bool active, required IconData icon, required VoidCallback onTap, required String tooltip}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active ? Colors.white.withOpacity(.10) : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(icon, size: 24),
        ),
      ),
    );
  }

  Widget _buildVolumeButton(ThemeData theme) {
    return PopupMenuButton<void>(
      tooltip: 'Volume',
      constraints: const BoxConstraints(minWidth: 70, maxWidth: 70),
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          height: 190,
          child: SizedBox(
            width: 70,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded),
                  const SizedBox(height: 10),
                  RotatedBox(
                    quarterTurns: -1,
                    child: SizedBox(
                      width: 130,
                      child: Slider(
                        value: _volume,
                        min: 0,
                        max: 1,
                        onChanged: (v) {
                          setState(() => _volume = v);
                          unawaited(_player.setVolume(v));
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      offset: const Offset(34, -190),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(_volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded, size: 24),
      ),
    );
  }
}

class _SeekIntent extends Intent {
  const _SeekIntent(this.seconds);
  final int seconds;
}

class _TrackIntent extends Intent {
  const _TrackIntent(this.next);
  final bool next;
}

class _VoiceTimedLyric extends StatelessWidget {
  const _VoiceTimedLyric({
    required this.line,
    required this.positionMs,
    required this.active,
    required this.done,
    required this.baseColor,
    required this.direction,
    required this.compact,
    required this.distance,
    super.key,
  });

  final SyncedLyricLine line;
  final int positionMs;
  final bool active;
  final bool done;
  final Color baseColor;
  final TextDirection direction;
  final bool compact;
  final int distance;

  double _progressFor(String text) => _editorMatchedSweep(line, positionMs);

  @override
  Widget build(BuildContext context) {
    final text = line.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    // Every visible lyric is large. Only a subtle scale and color shift
    // distinguish the current line; distant small-font rows are removed.
    final fontSize = compact
        ? (active ? 34.0 : distance == 1 ? 24.0 : 21.0)
        : (active ? 44.0 : distance == 1 ? 30.0 : 26.0);
    final style = TextStyle(
      fontSize: fontSize,
      height: active ? 1.08 : 1.15,
      fontWeight: active ? FontWeight.w800 : FontWeight.w500,
      letterSpacing: active ? -.2 : 0,
    );

    return LayoutBuilder(builder: (context, constraints) {
      final width = compact
          ? constraints.maxWidth
          : math.min(constraints.maxWidth, 900.0);
      final scaler = MediaQuery.textScalerOf(context);
      final availableHeight = constraints.maxHeight.isFinite
          ? math.max(1.0, constraints.maxHeight - 4.0)
          : 1000.0;

      // Fit the COMPLETE phrase inside its karaoke slot instead of truncating
      // the third/fourth visual row. The same exact style is used by both
      // text layers and the sweep clipper.
      var fittedStyle = style;
      for (var attempt = 0; attempt < 30; attempt++) {
        final probe = TextPainter(
          text: TextSpan(text: text, style: fittedStyle),
          textAlign: TextAlign.center,
          textDirection: direction,
          textScaler: scaler,
        )..layout(maxWidth: width);
        final fits = probe.height <= availableHeight && !probe.didExceedMaxLines;
        probe.dispose();
        if (fits || fittedStyle.fontSize! <= (compact ? 13.0 : 17.0)) break;
        fittedStyle = fittedStyle.copyWith(fontSize: fittedStyle.fontSize! - 1.0);
      }

      final mutedStyle = fittedStyle.copyWith(
        color: baseColor.withOpacity(active ? .34 : distance == 1 ? .38 : .22),
      );
      if (!active) {
        return SizedBox(
          width: width,
          child: Text(text, textAlign: TextAlign.center,
              softWrap: true, style: mutedStyle),
        );
      }
      // Exactly the editor's Text.rich strategy: a SINGLE paragraph layout,
      // one character per span, with continuously interpolated foreground.
      // No second text layer, no glyph boxes and no clipping geometry.
      final progress = _progressFor(text);
      final boundary = text.length * progress;
      final spans = <TextSpan>[];
      for (var i = 0; i < text.length; i++) {
        final fraction = (boundary - i).clamp(0.0, 1.0);
        spans.add(TextSpan(
          text: text[i],
          style: TextStyle(color: Color.lerp(
              mutedStyle.color!, baseColor, fraction)),
        ));
      }
      return SizedBox(
        width: width,
        child: Text.rich(
          TextSpan(children: spans),
          textAlign: TextAlign.center,
          softWrap: true,
          style: fittedStyle,
        ),
      );
    });
  }
}
