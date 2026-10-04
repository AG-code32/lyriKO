import 'dart:io';

class LyricsSyncBuildResult {
  final bool success;
  final Duration elapsed;
  final String message;

  const LyricsSyncBuildResult({
    required this.success,
    required this.elapsed,
    required this.message,
  });
}

class LyricsSyncBuilderService {
  String get _userProfile {
    final value =
        Platform.environment['USERPROFILE'];

    if (value == null || value.isEmpty) {
      throw StateError(
        'Could not determine USERPROFILE.',
      );
    }

    return value;
  }

  String get _projectRoot =>
      '$_userProfile\\Desktop\\fluter_projects\\Lyriko\\lyrics_app';

  String get _alignerRoot =>
      '$_userProfile\\Downloads\\lyriko-aligner';

  String get _alignerExe =>
      '$_alignerRoot\\Scripts\\ctc-forced-aligner.exe';

  String get _pythonExe =>
      '$_alignerRoot\\Scripts\\python.exe';

  String get _lyricsPath =>
      '$_projectRoot\\assets\\lyrics\\Avenged Sevenfold - Nobody.txt';

  String get _buildScript =>
      '$_projectRoot\\tools\\build_lyric_sync.py';

  String get _albumRoot =>
      r'F:\Nueva carpeta\Avenged Sevenfold - Life Is But A Dream (2023) Mp3 320kbps (PMEDIA)';

  Future<String> _findNobodyMp3() async {
    final directory =
        Directory(_albumRoot);

    if (!await directory.exists()) {
      throw StateError(
        'Album folder was not found:\n$_albumRoot',
      );
    }

    await for (final entity
        in directory.list(
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
      'Nobody MP3 was not found inside:\n$_albumRoot',
    );
  }

  Future<void> _validate() async {
    final requiredFiles = {
      'Forced aligner':
          _alignerExe,
      'Python':
          _pythonExe,
      'Lyrics':
          _lyricsPath,
      'Build script':
          _buildScript,
    };

    for (final entry
        in requiredFiles.entries) {
      if (!await File(
        entry.value,
      ).exists()) {
        throw StateError(
          '${entry.key} was not found:\n'
          '${entry.value}',
        );
      }
    }
  }

  Future<LyricsSyncBuildResult>
      rebuildNobody() async {
    final watch =
        Stopwatch()..start();

    try {
      await _validate();

      final mp3Path =
          await _findNobodyMp3();

      //
      // STEP 1:
      // forced alignment
      //
      final alignment =
          await Process.run(
        _alignerExe,
        [
          '--audio_path',
          mp3Path,
          '--text_path',
          _lyricsPath,
          '--language',
          'eng',
          '--romanize',
          '--split_size',
          'word',
        ],
        workingDirectory:
            _projectRoot,
        runInShell: false,
      );

      if (alignment.exitCode != 0) {
        watch.stop();

        return LyricsSyncBuildResult(
          success: false,
          elapsed:
              watch.elapsed,
          message:
              'Forced alignment failed.\n\n'
              '${alignment.stdout}\n'
              '${alignment.stderr}',
        );
      }

      //
      // STEP 2:
      // convert forced-alignment output
      // into Lyriko JSON.
      //
      final build =
          await Process.run(
        _pythonExe,
        [
          _buildScript,
        ],
        workingDirectory:
            _projectRoot,
        runInShell: false,
      );

      if (build.exitCode != 0) {
        watch.stop();

        return LyricsSyncBuildResult(
          success: false,
          elapsed:
              watch.elapsed,
          message:
              'Sync JSON generation failed.\n\n'
              '${build.stdout}\n'
              '${build.stderr}',
        );
      }

      watch.stop();

      return LyricsSyncBuildResult(
        success: true,
        elapsed:
            watch.elapsed,
        message:
            'Nobody sync rebuilt successfully.',
      );
    } catch (e) {
      watch.stop();

      return LyricsSyncBuildResult(
        success: false,
        elapsed:
            watch.elapsed,
        message:
            e.toString(),
      );
    }
  }
}