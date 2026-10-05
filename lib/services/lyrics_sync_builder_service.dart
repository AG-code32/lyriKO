import 'dart:io';

import 'whisper_transcription_service.dart';

class SongBuildRequest {
  final String title;
  final String artist;
  final String audioPath;
  final String lyricsText;

  const SongBuildRequest({
    required this.title,
    required this.artist,
    required this.audioPath,
    required this.lyricsText,
  });
}

class LyricsSyncBuildResult {
  final bool success;
  final Duration elapsed;
  final String message;

  final String? songId;
  final String? lyricsPath;
  final String? jsonPath;

  const LyricsSyncBuildResult({
    required this.success,
    required this.elapsed,
    required this.message,
    this.songId,
    this.lyricsPath,
    this.jsonPath,
  });
}

class _LyricsAudioValidation {
  final bool accepted;

  final double bigramCoverage;
  final double trigramCoverage;
  final double distinctiveWordCoverage;

  final int transcriptWordCount;
  final Duration whisperTime;

  final String transcript;

  const _LyricsAudioValidation({
    required this.accepted,
    required this.bigramCoverage,
    required this.trigramCoverage,
    required this.distinctiveWordCoverage,
    required this.transcriptWordCount,
    required this.whisperTime,
    required this.transcript,
  });
}

class LyricsSyncBuilderService {
  final WhisperTranscriptionService _whisperService =
      WhisperTranscriptionService();

  String get _userProfile {
    final value = Platform.environment['USERPROFILE'];

    if (value == null || value.isEmpty) {
      throw StateError('Could not determine USERPROFILE.');
    }

    return value;
  }

  String get _projectRoot =>
      '$_userProfile\\Desktop\\'
      'fluter_projects\\Lyriko\\'
      'lyrics_app';

  String get _lyricsRoot => '$_projectRoot\\assets\\lyrics';

  String get _alignerRoot =>
      '$_userProfile\\Downloads\\'
      'lyriko-aligner';

  String get _alignerExe =>
      '$_alignerRoot\\Scripts\\'
      'ctc-forced-aligner.exe';

  String get _pythonExe =>
      '$_alignerRoot\\Scripts\\'
      'python.exe';

  String get _buildScript =>
      '$_projectRoot\\tools\\'
      'build_lyric_sync.py';

  String get _audfprintRoot =>
      '$_userProfile\\Downloads\\'
      'audfprint';

  String get _audfprintPython =>
      '$_audfprintRoot\\.venv\\'
      'Scripts\\python.exe';

  String get _audfprintScript =>
      '$_audfprintRoot\\'
      'audfprint.py';

  String get _fingerprintDatabase =>
      '$_audfprintRoot\\'
      'lyrics_fingerprint_db.pklz';

  //
  // =================================================
  // AUDIO ↔ LYRICS VALIDATION
  // =================================================
  //
  // These values are intentionally much lower than
  // 100%.
  //
  // Whisper is transcribing sung vocals, not clean
  // speech. It WILL make mistakes.
  //
  // A correct reference we already tested (Nobody)
  // still produces a substantial amount of matching
  // 2-word and 3-word phrases.
  //
  static const double _minimumBigramCoverage = 0.08;

  static const double _minimumTrigramCoverage = 0.03;

  static const double _minimumDistinctiveWordCoverage = 0.20;

  static const int _minimumWhisperWords = 12;

  static const Set<String> _commonWords = {
    'the',
    'and',
    'that',
    'this',
    'with',
    'from',
    'have',
    'what',
    'when',
    'where',
    'your',
    'you',
    'are',
    'was',
    'were',
    'been',
    'being',
    'but',
    'for',
    'not',
    'all',
    'our',
    'out',
    'into',
    'its',
    'his',
    'her',
    'she',
    'him',
    'they',
    'them',
    'their',
    'there',
    'here',
    'who',
    'why',
    'how',
    'can',
    'could',
    'would',
    'should',
    'will',
    'just',
    'like',
    'love',
    'yeah',
    'oh',
    'ooh',
    'ah',
    'im',
    'ive',
    'dont',
    'cant',
    'wont',
    'we',
    'me',
    'my',
    'i',
    'a',
    'an',
    'to',
    'of',
    'in',
    'on',
    'at',
    'is',
    'it',
    'as',
    'be',
    'so',
    'no',
  };

  Future<LyricsSyncBuildResult> buildSong(SongBuildRequest request) async {
    final watch = Stopwatch()..start();

    try {
      final title = request.title.trim();

      final artist = request.artist.trim();

      final audioPath = request.audioPath.trim();

      if (title.isEmpty) {
        throw StateError('Song title is required.');
      }

      if (artist.isEmpty) {
        throw StateError('Artist is required.');
      }

      if (audioPath.isEmpty) {
        throw StateError('Audio file is required.');
      }

      final audioFile = File(audioPath);

      if (!await audioFile.exists()) {
        throw StateError(
          'Audio file was not found:\n'
          '$audioPath',
        );
      }

      final cleanedLyrics = cleanLyrics(request.lyricsText);

      if (cleanedLyrics.isEmpty) {
        throw StateError(
          'No usable lyric lines '
          'were found.',
        );
      }

      await _validateDependencies();

      //
      // =============================================
      // STEP 0
      //
      // INDEPENDENT AUDIO / LYRICS VALIDATION
      // =============================================
      //
      // Whisper does NOT receive the lyrics.
      //
      // Therefore this test is independent of CTC.
      //
      final validation = await _validateLyricsAgainstAudio(
        audioPath: audioPath,
        lyrics: cleanedLyrics,
      );

      if (!validation.accepted) {
        final bigramPercent = (validation.bigramCoverage * 100).toStringAsFixed(
          1,
        );

        final trigramPercent = (validation.trigramCoverage * 100)
            .toStringAsFixed(1);

        final distinctivePercent = (validation.distinctiveWordCoverage * 100)
            .toStringAsFixed(1);

        throw StateError(
          'Lyrics validation failed.\n\n'
          'The pasted lyrics do not appear '
          'to belong to the selected audio.\n\n'
          'Whisper phrase match:\n'
          '• 2-word phrases: '
          '$bigramPercent%\n'
          '• 3-word phrases: '
          '$trigramPercent%\n'
          '• distinctive words: '
          '$distinctivePercent%\n\n'
          'Whisper detected '
          '${validation.transcriptWordCount} '
          'words from the audio.\n\n'
          'Please check that the MP3 and '
          'lyrics are from the same song.',
        );
      }

      final songId = _slugify('$artist-$title');

      final baseName =
          '${_safeFilePart(artist)}'
          ' - '
          '${_safeFilePart(title)}';

      final lyricsPath =
          '$_lyricsRoot\\'
          '$baseName.txt';

      final outputJsonPath =
          '$_lyricsRoot\\'
          '$baseName.json';

      await Directory(_lyricsRoot).create(recursive: true);

      await File(lyricsPath)
          .writeAsString('${cleanedLyrics.join('\n')}\n', flush: true);

      final alignedPath = _replaceExtension(audioPath, '.json');

      final oldAligned = File(alignedPath);

      if (await oldAligned.exists()) {
        await oldAligned.delete();
      }

      //
      // =============================================
      // STEP 1
      //
      // CTC FORCED ALIGNMENT
      // =============================================
      //
      final alignment = await Process.run(
        _alignerExe,
        [
          '--audio_path',
          audioPath,
          '--text_path',
          lyricsPath,
          '--language',
          'eng',
          '--romanize',
          '--split_size',
          'word',
        ],
        workingDirectory: _projectRoot,
        runInShell: false,
      );

      if (alignment.exitCode != 0) {
        throw StateError(
          'Forced alignment failed.'
          '\n\n'
          '${alignment.stdout}'
          '\n'
          '${alignment.stderr}',
        );
      }

      if (!await File(alignedPath).exists()) {
        throw StateError(
          'Forced aligner finished '
          'but the expected JSON '
          'was not created:\n'
          '$alignedPath',
        );
      }

      //
      // =============================================
      // STEP 2
      //
      // CREATE LYRIKO JSON
      // =============================================
      //
      final build = await Process.run(
        _pythonExe,
        [
          _buildScript,
          '--lyrics',
          lyricsPath,
          '--aligned',
          alignedPath,
          '--output',
          outputJsonPath,
          '--song-id',
          songId,
          '--title',
          title,
          '--artist',
          artist,
          '--audio',
          audioPath,
        ],
        workingDirectory: _projectRoot,
        runInShell: false,
      );

      if (build.exitCode != 0) {
        throw StateError(
          'Sync JSON generation failed.'
          '\n\n'
          '${build.stdout}'
          '\n'
          '${build.stderr}',
        );
      }

      //
      // =============================================
      // STEP 3
      //
      // REGISTER AUDFPRINT
      // =============================================
      //
      await _registerFingerprint(audioPath);

      watch.stop();

      final bigramPercent = (validation.bigramCoverage * 100).toStringAsFixed(
        1,
      );

      final trigramPercent = (validation.trigramCoverage * 100).toStringAsFixed(
        1,
      );

      return LyricsSyncBuildResult(
        success: true,

        elapsed: watch.elapsed,

        message:
            '$artist - $title '
            'created successfully.\n'
            'Lyrics/audio validation: '
            '$bigramPercent% phrase match '
            '(2-word), '
            '$trigramPercent% '
            '(3-word).',

        songId: songId,

        lyricsPath: lyricsPath,

        jsonPath: outputJsonPath,
      );
    } catch (e) {
      watch.stop();

      return LyricsSyncBuildResult(
        success: false,

        elapsed: watch.elapsed,

        message: e.toString(),
      );
    }
  }

  //
  // =================================================
  // WHISPER VALIDATION
  // =================================================
  //

  Future<_LyricsAudioValidation> _validateLyricsAgainstAudio({
    required String audioPath,
    required List<String> lyrics,
  }) async {
    final whisper = await _whisperService.transcribe(audioPath);

    final transcript = whisper.text.trim();

    final lyricText = lyrics.join(' ');

    final lyricTokens = _tokenize(lyricText);

    final transcriptTokens = _tokenize(transcript);

    if (transcriptTokens.length < _minimumWhisperWords) {
      throw StateError(
        'Lyrics validation could not be completed.\n\n'
        'Whisper detected only '
        '${transcriptTokens.length} usable words '
        'from the selected audio.\n\n'
        'The vocals may be too quiet, the song may '
        'contain a long instrumental section, or '
        'the audio may not be suitable for automatic '
        'validation.',
      );
    }

    final bigramCoverage = _ngramCoverage(
      source: lyricTokens,
      target: transcriptTokens,
      size: 2,
    );

    final trigramCoverage = _ngramCoverage(
      source: lyricTokens,
      target: transcriptTokens,
      size: 3,
    );

    final distinctiveCoverage = _distinctiveWordCoverage(
      lyricTokens,
      transcriptTokens,
    );

    //
    // We require evidence at phrase level.
    //
    // Individual words alone are too easy to match
    // accidentally between two unrelated songs.
    //
    final phraseEvidence =
        bigramCoverage >= _minimumBigramCoverage &&
        trigramCoverage >= _minimumTrigramCoverage;

    //
    // Distinctive-word coverage provides a second
    // path because Whisper can occasionally break
    // phrases while still hearing the important
    // words correctly.
    //
    final strongWordEvidence =
        distinctiveCoverage >= _minimumDistinctiveWordCoverage &&
        bigramCoverage >= 0.05;

    final accepted = phraseEvidence || strongWordEvidence;

    return _LyricsAudioValidation(
      accepted: accepted,

      bigramCoverage: bigramCoverage,

      trigramCoverage: trigramCoverage,

      distinctiveWordCoverage: distinctiveCoverage,

      transcriptWordCount: transcriptTokens.length,

      whisperTime: whisper.processingTime,

      transcript: transcript,
    );
  }

  List<String> _tokenize(String text) {
    var normalized = text.toLowerCase();

    normalized = normalized.replaceAll('’', "'");

    normalized = normalized.replaceAll(RegExp(r"[^a-z0-9']+"), ' ');

    return normalized
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList();
  }

  double _ngramCoverage({
    required List<String> source,
    required List<String> target,
    required int size,
  }) {
    if (source.length < size || target.length < size) {
      return 0;
    }

    final targetNgrams = <String>{};

    for (var i = 0; i <= target.length - size; i++) {
      targetNgrams.add(target.sublist(i, i + size).join('\u0001'));
    }

    var total = 0;

    var matched = 0;

    for (var i = 0; i <= source.length - size; i++) {
      final ngram = source.sublist(i, i + size).join('\u0001');

      total++;

      if (targetNgrams.contains(ngram)) {
        matched++;
      }
    }

    if (total == 0) {
      return 0;
    }

    return matched / total;
  }

  double _distinctiveWordCoverage(
    List<String> lyrics,
    List<String> transcript,
  ) {
    final lyricWords = lyrics
        .where((word) => word.length >= 5 && !_commonWords.contains(word))
        .toSet();

    if (lyricWords.isEmpty) {
      return 0;
    }

    final transcriptWords = transcript.toSet();

    var matched = 0;

    for (final lyricWord in lyricWords) {
      if (transcriptWords.contains(lyricWord)) {
        matched++;

        continue;
      }

      //
      // Whisper often gets a sung word nearly right.
      //
      // Examples:
      // wondering / wandering
      // shedding / shading
      //
      var fuzzyMatch = false;

      for (final transcriptWord in transcriptWords) {
        if (transcriptWord.length < 4) {
          continue;
        }

        if (_wordSimilarity(lyricWord, transcriptWord) >= 0.80) {
          fuzzyMatch = true;

          break;
        }
      }

      if (fuzzyMatch) {
        matched++;
      }
    }

    return matched / lyricWords.length;
  }

  double _wordSimilarity(String a, String b) {
    if (a == b) {
      return 1;
    }

    final distance = _levenshtein(a, b);

    final longest = a.length > b.length ? a.length : b.length;

    if (longest == 0) {
      return 1;
    }

    return 1 - distance / longest;
  }

  int _levenshtein(String a, String b) {
    if (a.isEmpty) {
      return b.length;
    }

    if (b.isEmpty) {
      return a.length;
    }

    var previous = List<int>.generate(b.length + 1, (index) => index);

    for (var i = 0; i < a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0);

      current[0] = i + 1;

      for (var j = 0; j < b.length; j++) {
        final insertion = current[j] + 1;

        final deletion = previous[j + 1] + 1;

        final substitution = previous[j] + (a[i] == b[j] ? 0 : 1);

        var best = insertion;

        if (deletion < best) {
          best = deletion;
        }

        if (substitution < best) {
          best = substitution;
        }

        current[j + 1] = best;
      }

      previous = current;
    }

    return previous[b.length];
  }

  //
  // =================================================
  // CLEAN LYRICS
  // =================================================
  //

  List<String> cleanLyrics(String raw) {
    final result = <String>[];

    for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
      final line = rawLine
          .replaceAll('\u00A0', ' ')
          .replaceAll(RegExp(r'[ \t]+'), ' ')
          .trim();

      if (line.isEmpty) {
        continue;
      }

      if (_isSectionLabel(line)) {
        continue;
      }

      result.add(line);
    }

    return result;
  }

  bool _isSectionLabel(String line) {
    return RegExp(
      r'^\[(verse|chorus|'
      r'pre-chorus|prechorus|'
      r'bridge|intro|outro|'
      r'hook|refrain|'
      r'instrumental|interlude|'
      r'breakdown|solo)'
      r'(?:[^\]]*)\]$',
      caseSensitive: false,
    ).hasMatch(line);
  }

  //
  // =================================================
  // AUDFPRINT
  // =================================================
  //

  Future<void> _registerFingerprint(String audioPath) async {
    final databaseFile = File(_fingerprintDatabase);

    if (!await databaseFile.exists()) {
      final create = await Process.run(
        _audfprintPython,
        [_audfprintScript, 'new', '-d', _fingerprintDatabase, audioPath],
        workingDirectory: _audfprintRoot,
        runInShell: false,
      );

      if (create.exitCode != 0) {
        throw StateError(
          'Fingerprint database '
          'creation failed.'
          '\n\n'
          '${create.stdout}'
          '\n'
          '${create.stderr}',
        );
      }

      return;
    }

    final list = await Process.run(
      _audfprintPython,
      [_audfprintScript, 'list', '-d', _fingerprintDatabase],
      workingDirectory: _audfprintRoot,
      runInShell: false,
    );

    final listing =
        '${list.stdout}\n'
                '${list.stderr}'
            .toLowerCase();

    final normalizedAudio = audioPath.replaceAll('\\', '/').toLowerCase();

    final audioName = normalizedAudio.split('/').last;

    if (listing.contains(normalizedAudio) || listing.contains(audioName)) {
      return;
    }

    final add = await Process.run(
      _audfprintPython,
      [_audfprintScript, 'add', '-d', _fingerprintDatabase, audioPath],
      workingDirectory: _audfprintRoot,
      runInShell: false,
    );

    if (add.exitCode != 0) {
      throw StateError(
        'Fingerprint registration failed.'
        '\n\n'
        '${add.stdout}'
        '\n'
        '${add.stderr}',
      );
    }
  }

  //
  // =================================================
  // DEPENDENCIES
  // =================================================
  //

  Future<void> _validateDependencies() async {
    final requiredFiles = {
      'Forced aligner': _alignerExe,

      'Aligner Python': _pythonExe,

      'Build script': _buildScript,

      'audfprint Python': _audfprintPython,

      'audfprint.py': _audfprintScript,
    };

    for (final entry in requiredFiles.entries) {
      if (!await File(entry.value).exists()) {
        throw StateError(
          '${entry.key} '
          'was not found:\n'
          '${entry.value}',
        );
      }
    }
  }

  String _safeFilePart(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (cleaned.isEmpty) {
      return 'Unknown';
    }

    return cleaned;
  }

  String _slugify(String value) {
    var slug = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');

    slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');

    return slug.isEmpty
        ? 'song-'
              '${DateTime.now().millisecondsSinceEpoch}'
        : slug;
  }

  String _replaceExtension(String path, String extension) {
    final slashBack = path.lastIndexOf('\\');

    final slashForward = path.lastIndexOf('/');

    final slash = slashBack > slashForward ? slashBack : slashForward;

    final dot = path.lastIndexOf('.');

    if (dot > slash) {
      return '${path.substring(0, dot)}$extension';
    }

    return '$path$extension';
  }

  //
  // =================================================
  // LEGACY NOBODY BUTTON SUPPORT
  // =================================================
  //

  Future<LyricsSyncBuildResult> rebuildNobody() async {
    const audioPath =
        r'F:\Nueva carpeta\Avenged Sevenfold - Life Is But A Dream (2023) Mp3 320kbps (PMEDIA)\03. Nobody.mp3';

    final lyricsFile = File(
      '$_lyricsRoot\\'
      'Avenged Sevenfold - Nobody.txt',
    );

    if (!await lyricsFile.exists()) {
      return const LyricsSyncBuildResult(
        success: false,

        elapsed: Duration.zero,

        message:
            'Nobody lyrics file '
            'was not found.',
      );
    }

    final lyricsText = await lyricsFile.readAsString();

    return buildSong(
      SongBuildRequest(
        title: 'Nobody',

        artist: 'Avenged Sevenfold',

        audioPath: audioPath,

        lyricsText: lyricsText,
      ),
    );
  }
}
