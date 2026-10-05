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
  final int acceptedSamples;
  final int strongSamples;
  final int evaluatedSamples;

  final Duration whisperTime;

  final String transcript;

  const _LyricsAudioValidation({
    required this.accepted,
    required this.bigramCoverage,
    required this.trigramCoverage,
    required this.distinctiveWordCoverage,
    required this.transcriptWordCount,
    required this.acceptedSamples,
    required this.strongSamples,
    required this.evaluatedSamples,
    required this.whisperTime,
    required this.transcript,
  });
}

class _WhisperSampleScore {
  final String transcript;
  final int wordCount;

  final double bigramCoverage;
  final double trigramCoverage;
  final double distinctiveWordCoverage;

  final bool accepted;
  final bool strong;

  final Duration processingTime;

  const _WhisperSampleScore({
    required this.transcript,
    required this.wordCount,
    required this.bigramCoverage,
    required this.trigramCoverage,
    required this.distinctiveWordCoverage,
    required this.accepted,
    required this.strong,
    required this.processingTime,
  });

  double get rankingScore {
    return bigramCoverage * 0.45 +
        trigramCoverage * 0.30 +
        distinctiveWordCoverage * 0.25;
  }
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
  static const int _sampleDurationSeconds = 15;

  static const int _desiredSampleCount = 4;

  static const int _absoluteMinimumWhisperWords = 5;

  static const int _minimumSampleWords = 4;

  //
  // A normal sample is useful when it has both phrase-level
  // evidence and/or enough distinctive words.
  //
  static const double _minimumSampleBigramCoverage = 0.12;

  static const double _minimumSampleTrigramCoverage = 0.05;

  static const double _minimumSampleDistinctiveCoverage = 0.35;

  //
  // One very strong sample is enough to validate the song.
  //
  static const double _strongSampleBigramCoverage = 0.30;

  static const double _strongSampleTrigramCoverage = 0.15;

  static const double _strongSampleDistinctiveCoverage = 0.60;

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
          'Best Whisper sample:\n'
          '• 2-word phrases: '
          '$bigramPercent%\n'
          '• 3-word phrases: '
          '$trigramPercent%\n'
          '• distinctive words: '
          '$distinctivePercent%\n\n'
          'Samples accepted: '
          '${validation.acceptedSamples}/'
          '${validation.evaluatedSamples}\n'
          'Strong samples: '
          '${validation.strongSamples}\n\n'
          'Whisper detected '
          '${validation.transcriptWordCount} '
          'usable words across the sampled audio.\n\n'
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
            '${validation.acceptedSamples}/'
            '${validation.evaluatedSamples} samples matched. '
            'Best sample: '
            '$bigramPercent% bigram, '
            '$trigramPercent% trigram.',

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
    final durationSeconds = await _readAudioDurationSeconds(
      audioPath,
    );

    if (durationSeconds <= 0) {
      throw StateError(
        'Could not determine audio duration.',
      );
    }

    final lyricTokens = _tokenize(
      lyrics.join(' '),
    );

    if (lyricTokens.isEmpty) {
      throw StateError(
        'Lyrics validation received no usable lyric words.',
      );
    }

    final sampleStarts = _buildSampleStarts(
      durationSeconds,
    );

    final scores = <_WhisperSampleScore>[];

    final transcripts = <String>[];

    var totalWords = 0;

    var totalWhisperTime = Duration.zero;

    for (var i = 0; i < sampleStarts.length; i++) {
      String? samplePath;

      try {
        samplePath = await _createValidationSample(
          audioPath: audioPath,
          startSeconds: sampleStarts[i],
          sampleIndex: i,
        );

        final whisper = await _whisperService.transcribePrepared(
          samplePath,
        );

        totalWhisperTime += whisper.processingTime;

        final transcript = whisper.text.trim();

        final transcriptTokens = _tokenize(
          transcript,
        );

        totalWords += transcriptTokens.length;

        if (transcript.isNotEmpty) {
          transcripts.add(transcript);
        }

        if (transcriptTokens.length < _minimumSampleWords) {
          continue;
        }

        final bigramCoverage = _heardNgramCoverage(
          heard: transcriptTokens,
          lyrics: lyricTokens,
          size: 2,
        );

        final trigramCoverage = _heardNgramCoverage(
          heard: transcriptTokens,
          lyrics: lyricTokens,
          size: 3,
        );

        final distinctiveCoverage = _heardDistinctiveWordCoverage(
          heard: transcriptTokens,
          lyrics: lyricTokens,
        );

        final phraseEvidence =
            bigramCoverage >= _minimumSampleBigramCoverage &&
            trigramCoverage >= _minimumSampleTrigramCoverage;

        final wordEvidence =
            distinctiveCoverage >= _minimumSampleDistinctiveCoverage &&
            bigramCoverage >= 0.08;

        final accepted = phraseEvidence || wordEvidence;

        final strongPhraseEvidence =
            bigramCoverage >= _strongSampleBigramCoverage &&
            trigramCoverage >= _strongSampleTrigramCoverage;

        final strongWordEvidence =
            distinctiveCoverage >= _strongSampleDistinctiveCoverage &&
            bigramCoverage >= 0.15;

        final strong = strongPhraseEvidence || strongWordEvidence;

        scores.add(
          _WhisperSampleScore(
            transcript: transcript,
            wordCount: transcriptTokens.length,
            bigramCoverage: bigramCoverage,
            trigramCoverage: trigramCoverage,
            distinctiveWordCoverage: distinctiveCoverage,
            accepted: accepted,
            strong: strong,
            processingTime: whisper.processingTime,
          ),
        );
      } catch (_) {
        //
        // One difficult sample should not reject the entire song.
        // Other sections may still provide enough evidence.
        //
      } finally {
        if (samplePath != null) {
          await _deleteTemporaryFile(
            samplePath,
          );
        }
      }
    }

    if (totalWords < _absoluteMinimumWhisperWords) {
      throw StateError(
        'Lyrics validation could not be completed.\n\n'
        'Whisper detected only '
        '$totalWords usable words across '
        '${sampleStarts.length} sampled parts of the song.\n\n'
        'The vocals may be too quiet, the song may contain '
        'long instrumental sections, or the audio may not be '
        'suitable for automatic validation.',
      );
    }

    if (scores.isEmpty) {
      throw StateError(
        'Lyrics validation could not obtain '
        'a usable Whisper sample.',
      );
    }

    scores.sort(
      (a, b) => b.rankingScore.compareTo(
        a.rankingScore,
      ),
    );

    final best = scores.first;

    final acceptedSamples = scores
        .where(
          (score) => score.accepted,
        )
        .length;

    final strongSamples = scores
        .where(
          (score) => score.strong,
        )
        .length;

    final accepted =
        acceptedSamples >= 2 ||
        strongSamples >= 1;

    return _LyricsAudioValidation(
      accepted: accepted,
      bigramCoverage: best.bigramCoverage,
      trigramCoverage: best.trigramCoverage,
      distinctiveWordCoverage: best.distinctiveWordCoverage,
      transcriptWordCount: totalWords,
      acceptedSamples: acceptedSamples,
      strongSamples: strongSamples,
      evaluatedSamples: scores.length,
      whisperTime: totalWhisperTime,
      transcript: transcripts.join(' '),
    );
  }

  Future<double> _readAudioDurationSeconds(
    String audioPath,
  ) async {
    final result = await Process.run(
      'ffprobe',
      [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        audioPath,
      ],
      runInShell: true,
    );

    if (result.exitCode != 0) {
      throw StateError(
        'FFprobe could not read audio duration.\n\n'
        '${result.stderr}',
      );
    }

    return double.tryParse(
          result.stdout.toString().trim(),
        ) ??
        0;
  }

  List<double> _buildSampleStarts(
    double durationSeconds,
  ) {
    final sampleDuration = _sampleDurationSeconds.toDouble();

    if (durationSeconds <= sampleDuration + 2) {
      return [
        0,
      ];
    }

    final maximumStart =
        durationSeconds - sampleDuration;

    const fractions = <double>[
      0.10,
      0.32,
      0.56,
      0.78,
    ];

    final starts = <double>[];

    for (final fraction in fractions) {
      final start =
          (durationSeconds * fraction)
              .clamp(
                0.0,
                maximumStart,
              )
              .toDouble();

      final tooClose = starts.any(
        (existing) =>
            (existing - start).abs() < 5,
      );

      if (!tooClose) {
        starts.add(start);
      }

      if (starts.length >= _desiredSampleCount) {
        break;
      }
    }

    if (starts.isEmpty) {
      starts.add(0);
    }

    return starts;
  }

  Future<String> _createValidationSample({
    required String audioPath,
    required double startSeconds,
    required int sampleIndex,
  }) async {
    final timestamp =
        DateTime.now().microsecondsSinceEpoch;

    final outputPath =
        '${Directory.systemTemp.path}'
        '\\lyriko_validation_${timestamp}_$sampleIndex.wav';

    final result = await Process.run(
      'ffmpeg',
      [
        '-y',
        '-loglevel',
        'error',
        '-ss',
        startSeconds.toStringAsFixed(3),
        '-i',
        audioPath,
        '-t',
        _sampleDurationSeconds.toString(),
        '-ar',
        '16000',
        '-ac',
        '1',
        '-c:a',
        'pcm_s16le',
        outputPath,
      ],
      runInShell: true,
    );

    if (result.exitCode != 0) {
      throw StateError(
        'Could not create Whisper validation sample.\n\n'
        '${result.stderr}',
      );
    }

    final file = File(
      outputPath,
    );

    if (!await file.exists()) {
      throw StateError(
        'FFmpeg did not create the Whisper validation sample.',
      );
    }

    return outputPath;
  }

  Future<void> _deleteTemporaryFile(
    String path,
  ) async {
    try {
      final file = File(
        path,
      );

      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Temporary cleanup is not critical.
    }
  }

  List<String> _tokenize(String text) {
    var normalized = text.toLowerCase();

    normalized = normalized.replaceAll(
      '’',
      "'",
    );

    normalized = normalized.replaceAll(
      RegExp(r"[^a-z0-9']+"),
      ' ',
    );

    return normalized
        .split(
          RegExp(r'\s+'),
        )
        .map(
          (token) => token.trim(),
        )
        .where(
          (token) => token.isNotEmpty,
        )
        .toList();
  }

  //
  // We evaluate the phrases Whisper actually heard.
  //
  // This avoids penalizing a 15-second sample for not containing
  // every phrase from the complete song.
  //
  double _heardNgramCoverage({
    required List<String> heard,
    required List<String> lyrics,
    required int size,
  }) {
    if (heard.length < size || lyrics.length < size) {
      return 0;
    }

    final lyricNgrams = <String>{};

    for (var i = 0; i <= lyrics.length - size; i++) {
      lyricNgrams.add(
        lyrics
            .sublist(
              i,
              i + size,
            )
            .join('\u0001'),
      );
    }

    var total = 0;

    var matched = 0;

    for (var i = 0; i <= heard.length - size; i++) {
      final ngram = heard
          .sublist(
            i,
            i + size,
          )
          .join('\u0001');

      total++;

      if (lyricNgrams.contains(ngram)) {
        matched++;
      }
    }

    if (total == 0) {
      return 0;
    }

    return matched / total;
  }

  double _heardDistinctiveWordCoverage({
    required List<String> heard,
    required List<String> lyrics,
  }) {
    final heardWords = heard
        .where(
          (word) =>
              word.length >= 5 &&
              !_commonWords.contains(word),
        )
        .toSet();

    if (heardWords.isEmpty) {
      return 0;
    }

    final lyricWords = lyrics.toSet();

    var matched = 0;

    for (final heardWord in heardWords) {
      if (lyricWords.contains(heardWord)) {
        matched++;
        continue;
      }

      var fuzzyMatch = false;

      for (final lyricWord in lyricWords) {
        if (lyricWord.length < 4) {
          continue;
        }

        if (_wordSimilarity(
              heardWord,
              lyricWord,
            ) >=
            0.80) {
          fuzzyMatch = true;
          break;
        }
      }

      if (fuzzyMatch) {
        matched++;
      }
    }

    return matched / heardWords.length;
  }

  double _wordSimilarity(String a, String b) {
    if (a == b) {
      return 1;
    }

    final distance = _levenshtein(
      a,
      b,
    );

    final longest =
        a.length > b.length
        ? a.length
        : b.length;

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

    var previous = List<int>.generate(
      b.length + 1,
      (index) => index,
    );

    for (var i = 0; i < a.length; i++) {
      final current = List<int>.filled(
        b.length + 1,
        0,
      );

      current[0] = i + 1;

      for (var j = 0; j < b.length; j++) {
        final insertion = current[j] + 1;

        final deletion = previous[j + 1] + 1;

        final substitution =
            previous[j] +
            (a[i] == b[j] ? 0 : 1);

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
