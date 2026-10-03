import 'dart:convert';
import 'dart:io';

class WhisperTranscriptionResult {
  final String text;
  final Duration processingTime;

  const WhisperTranscriptionResult({
    required this.text,
    required this.processingTime,
  });
}

class WhisperTranscriptionService {
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

  String get _modelPath =>
      '$_whisperRoot\\models\\ggml-base.en.bin';

  Future<String> prepareAudio(
    String inputWavPath,
  ) async {
    final inputFile = File(inputWavPath);

    if (!await inputFile.exists()) {
      throw StateError(
        'Captured audio file does not exist:\n$inputWavPath',
      );
    }

    final timestamp =
        DateTime.now().microsecondsSinceEpoch;

    final outputPath =
        '${inputFile.parent.path}\\lyrics_whisper_$timestamp.wav';

    final result = await Process.run(
      'ffmpeg',
      [
        '-y',
        '-loglevel',
        'error',
        '-i',
        inputWavPath,
        '-ar',
        '16000',
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
        'FFmpeg conversion failed.\n\n${result.stderr}',
      );
    }

    final outputFile = File(outputPath);

    if (!await outputFile.exists()) {
      throw StateError(
        'FFmpeg finished but did not create the converted WAV.',
      );
    }

    return outputPath;
  }

  Future<WhisperTranscriptionResult> transcribePrepared(
    String preparedWavPath,
  ) async {
    await _validateDependencies();

    final audioFile = File(preparedWavPath);

    if (!await audioFile.exists()) {
      throw StateError(
        'Prepared Whisper audio does not exist:\n'
        '$preparedWavPath',
      );
    }

    final stopwatch = Stopwatch()..start();

    final result = await Process.run(
      _whisperExecutable,
      [
        '-m',
        _modelPath,
        '-f',
        preparedWavPath,
        '-l',
        'en',
        '-nt',
        '-np',
      ],
      workingDirectory: _whisperRoot,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    stopwatch.stop();

    if (result.exitCode != 0) {
      throw StateError(
        'Whisper failed.\n\n${result.stderr}',
      );
    }

    final transcript = _cleanTranscript(
      result.stdout.toString(),
    );

    return WhisperTranscriptionResult(
      text: transcript,
      processingTime: stopwatch.elapsed,
    );
  }

  Future<WhisperTranscriptionResult> transcribe(
    String inputWavPath,
  ) async {
    final preparedPath = await prepareAudio(
      inputWavPath,
    );

    try {
      return await transcribePrepared(
        preparedPath,
      );
    } finally {
      await deletePreparedAudio(
        preparedPath,
      );
    }
  }

  Future<void> deletePreparedAudio(
    String path,
  ) async {
    final file = File(path);

    if (!await file.exists()) {
      return;
    }

    try {
      await file.delete();
    } catch (_) {
      // Temporary file cleanup is not critical.
    }
  }

  Future<void> _validateDependencies() async {
    final executable = File(
      _whisperExecutable,
    );

    if (!await executable.exists()) {
      throw StateError(
        'whisper-cli.exe was not found at:\n'
        '$_whisperExecutable',
      );
    }

    final model = File(
      _modelPath,
    );

    if (!await model.exists()) {
      throw StateError(
        'Whisper model was not found at:\n'
        '$_modelPath',
      );
    }
  }

  String _cleanTranscript(
    String raw,
  ) {
    return raw
        .replaceAll('♪', ' ')
        .replaceAll(
          RegExp(r'\s+'),
          ' ',
        )
        .trim();
  }
}