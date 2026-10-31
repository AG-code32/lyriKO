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
    if (_karaokePosition.value != now) {
      final previous = _activeIndex;
      _karaokePosition.value = now;
      if (_activeIndex != previous && mounted) {
        setState(() => _lastActive = -1);
        _scrollActive();
      }
    }
  }

  final _player = AudioPlayer();
  final _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
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
    _loadSavedMetadata();
    _warmIndex();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted || _playing == null) return;
    // Refresh the Flutter mini player from the actual native player on resume.
    setState(() {
      _positionMs = _player.position.inMilliseconds;
      _isPlaying = _player.playing;
    });
    _sendPlaybackState(force: true);
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
    // The service preserves wordsEdited directly from each JSON line.
    // Do not rely on matching raw JSON indices or overwrite original anchors.
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
      // Use the same locally saved WORDS timestamps as Lyrics Timeline,
      // including on the FIRST playback (not just after closing the editor).
      try {
        await _reloadEditedLyrics(song);
      } catch (error) {
        debugPrint('Using existing lyrics: $error');
      }
      final currentLyrics = _songs.where((item) =>
          item.songId == song.songId || item.jsonPath == song.jsonPath);
      final freshSong = currentLyrics.isNotEmpty ? currentLyrics.first : song;
      await _player.stop();
      await _player.setFilePath(mp3.path);
      await _player.setVolume(_volume);
      if (!mounted) return;
      _browseTimer?.cancel();
      setState(() {
        _playing = freshSong;
        _showLyrics = true;
        _browsingLyrics = false;
        _positionMs = 0;
        _lastActive = -1;
        _dragSeconds = null;
      });
      _sendPlaybackState(force: true);
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _scrollActive(); });
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
    if (Platform.isIOS) _mediaChannel.setMethodCallHandler(null);
    _focusNode.dispose();
    _player.dispose();
    _searchFocus.dispose();
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
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.space) {
              return KeyEventResult.ignored;
            }
            final focused = FocusManager.instance.primaryFocus?.context?.widget;
            if (focused is EditableText || _searchFocus.hasFocus) {
              return KeyEventResult.ignored;
            }
            _togglePlayPause();
            return KeyEventResult.handled;
          },
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
            focusNode: _searchFocus,
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
                if (Platform.isMacOS)
                  SizedBox(width: 190, child: Row(children: [
                    Icon(_volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded, size: 19),
                    Expanded(child: Slider(value: _volume, min: 0, max: 1,
                      onChanged: (v) {
                        setState(() => _volume = v);
                        unawaited(_player.setVolume(v));
                      })),
                  ]))
                else
                  _buildVolumeButton(theme),
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

  double _curve(double fraction, {String? word}) => LyricSweepCurve.transform(
    fraction, line.sweepCurve,
    text: word ?? line.text.trim(),
    syllables: line.sweepSyllables,
    weights: line.sweepWeights,
    points: line.sweepPoints,
  );

  double _progressFor(String text) {
    final duration = line.endMs - line.startMs;
    if (text == '♪') return positionMs >= line.startMs && positionMs < line.endMs ? 1.0 : 0.0;
    final isAutomation = line.sweepCurve == 'automation';
    final effectivePositionMs = isAutomation && duration > 0 &&
        positionMs > line.startMs && positionMs < line.endMs
        ? line.startMs + (duration * LyricSweepCurve.transform(
            (positionMs - line.startMs) / duration, 'automation',
            points: line.sweepPoints)).round()
        : positionMs;
    if (effectivePositionMs <= line.startMs) return 0.0;
    if (duration <= 0 || effectivePositionMs >= line.endMs) return 1.0;
    if (text.isEmpty || line.words.isEmpty) {
      return isAutomation ? (effectivePositionMs - line.startMs) / duration : _curve((effectivePositionMs - line.startMs) / duration);
    }
    // WORDS edited in Lyrics Timeline are already absolute song timestamps.
    // Only unedited CTC words need their original->calibrated mapping.
    final originalSpan = line.originalEndMs - line.originalStartMs;
    int adjusted(int ms) => line.wordsEdited
        ? ms
        : originalSpan <= 0
            ? line.startMs + ms - line.originalStartMs
            : line.startMs + ((ms - line.originalStartMs) * duration / originalSpan).round();
    final lower = text.toLowerCase();
    var cursor = 0;
    var previous = 0.0;
    var matches = 0;
    for (final word in line.words) {
      final token = word.text.trim().toLowerCase();
      if (token.isEmpty || word.endMs <= word.startMs) continue;
      var index = lower.indexOf(token, cursor);
      var length = token.length;
      if (index < 0) {
        final simplified = token.replaceAll(RegExp(r"[^a-z0-9']"), '');
        if (simplified.isEmpty) continue;
        index = lower.indexOf(simplified, cursor);
        length = simplified.length;
      }
      if (index < 0) continue;
      matches++;
      final start = adjusted(word.startMs);
      final end = adjusted(word.endMs);
      if (effectivePositionMs < start) return previous;
      if (effectivePositionMs <= end) {
        final fraction = ((effectivePositionMs - start) /
            (end - start).clamp(1, 100000000)).clamp(0.0, 1.0);
        return ((index + length * (isAutomation ? fraction : _curve(fraction,
            word: text.substring(index, index + length)))) / text.length).clamp(0.0, 1.0);
      }
      cursor = index + length;
      previous = cursor / text.length;
    }
    if (matches == 0) {
      return isAutomation ? (effectivePositionMs - line.startMs) / duration : _curve((effectivePositionMs - line.startMs) / duration);
    }
    // The last sung word completes the whole phrase, including punctuation.
    // Never leave a dark suffix while waiting for the next line to begin.
    return 1.0;
  }

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

      final mutedColor = baseColor.withOpacity(
        active ? .34 : distance == 1 ? .38 : .22,
      );
      if (!active) {
        return SizedBox(
          width: width,
          child: Text(
            text,
            textAlign: TextAlign.center,
            softWrap: true,
            style: fittedStyle.copyWith(color: mutedColor),
          ),
        );
      }

      // Match Lyrics Timeline's working karaoke preview: render a SINGLE
      // Text.rich paragraph. Two separately laid-out Text widgets with a
      // ClipPath can disagree on glyph positions, leaving visible dark gaps.
      // A single paragraph guarantees the muted and bright portions share
      // precisely the same glyph metrics, wrapping and baselines.
      final boundary = text.length * _progressFor(text);
      final spans = <TextSpan>[];
      for (var i = 0; i < text.length; i++) {
        final fraction = (boundary - i).clamp(0.0, 1.0);
        spans.add(TextSpan(
          text: text[i],
          style: TextStyle(
            color: Color.lerp(mutedColor, baseColor, fraction),
          ),
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
