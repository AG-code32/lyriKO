import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

class FingerprintEngineInfo {
  final Duration startupTime;
  final int tracks;
  final int hashes;

  const FingerprintEngineInfo({
    required this.startupTime,
    required this.tracks,
    required this.hashes,
  });
}

class FingerprintMatchResult {
  final bool matched;

  final String? trackPath;

  final double? offsetSeconds;

  final int? alignedHashes;
  final int? commonHashes;

  final int rawHashes;

  final Duration processingTime;
  final Duration roundTripTime;

  final double queryDuration;

  const FingerprintMatchResult({
    required this.matched,
    required this.trackPath,
    required this.offsetSeconds,
    required this.alignedHashes,
    required this.commonHashes,
    required this.rawHashes,
    required this.processingTime,
    required this.roundTripTime,
    required this.queryDuration,
  });

  String? get trackName {
    if (trackPath == null) {
      return null;
    }

    final normalized =
        trackPath!.replaceAll(
      '\\',
      '/',
    );

    final fileName =
        normalized.split('/').last;

    final dot =
        fileName.lastIndexOf('.');

    if (dot <= 0) {
      return fileName;
    }

    return fileName.substring(
      0,
      dot,
    );
  }
}

class FingerprintMatchService {
  Process? _process;

  StreamSubscription<String>?
      _stdoutSubscription;

  StreamSubscription<String>?
      _stderrSubscription;

  Completer<FingerprintEngineInfo>?
      _readyCompleter;

  final Queue<
      Completer<Map<String, dynamic>>>
      _pendingRequests =
      Queue();

  FingerprintEngineInfo?
      _engineInfo;

  String _lastStderr = '';

  String get _userProfile {
    final path =
        Platform.environment[
            'USERPROFILE'];

    if (path == null ||
        path.isEmpty) {
      throw StateError(
        'Could not determine '
        'the Windows user folder.',
      );
    }

    return path;
  }

  String get _audfprintRoot =>
      '$_userProfile\\Downloads\\audfprint';

  String get _pythonExe =>
      '$_audfprintRoot\\'
      '.venv\\Scripts\\python.exe';

  String get _serverScript =>
      '$_audfprintRoot\\'
      'fingerprint_server.py';

  String get _databasePath =>
      '$_audfprintRoot\\'
      'lyrics_fingerprint_db.pklz';

  Future<FingerprintEngineInfo>
      ensureReady() async {
    if (_process != null &&
        _engineInfo != null) {
      return _engineInfo!;
    }

    await _startEngine();

    return _readyCompleter!.future;
  }

  Future<void> _startEngine() async {
    if (_process != null) {
      return;
    }

    await _validateDependencies();

    _readyCompleter =
        Completer<
            FingerprintEngineInfo>();

    _lastStderr = '';

    _process = await Process.start(
      _pythonExe,
      [
        _serverScript,
      ],
      workingDirectory:
          _audfprintRoot,
      runInShell: false,
    );

    _stdoutSubscription =
        _process!.stdout
            .transform(
              utf8.decoder,
            )
            .transform(
              const LineSplitter(),
            )
            .listen(
              _handleStdoutLine,
              onError: (
                Object error,
              ) {
                _failAll(
                  'Fingerprint stdout '
                  'error: $error',
                );
              },
            );

    _stderrSubscription =
        _process!.stderr
            .transform(
              utf8.decoder,
            )
            .transform(
              const LineSplitter(),
            )
            .listen(
              (line) {
                _lastStderr = line;
              },
            );

    _process!.exitCode.then(
      (code) {
        if (code != 0) {
          _failAll(
            'Fingerprint engine '
            'exited with code $code.'
            '${_lastStderr.isEmpty ? '' : '\n$_lastStderr'}',
          );
        }

        _process = null;
        _engineInfo = null;
      },
    );
  }

  void _handleStdoutLine(
    String line,
  ) {
    if (line.trim().isEmpty) {
      return;
    }

    Map<String, dynamic> message;

    try {
      message =
          Map<String, dynamic>.from(
        jsonDecode(line) as Map,
      );
    } catch (_) {
      return;
    }

    final type =
        message['type'];

    if (type == 'ready') {
      final info =
          FingerprintEngineInfo(
        startupTime:
            Duration(
          microseconds:
              ((message[
                          'startup_ms']
                      as num) *
                  1000)
              .round(),
        ),
        tracks:
            (message['tracks']
                    as num)
                .toInt(),
        hashes:
            (message['hashes']
                    as num)
                .toInt(),
      );

      _engineInfo = info;

      if (_readyCompleter !=
              null &&
          !_readyCompleter!
              .isCompleted) {
        _readyCompleter!
            .complete(info);
      }

      return;
    }

    if (type == 'fatal') {
      final messageText =
          message['message']
                  ?.toString() ??
              'Fingerprint engine '
                  'failed.';

      _failAll(
        messageText,
      );

      return;
    }

    if (_pendingRequests.isEmpty) {
      return;
    }

    final completer =
        _pendingRequests
            .removeFirst();

    if (type == 'error') {
      completer.completeError(
        StateError(
          message['message']
                  ?.toString() ??
              'Fingerprint request '
                  'failed.',
        ),
      );

      return;
    }

    completer.complete(
      message,
    );
  }

  Future<FingerprintMatchResult>
      match(
    String capturedWavPath,
  ) async {
    await ensureReady();

    final file =
        File(capturedWavPath);

    if (!await file.exists()) {
      throw StateError(
        'Captured WAV was not found:\n'
        '$capturedWavPath',
      );
    }

    final responseCompleter =
        Completer<
            Map<String, dynamic>>();

    _pendingRequests.add(
      responseCompleter,
    );

    final roundTripWatch =
        Stopwatch()..start();

    _process!.stdin.writeln(
      jsonEncode({
        'cmd': 'match',
        'path': capturedWavPath,
      }),
    );

    await _process!.stdin.flush();

    final response =
        await responseCompleter.future;

    roundTripWatch.stop();

    if (response['type'] !=
        'match_result') {
      throw StateError(
        'Unexpected fingerprint '
        'response.',
      );
    }

    final matched =
        response['matched'] ==
            true;

    return FingerprintMatchResult(
      matched: matched,

      trackPath:
          response['track_path']
              ?.toString(),

      offsetSeconds:
          response['offset_seconds']
                  == null
              ? null
              : (response[
                          'offset_seconds']
                      as num)
                  .toDouble(),

      alignedHashes:
          response['aligned_hashes']
                  == null
              ? null
              : (response[
                          'aligned_hashes']
                      as num)
                  .toInt(),

      commonHashes:
          response['common_hashes']
                  == null
              ? null
              : (response[
                          'common_hashes']
                      as num)
                  .toInt(),

      rawHashes:
          (response['raw_hashes']
                  as num?)
              ?.toInt() ??
              0,

      processingTime:
          Duration(
        microseconds:
            (((response[
                            'processing_ms']
                        as num?) ??
                    0) *
                1000)
            .round(),
      ),

      roundTripTime:
          roundTripWatch.elapsed,

      queryDuration:
          (response[
                      'query_duration']
                  as num?)
              ?.toDouble() ??
              0.0,
    );
  }

  Future<void> dispose() async {
    final process =
        _process;

    if (process == null) {
      return;
    }

    try {
      process.stdin.writeln(
        jsonEncode({
          'cmd': 'quit',
        }),
      );

      await process.stdin.flush();
    } catch (_) {}

    await _stdoutSubscription
        ?.cancel();

    await _stderrSubscription
        ?.cancel();

    process.kill();

    _process = null;
    _engineInfo = null;
  }

  Future<void>
      _validateDependencies() async {
    if (!await File(
      _pythonExe,
    ).exists()) {
      throw StateError(
        'Python environment '
        'was not found:\n'
        '$_pythonExe',
      );
    }

    if (!await File(
      _serverScript,
    ).exists()) {
      throw StateError(
        'fingerprint_server.py '
        'was not found:\n'
        '$_serverScript',
      );
    }

    if (!await File(
      _databasePath,
    ).exists()) {
      throw StateError(
        'Fingerprint database '
        'was not found:\n'
        '$_databasePath',
      );
    }
  }

  void _failAll(
    String message,
  ) {
    final error =
        StateError(message);

    if (_readyCompleter != null &&
        !_readyCompleter!
            .isCompleted) {
      _readyCompleter!
          .completeError(error);
    }

    while (_pendingRequests
        .isNotEmpty) {
      _pendingRequests
          .removeFirst()
          .completeError(error);
    }
  }
}