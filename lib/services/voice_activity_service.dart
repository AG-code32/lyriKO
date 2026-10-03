import 'dart:convert';
import 'dart:io';

class VoiceActivityResult {
  final bool hasVoice;
  final int segmentCount;

  const VoiceActivityResult({
    required this.hasVoice,
    required this.segmentCount,
  });
}

class VoiceActivityService {
  String get _userProfile {
    final path = Platform.environment['USERPROFILE'];

    if (path == null || path.isEmpty) {
      throw StateError(
        'Could not determine the Windows user folder.',
      );
    }

    return path;
  }

  String get _whisperRoot =>
      '$_userProfile\\Downloads\\whisper.cpp';

  String get _whisperExecutable =>
      '$_whisperRoot\\build\\bin\\Release\\whisper-cli.exe';

  String get _whisperModel =>
      '$_whisperRoot\\models\\ggml-base.en.bin';

  String get _vadModel =>
      '$_whisperRoot\\models\\ggml-silero-v6.2.0.bin';

  Future<VoiceActivityResult> detectVoice(
    String wavPath,
  ) async {
    await _validateDependencies();

    final audioFile = File(wavPath);

    if (!await audioFile.exists()) {
      throw StateError(
        'VAD input audio does not exist:\n$wavPath',
      );
    }

    final result = await Process.run(
      _whisperExecutable,
      [
        '-m',
        _whisperModel,
        '-f',
        wavPath,
        '-l',
        'en',
        '--vad',
        '-vm',
        _vadModel,

        // Keep console output simple.
        '-nt',
      ],
      workingDirectory: _whisperRoot,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (result.exitCode != 0) {
      throw StateError(
        'VAD check failed.\n\n'
        '${result.stderr}',
      );
    }

    final combinedOutput =
        '${result.stdout}\n${result.stderr}';

    final match = RegExp(
      r'detected\s+(\d+)\s+speech segments',
      caseSensitive: false,
    ).firstMatch(combinedOutput);

    if (match == null) {
      return const VoiceActivityResult(
        hasVoice: false,
        segmentCount: 0,
      );
    }

    final count =
        int.tryParse(
          match.group(1) ?? '0',
        ) ??
        0;

    return VoiceActivityResult(
      hasVoice: count > 0,
      segmentCount: count,
    );
  }

  Future<void> _validateDependencies() async {
    if (!await File(
      _whisperExecutable,
    ).exists()) {
      throw StateError(
        'whisper-cli.exe was not found at:\n'
        '$_whisperExecutable',
      );
    }

    if (!await File(
      _whisperModel,
    ).exists()) {
      throw StateError(
        'Whisper model was not found at:\n'
        '$_whisperModel',
      );
    }

    if (!await File(
      _vadModel,
    ).exists()) {
      throw StateError(
        'Silero VAD model was not found at:\n'
        '$_vadModel',
      );
    }
  }
}