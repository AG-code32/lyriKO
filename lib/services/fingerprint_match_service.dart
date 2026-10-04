import 'dart:convert';
import 'dart:io';

class FingerprintMatchResult {
  final bool matched;
  final String? trackPath;
  final double? offsetSeconds;
  final int? alignedHashes;
  final int? commonHashes;
  final Duration processingTime;
  final String rawOutput;

  const FingerprintMatchResult({
    required this.matched,
    required this.trackPath,
    required this.offsetSeconds,
    required this.alignedHashes,
    required this.commonHashes,
    required this.processingTime,
    required this.rawOutput,
  });

  String? get trackName {
    if (trackPath == null) {
      return null;
    }

    final normalized =
        trackPath!.replaceAll('\\', '/');

    final fileName =
        normalized.split('/').last;

    final dot =
        fileName.lastIndexOf('.');

    if (dot <= 0) {
      return fileName;
    }

    return fileName.substring(0, dot);
  }
}

class FingerprintMatchService {
  String get _userProfile {
    final path =
        Platform.environment['USERPROFILE'];

    if (path == null || path.isEmpty) {
      throw StateError(
        'Could not determine the Windows user folder.',
      );
    }

    return path;
  }

  String get _audfprintRoot =>
      '$_userProfile\\Downloads\\audfprint';

  String get _pythonExe =>
      '$_audfprintRoot\\.venv\\Scripts\\python.exe';

  String get _audfprintScript =>
      '$_audfprintRoot\\audfprint.py';

  String get _databasePath =>
      '$_audfprintRoot\\lyrics_fingerprint_db.pklz';

  Future<FingerprintMatchResult> matchEightSeconds(
    String capturedWavPath,
  ) async {
    await _validateDependencies();

    final source =
        File(capturedWavPath);

    if (!await source.exists()) {
      throw StateError(
        'Captured WAV was not found:\n'
        '$capturedWavPath',
      );
    }

    final queryPath =
        '${Directory.systemTemp.path}\\'
        'fingerprint_query_8s.wav';

    try {
      await _createQuery(
        inputPath: capturedWavPath,
        outputPath: queryPath,
      );

      return await _match(
        queryPath,
      );
    } finally {
      await _safeDelete(
        queryPath,
      );
    }
  }

  Future<void> _createQuery({
    required String inputPath,
    required String outputPath,
  }) async {
    final result =
        await Process.run(
      'ffmpeg',
      [
        '-y',
        '-loglevel',
        'error',
        '-i',
        inputPath,

        // Use the complete 8-second capture.
        '-t',
        '8',

        // Normalize to a small mono WAV
        // suitable for fingerprinting.
        '-ar',
        '11025',
        '-ac',
        '1',
        '-c:a',
        'pcm_s16le',

        outputPath,
      ],
      runInShell: true,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (result.exitCode != 0) {
      throw StateError(
        'FFmpeg failed creating '
        'the 8-second fingerprint query.\n\n'
        '${result.stderr}',
      );
    }

    if (!await File(
      outputPath,
    ).exists()) {
      throw StateError(
        'FFmpeg did not create:\n'
        '$outputPath',
      );
    }
  }

  Future<FingerprintMatchResult> _match(
    String queryPath,
  ) async {
    final watch =
        Stopwatch()..start();

    final result =
        await Process.run(
      _pythonExe,
      [
        _audfprintScript,
        'match',
        '--dbase',
        _databasePath,
        queryPath,
      ],
      workingDirectory:
          _audfprintRoot,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    watch.stop();

    final output =
        '${result.stdout}\n${result.stderr}'
            .trim();

    if (result.exitCode != 0) {
      throw StateError(
        'audfprint match failed.\n\n$output',
      );
    }

    final match = RegExp(
      r'Matched\s+.+?\s+as\s+(.+?)\s+at\s+'
      r'([0-9.]+)\s+s\s+with\s+'
      r'(\d+)\s+of\s+(\d+)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(output);

    if (match == null) {
      return FingerprintMatchResult(
        matched: false,
        trackPath: null,
        offsetSeconds: null,
        alignedHashes: null,
        commonHashes: null,
        processingTime:
            watch.elapsed,
        rawOutput: output,
      );
    }

    return FingerprintMatchResult(
      matched: true,
      trackPath:
          match.group(1)?.trim(),
      offsetSeconds:
          double.tryParse(
        match.group(2) ?? '',
      ),
      alignedHashes:
          int.tryParse(
        match.group(3) ?? '',
      ),
      commonHashes:
          int.tryParse(
        match.group(4) ?? '',
      ),
      processingTime:
          watch.elapsed,
      rawOutput: output,
    );
  }

  Future<void> _validateDependencies() async {
    if (!await File(
      _pythonExe,
    ).exists()) {
      throw StateError(
        'audfprint Python environment '
        'was not found at:\n'
        '$_pythonExe',
      );
    }

    if (!await File(
      _audfprintScript,
    ).exists()) {
      throw StateError(
        'audfprint.py was not found at:\n'
        '$_audfprintScript',
      );
    }

    if (!await File(
      _databasePath,
    ).exists()) {
      throw StateError(
        'Fingerprint database '
        'was not found at:\n'
        '$_databasePath',
      );
    }
  }

  Future<void> _safeDelete(
    String path,
  ) async {
    try {
      final file =
          File(path);

      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Temporary cleanup must not fail the test.
    }
  }
}