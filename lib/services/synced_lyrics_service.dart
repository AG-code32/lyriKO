import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class SyncedLyricWord {
  final String text;
  final int startMs;
  final int endMs;

  const SyncedLyricWord({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  factory SyncedLyricWord.fromJson(Map<String, dynamic> json) {
    return SyncedLyricWord(
      text: json['text']?.toString() ?? '',
      startMs: (json['startMs'] as num?)?.toInt() ?? 0,
      endMs: (json['endMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class SyncedLyricLine {
  final int startMs;
  final int endMs;

  final int originalStartMs;
  final int originalEndMs;

  final String text;

  final List<SyncedLyricWord> words;

  const SyncedLyricLine({
    required this.startMs,
    required this.endMs,
    required this.originalStartMs,
    required this.originalEndMs,
    required this.text,
    required this.words,
  });

  bool get manuallyCalibrated => startMs != originalStartMs;

  factory SyncedLyricLine.fromJson(Map<String, dynamic> json) {
    final startMs = (json['startMs'] as num?)?.toInt() ?? 0;

    final endMs = (json['endMs'] as num?)?.toInt() ?? startMs;

    final rawWords = (json['words'] as List<dynamic>?) ?? const [];

    return SyncedLyricLine(
      startMs: startMs,
      endMs: endMs,
      originalStartMs: (json['originalStartMs'] as num?)?.toInt() ?? startMs,
      originalEndMs: (json['originalEndMs'] as num?)?.toInt() ?? endMs,
      text: json['text']?.toString() ?? '',
      words: rawWords
          .whereType<Map>()
          .map(
            (item) => SyncedLyricWord.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
    );
  }
}

class SyncedLyricsSong {
  final String songId;
  final String title;
  final String artist;

  final String jsonPath;
  final String? audioPath;

  final List<SyncedLyricLine> lines;

  final int durationMs;

  final DateTime modifiedAt;

  const SyncedLyricsSong({
    required this.songId,
    required this.title,
    required this.artist,
    required this.jsonPath,
    required this.audioPath,
    required this.lines,
    required this.durationMs,
    required this.modifiedAt,
  });

  String get displayName => artist.trim().isEmpty ? title : '$artist - $title';

  int get manualCalibrationCount =>
      lines.where((line) => line.manuallyCalibrated).length;

  bool get hasManualCalibration => manualCalibrationCount > 0;
}

class SyncedLyricsService {
  // On macOS the library is bundled with Flutter, just like on iOS/Android.
  // Edits are stored as private writable copies in Application Documents.
  // Keep the existing on-disk Windows project library unchanged.
  bool get _usesBundledAssets =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  String get _userProfile {
    final value = Platform.environment['USERPROFILE'];

    if (value == null || value.isEmpty) {
      throw StateError('Could not determine USERPROFILE.');
    }

    return value;
  }

  String get projectRoot =>
      '$_userProfile\\Desktop\\'
      'fluter_projects\\Lyriko\\lyrics_app';

  String get lyricsRoot => '$projectRoot\\assets\\lyrics';

  Future<List<SyncedLyricsSong>> loadLibrary() async {
    final discoveredSongs = <SyncedLyricsSong>[];

    if (_usesBundledAssets) {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final jsonAssets = manifest
          .listAssets()
          .where(
            (asset) =>
                asset.startsWith('assets/lyrics/') &&
                asset.toLowerCase().endsWith('.json'),
          )
          .toList();

      for (final assetPath in jsonAssets) {
        try {
          final song = await loadSong(assetPath);
          if (song.lines.isNotEmpty) {
            discoveredSongs.add(song);
          }
        } catch (_) {
          // Ignore debug/generated JSON files that are not Lyriko songs.
        }
      }
    } else {
      final directory = Directory(lyricsRoot);

      if (!await directory.exists()) {
        return [];
      }

      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File ||
            !entity.path.toLowerCase().endsWith('.json')) {
          continue;
        }

        try {
          final song = await loadSong(entity.path);
          if (song.lines.isNotEmpty) {
            discoveredSongs.add(song);
          }
        } catch (_) {
          // Ignore debug/generated JSON files that are not Lyriko songs.
        }
      }
    }

    final deduplicated = <String, SyncedLyricsSong>{};

    for (final song in discoveredSongs) {
      final key = identityKey(song.artist, song.title);
      final existing = deduplicated[key];

      if (existing == null) {
        deduplicated[key] = song;
      } else {
        deduplicated[key] = _choosePreferredSong(existing, song);
      }
    }

    final songs = deduplicated.values.toList();

    songs.sort((a, b) {
      final artistComparison =
          a.artist.toLowerCase().compareTo(b.artist.toLowerCase());

      if (artistComparison != 0) {
        return artistComparison;
      }

      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    return songs;
  }

  SyncedLyricsSong _choosePreferredSong(
    SyncedLyricsSong a,
    SyncedLyricsSong b,
  ) {
    //
    // Most important:
    // preserve manual calibration.
    //
    if (a.manualCalibrationCount != b.manualCalibrationCount) {
      return a.manualCalibrationCount > b.manualCalibrationCount ? a : b;
    }

    //
    // If neither/both are calibrated,
    // prefer the more complete lyrics.
    //
    if (a.lines.length != b.lines.length) {
      return a.lines.length > b.lines.length ? a : b;
    }

    //
    // Last tie breaker:
    // newest file.
    //
    return a.modifiedAt.isAfter(b.modifiedAt) ? a : b;
  }

  Future<SyncedLyricsSong?> findExistingSong({
    required String artist,
    required String title,
  }) async {
    final targetKey = identityKey(artist, title);

    final songs = await loadLibrary();

    for (final song in songs) {
      final key = identityKey(song.artist, song.title);

      if (key == targetKey) {
        return song;
      }
    }

    return null;
  }

  String identityKey(String artist, String title) {
    return '${_normalizeIdentityPart(artist)}'
        '::'
        '${_normalizeIdentityPart(title)}';
  }

  /// Makes a writable private copy of a bundled lyrics JSON for editing.
  /// The source asset stays unchanged, and existing edits are preserved.
  Future<String> editableJsonPath(String jsonPath) async {
    if (!jsonPath.startsWith('assets/')) return jsonPath;
    final file = await _editedFileForAsset(jsonPath);
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      final original = await rootBundle.loadString(jsonPath);
      await file.writeAsString(original, encoding: utf8, flush: true);
    }
    return file.path;
  }

  Future<File> _editedFileForAsset(String assetPath) async {
    final directory = await getApplicationDocumentsDirectory();
    final filename = assetPath.split('/').last;
    return File('${directory.path}/lyriko_edited/$filename');
  }

  Future<SyncedLyricsSong> loadSong(String jsonPath) async {
    final isAsset = jsonPath.startsWith('assets/');

    late String raw;
    late String filename;
    late DateTime modifiedAt;

    if (isAsset) {
      filename = jsonPath.split('/').last;
      final edited = await _editedFileForAsset(jsonPath);
      if (await edited.exists()) {
        raw = await edited.readAsString(encoding: utf8);
        modifiedAt = (await edited.stat()).modified;
      } else {
        raw = await rootBundle.loadString(jsonPath);
        modifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
      }
    } else {
      final file = File(jsonPath);

      if (!await file.exists()) {
        throw StateError('Sync JSON not found:\n$jsonPath');
      }

      raw = await file.readAsString(encoding: utf8);
      filename = file.uri.pathSegments.last;

      try {
        modifiedAt = (await file.stat()).modified;
      } catch (_) {
        modifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    final decoded = jsonDecode(raw);

    if (decoded is! Map) {
      throw StateError('Invalid song JSON:\n$jsonPath');
    }

    final json = Map<String, dynamic>.from(decoded);
    final rawLines = json['lines'];

    if (rawLines is! List) {
      throw StateError('Song JSON contains no lyrics.');
    }

    final lines = rawLines
        .whereType<Map>()
        .map(
          (item) => SyncedLyricLine.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .toList();

    final filenameWithoutExtension = filename.replaceFirst(
      RegExp(r'\.json$', caseSensitive: false),
      '',
    );

    String fallbackArtist = '';
    String fallbackTitle = filenameWithoutExtension;

    final separator = filenameWithoutExtension.indexOf(' - ');

    if (separator > 0) {
      fallbackArtist = filenameWithoutExtension.substring(0, separator).trim();
      fallbackTitle = filenameWithoutExtension.substring(separator + 3).trim();
    }

    final jsonTitle = json['title']?.toString().trim();
    final jsonArtist = json['artist']?.toString().trim();

    final title = jsonTitle != null && jsonTitle.isNotEmpty
        ? jsonTitle
        : fallbackTitle;

    final artist = jsonArtist != null && jsonArtist.isNotEmpty
        ? jsonArtist
        : fallbackArtist;

    final durationMs =
        (json['durationMs'] as num?)?.toInt() ??
        (lines.isEmpty ? 0 : lines.last.endMs);

    String? audioPath = json['audioPath']?.toString().trim();

    if (audioPath != null && audioPath.isEmpty) {
      audioPath = null;
    }

    return SyncedLyricsSong(
      songId: json['songId']?.toString().trim().isNotEmpty == true
          ? json['songId'].toString().trim()
          : _slugify('$artist-$title'),
      title: title,
      artist: artist,
      jsonPath: jsonPath,
      audioPath: audioPath,
      lines: lines,
      durationMs: durationMs,
      modifiedAt: modifiedAt,
    );
  }

  Future<SyncedLyricsSong?> findSongForTrackPath(String? trackPath) async {
    if (trackPath == null || trackPath.trim().isEmpty) {
      return null;
    }

    final songs = await loadLibrary();

    final trackNormalized = _normalizePath(trackPath);

    final trackFilename = _fileNameWithoutExtension(trackPath);

    //
    // First choice:
    // exact reference audio path.
    //
    for (final song in songs) {
      final audioPath = song.audioPath;

      if (audioPath == null || audioPath.isEmpty) {
        continue;
      }

      if (_normalizePath(audioPath) == trackNormalized) {
        return song;
      }
    }

    //
    // Second choice:
    // audio filename.
    //
    for (final song in songs) {
      final audioPath = song.audioPath;

      if (audioPath == null || audioPath.isEmpty) {
        continue;
      }

      if (_fileNameWithoutExtension(audioPath) == trackFilename) {
        return song;
      }
    }

    //
    // Compatibility for old JSON files.
    //
    for (final song in songs) {
      final title = _normalizeIdentityPart(song.title);

      final filename = _normalizeIdentityPart(trackFilename);

      if (title.isNotEmpty && filename.contains(title)) {
        return song;
      }
    }

    return null;
  }


  Future<SyncedLyricsSong?> findSongForMediaMetadata({
    required String title,
    String artist = '',
    String albumArtist = '',
  }) async {
    final songs = await loadLibrary();

    SyncedLyricsSong? bestSong;
    var bestScore = 0;

    for (final song in songs) {
      final score = mediaMetadataScoreForSong(
        song,
        title: title,
        artist: artist,
        albumArtist: albumArtist,
      );

      if (score > bestScore) {
        bestScore = score;
        bestSong = song;
      }
    }

    // Android/player metadata is only trusted when the SONG TITLE itself
    // produces a strong match. Artist/album fields are only supporting data.
    return bestScore >= 95 ? bestSong : null;
  }

  int mediaMetadataScoreForSong(
    SyncedLyricsSong song, {
    required String title,
    String artist = '',
    String albumArtist = '',
  }) {
    final mediaTitle = _normalizeMediaText(title);
    final songTitle = _normalizeMediaText(song.title);

    if (mediaTitle.isEmpty || songTitle.isEmpty) {
      return 0;
    }

    final mediaArtist = _normalizeMediaText(artist);
    final mediaAlbumArtist = _normalizeMediaText(albumArtist);
    final songArtist = _normalizeMediaText(song.artist);

    final titleExact = mediaTitle == songTitle;
    final titlePhraseMatch = _containsWholePhrase(mediaTitle, songTitle);

    final artistConfirmed = songArtist.isNotEmpty &&
        (mediaArtist == songArtist ||
            mediaAlbumArtist == songArtist ||
            _containsWholePhrase(mediaArtist, songArtist) ||
            _containsWholePhrase(mediaAlbumArtist, songArtist) ||
            _containsWholePhrase(mediaTitle, songArtist));

    // Exact title is authoritative. This intentionally still works when
    // YouTube/another Android player publishes garbage in ARTIST/ALBUM.
    if (titleExact) {
      return artistConfirmed ? 110 : 100;
    }

    // A common YouTube title is "Artist - Song (Official Video)". After
    // normalization, the song title must appear as a COMPLETE phrase.
    if (titlePhraseMatch) {
      return artistConfirmed ? 105 : 95;
    }

    return 0;
  }

  bool _containsWholePhrase(String source, String phrase) {
    if (source.isEmpty || phrase.isEmpty) return false;
    if (source == phrase) return true;

    final sourceTokens = source.split(' ');
    final phraseTokens = phrase.split(' ');

    if (phraseTokens.length > sourceTokens.length) return false;

    for (var i = 0; i <= sourceTokens.length - phraseTokens.length; i++) {
      var matches = true;
      for (var j = 0; j < phraseTokens.length; j++) {
        if (sourceTokens[i + j] != phraseTokens[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }

    return false;
  }

  String _normalizeMediaText(String value) {
    var normalized = value.toLowerCase();

    const noise = <String>[
      'official music video',
      'official video',
      'official audio',
      'official visualizer',
      'visualizer',
      'lyric video',
      'lyrics video',
      'lyrics',
      'audio',
      'video',
      'remastered',
      'remaster',
      'hd',
      '4k',
    ];

    for (final item in noise) {
      normalized = normalized.replaceAll(item, ' ');
    }

    normalized = normalized
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\[[^]]*\]'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return normalized;
  }

  int findActiveLineIndex(SyncedLyricsSong song, int positionMs) {
    if (song.lines.isEmpty) {
      return -1;
    }

    if (positionMs < song.lines.first.startMs) {
      return 0;
    }

    for (var i = song.lines.length - 1; i >= 0; i--) {
      if (positionMs >= song.lines[i].startMs) {
        return i;
      }
    }

    return 0;
  }

  int findNearestLineIndex(SyncedLyricsSong song, int positionMs) {
    return findActiveLineIndex(song, positionMs);
  }

  String _normalizePath(String path) {
    return path.replaceAll('\\', '/').toLowerCase().trim();
  }

  String _fileNameWithoutExtension(String path) {
    final normalized = path.replaceAll('\\', '/');

    var filename = normalized.split('/').last;

    final dot = filename.lastIndexOf('.');

    if (dot > 0) {
      filename = filename.substring(0, dot);
    }

    return filename.toLowerCase().trim();
  }

  String _normalizeIdentityPart(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String _slugify(String value) {
    var slug = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');

    slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');

    return slug;
  }
}
