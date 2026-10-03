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

  Future<WhisperTranscriptionResult> transcribe(
    String inputWavPath,
  ) async {
    await _validateDependencies();

    final inputFile = File(inputWavPath);

    if (!await inputFile.exists()) {
      throw StateError(
        'Captured audio file does not exist:\n$inputWavPath',
      );
    }

    final whisperWavPath =
        '${inputFile.parent.path}\\lyrics_whisper.wav';

    await _convertForWhisper(
      inputWavPath: inputWavPath,
      outputWavPath: whisperWavPath,
    );

    final stopwatch = Stopwatch()
      ..start();

    final result = await Process.run(
      _whisperExecutable,
      [
        '-m',
        _modelPath,
        '-f',
        whisperWavPath,
        '-l',
        'en',

        // Only transcript text.
        '-nt',
        '-np',
      ],
      workingDirectory: _whisperRoot,
      runInShell: false,
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

    if (transcript.isEmpty) {
      throw StateError(
        'Whisper did not detect any usable words.',
      );
    }

    return WhisperTranscriptionResult(
      text: transcript,
      processingTime: stopwatch.elapsed,
    );
  }

  Future<void> _convertForWhisper({
    required String inputWavPath,
    required String outputWavPath,
  }) async {
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
        outputWavPath,
      ],
      runInShell: true,
    );

    if (result.exitCode != 0) {
      throw StateError(
        'FFmpeg conversion failed.\n\n${result.stderr}',
      );
    }

    final convertedFile =
        File(outputWavPath);

    if (!await convertedFile.exists()) {
      throw StateError(
        'FFmpeg finished but the converted WAV was not created.',
      );
    }
  }

  Future<void> _validateDependencies() async {
    final whisperExe =
        File(_whisperExecutable);

    final model =
        File(_modelPath);

    if (!await whisperExe.exists()) {
      throw StateError(
        'whisper-cli.exe was not found at:\n'
        '$_whisperExecutable',
      );
    }

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