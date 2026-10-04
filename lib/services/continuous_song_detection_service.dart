import 'dart:io';

import 'lyrics_matcher_service.dart';
import 'system_audio_capture_service.dart';
import 'whisper_transcription_service.dart';

class DiagnosticWindowResult {
  final int windowNumber;

  final String transcript;

  // Result for this individual window.
  final LyricsMatchCandidate? windowBestMatch;
  final double windowSecondScore;
  final double windowLead;

  // Accumulated result using recent useful windows.
  final LyricsMatchCandidate? accumulatedBestMatch;
  final double accumulatedScore;
  final double accumulatedSecondScore;
  final double accumulatedLead;

  final int evidenceWindows;
  final int winnerCount;

  final bool accepted;
  final String acceptanceReason;

  final Duration captureTime;
  final Duration preparationTime;
  final Duration whisperTime;
  final Duration matcherTime;

  const DiagnosticWindowResult({
    required this.windowNumber,
    required this.transcript,
    required this.windowBestMatch,
    required this.windowSecondScore,
    required this.windowLead,
    required this.accumulatedBestMatch,
    required this.accumulatedScore,
    required this.accumulatedSecondScore,
    required this.accumulatedLead,
    required this.evidenceWindows,
    required this.winnerCount,
    required this.accepted,
    required this.acceptanceReason,
    required this.captureTime,
    required this.preparationTime,
    required this.whisperTime,
    required this.matcherTime,
  });
}

class _EvidenceWindow {
  final String winnerSongId;

  final Map<String, double> scores;

  const _EvidenceWindow({
    required this.winnerSongId,
    required this.scores,
  });
}

class ContinuousSongDetectionService {
  final SystemAudioCaptureService _captureService =
      SystemAudioCaptureService();

  final WhisperTranscriptionService _whisperService =
      WhisperTranscriptionService();

  final LyricsMatcherService _matcher =
      LyricsMatcherService();

  static const Duration _windowDuration =
      Duration(seconds: 8);

  //
  // We keep only the most recent useful evidence.
  //
  static const int _maxEvidenceWindows = 3;

  //
  // A single exceptionally good window can still
  // identify the song immediately.
  //
  static const double _strongSingleScore = 0.50;
  static const double _strongSingleLead = 0.12;

  //
  // Accumulated matching is intentionally less strict.
  // It compensates for imperfect singing transcription.
  //
  static const double _accumulatedMinimumScore = 0.30;
  static const double _accumulatedMinimumLead = 0.08;

  bool _stopRequested = false;

  void stop() {
    _stopRequested = true;
  }

  Future<void> startDiagnostic({
    required void Function(String status) onStatus,
    required void Function(DiagnosticWindowResult result)
        onWindowResult,
  }) async {
    _stopRequested = false;

    final evidence = <_EvidenceWindow>[];

    //
    // We keep the latest candidate object for each song
    // so we still have title, matched text, line, etc.
    //
    final latestCandidates =
        <String, LyricsMatchCandidate>{};

    var windowNumber = 0;

    onStatus('Capturing first window...');

    //
    // First window.
    //
    final firstCaptureWatch =
        Stopwatch()..start();

    var currentCapture =
        await _captureService.capture(
      duration: _windowDuration,
    );

    firstCaptureWatch.stop();

    var currentCaptureTime =
        firstCaptureWatch.elapsed;

    while (!_stopRequested) {
      windowNumber++;

      //
      // WASAPI always writes to the same temporary WAV.
      // Copy it before we start recording the next one.
      //
      final chunkPath =
          await _copyCapture(
        currentCapture.filePath,
      );

      //
      // Start NEXT capture now.
      //
      // While Windows is recording it, we process
      // the current window.
      //
      final nextCaptureFuture =
          _captureNextWindow(
        duration: _windowDuration,
      );

      String? preparedPath;

      try {
        onStatus(
          'Analyzing window $windowNumber...',
        );

        //
        // FFmpeg
        //
        final preparationWatch =
            Stopwatch()..start();

        preparedPath =
            await _whisperService.prepareAudio(
          chunkPath,
        );

        preparationWatch.stop();

        if (_stopRequested) {
          _ignoreFuture(
            nextCaptureFuture,
          );

          return;
        }

        //
        // NO VAD.
        //
        // Every window goes directly to Whisper.
        //
        onStatus(
          'Whisper analyzing window $windowNumber...',
        );

        final whisperWatch =
            Stopwatch()..start();

        final transcription =
            await _whisperService
                .transcribePrepared(
          preparedPath,
        );

        whisperWatch.stop();

        final transcript =
            transcription.text.trim();

        final matcherWatch =
            Stopwatch()..start();

        LyricsMatchCandidate?
            windowBest;

        double windowSecondScore = 0.0;
        double windowLead = 0.0;

        if (_isUsefulTranscript(
          transcript,
        )) {
          onStatus(
            'Comparing lyrics...',
          );

          final result =
              await _matcher.match(
            transcript,
          );

          windowBest =
              result.bestMatch;

          //
          // Save candidate metadata.
          //
          for (final candidate
              in result.candidates) {
            latestCandidates[
                    candidate.songId] =
                candidate;
          }

          if (result.candidates.length >
              1) {
            windowSecondScore =
                result
                    .candidates[1]
                    .score;
          }

          if (windowBest != null) {
            windowLead =
                windowBest.score -
                    windowSecondScore;

            final scores =
                <String, double>{};

            for (final candidate
                in result.candidates) {
              scores[candidate.songId] =
                  candidate.score;
            }

            evidence.add(
              _EvidenceWindow(
                winnerSongId:
                    windowBest.songId,
                scores: scores,
              ),
            );

            //
            // Never accumulate indefinitely.
            //
            if (evidence.length >
                _maxEvidenceWindows) {
              evidence.removeAt(0);
            }
          }
        }

        matcherWatch.stop();

        //
        // Calculate weighted accumulated evidence.
        //
        final accumulated =
            _calculateAccumulatedScores(
          evidence,
        );

        String? accumulatedBestId;
        double accumulatedBestScore = 0.0;
        double accumulatedSecondScore =
            0.0;

        if (accumulated.isNotEmpty) {
          final ordered =
              accumulated.entries.toList()
                ..sort(
                  (a, b) => b.value
                      .compareTo(a.value),
                );

          accumulatedBestId =
              ordered.first.key;

          accumulatedBestScore =
              ordered.first.value;

          if (ordered.length > 1) {
            accumulatedSecondScore =
                ordered[1].value;
          }
        }

        final accumulatedLead =
            accumulatedBestScore -
                accumulatedSecondScore;

        final accumulatedBest =
            accumulatedBestId == null
                ? null
                : latestCandidates[
                    accumulatedBestId];

        final winnerCount =
            accumulatedBestId == null
                ? 0
                : evidence
                    .where(
                      (item) =>
                          item.winnerSongId ==
                          accumulatedBestId,
                    )
                    .length;

        //
        // RULE 1:
        // One very strong window.
        //
        final strongSingle =
            windowBest != null &&
                windowBest.score >=
                    _strongSingleScore &&
                windowLead >=
                    _strongSingleLead;

        //
        // RULE 2:
        // Consistent evidence across recent windows.
        //
        final consistentAccumulated =
            accumulatedBest != null &&
                evidence.length >= 2 &&
                winnerCount >= 2 &&
                accumulatedBestScore >=
                    _accumulatedMinimumScore &&
                accumulatedLead >=
                    _accumulatedMinimumLead;

        final accepted =
            strongSingle ||
                consistentAccumulated;

        String acceptanceReason =
            'Not enough evidence yet';

        if (strongSingle) {
          acceptanceReason =
              'Strong single window';
        } else if (
            consistentAccumulated) {
          acceptanceReason =
              'Consistent accumulated evidence';
        }

        final diagnostic =
            DiagnosticWindowResult(
          windowNumber:
              windowNumber,
          transcript:
              transcript,
          windowBestMatch:
              windowBest,
          windowSecondScore:
              windowSecondScore,
          windowLead:
              windowLead,
          accumulatedBestMatch:
              accumulatedBest,
          accumulatedScore:
              accumulatedBestScore,
          accumulatedSecondScore:
              accumulatedSecondScore,
          accumulatedLead:
              accumulatedLead,
          evidenceWindows:
              evidence.length,
          winnerCount:
              winnerCount,
          accepted:
              accepted,
          acceptanceReason:
              acceptanceReason,
          captureTime:
              currentCaptureTime,
          preparationTime:
              preparationWatch.elapsed,
          whisperTime:
              whisperWatch.elapsed,
          matcherTime:
              matcherWatch.elapsed,
        );

        onWindowResult(
          diagnostic,
        );

        if (accepted) {
          _stopRequested = true;

          //
          // Next capture may already be running.
          // We no longer need its result.
          //
          _ignoreFuture(
            nextCaptureFuture,
          );

          onStatus(
            'Song detected',
          );

          return;
        }

        onStatus(
          'Listening for more evidence...',
        );
      } finally {
        await _safeDelete(
          chunkPath,
        );

        if (preparedPath != null) {
          await _whisperService
              .deletePreparedAudio(
            preparedPath,
          );
        }
      }

      if (_stopRequested) {
        _ignoreFuture(
          nextCaptureFuture,
        );

        return;
      }

      //
      // Next recording has already been happening
      // while Whisper processed the previous window.
      //
      final nextCaptureResult =
          await nextCaptureFuture;

      currentCapture =
          nextCaptureResult.result;

      currentCaptureTime =
          nextCaptureResult.elapsed;
    }
  }

  bool _isUsefulTranscript(
    String text,
  ) {
    final cleaned =
        text.trim();

    if (cleaned.isEmpty) {
      return false;
    }

    //
    // Whisper sometimes returns generic music labels.
    //
    final normalized =
        cleaned
            .toLowerCase()
            .replaceAll('♪', '')
            .trim();

    if (normalized == '(music)' ||
        normalized == '[music]' ||
        normalized == 'music') {
      return false;
    }

    //
    // Require at least 3 words.
    //
    final words =
        normalized
            .split(
              RegExp(r'\s+'),
            )
            .where(
              (word) =>
                  word.isNotEmpty,
            )
            .toList();

    return words.length >= 3;
  }

  Map<String, double>
      _calculateAccumulatedScores(
    List<_EvidenceWindow> evidence,
  ) {
    if (evidence.isEmpty) {
      return {};
    }

    final totals =
        <String, double>{};

    var totalWeight = 0.0;

    //
    // Most recent windows get slightly more weight.
    //
    // For 3 windows:
    //
    // oldest = 1
    // middle = 2
    // newest = 3
    //
    for (var i = 0;
        i < evidence.length;
        i++) {
      final weight =
          (i + 1).toDouble();

      totalWeight += weight;

      for (final entry
          in evidence[i].scores.entries) {
        totals[entry.key] =
            (totals[entry.key] ?? 0.0) +
                entry.value * weight;
      }
    }

    if (totalWeight == 0) {
      return {};
    }

    return totals.map(
      (songId, total) =>
          MapEntry(
        songId,
        total / totalWeight,
      ),
    );
  }

  Future<_CapturedWindow>
      _captureNextWindow({
    required Duration duration,
  }) async {
    final watch =
        Stopwatch()..start();

    final result =
        await _captureService.capture(
      duration: duration,
    );

    watch.stop();

    return _CapturedWindow(
      result: result,
      elapsed: watch.elapsed,
    );
  }

  Future<String> _copyCapture(
    String sourcePath,
  ) async {
    final source =
        File(sourcePath);

    if (!await source.exists()) {
      throw StateError(
        'Captured WAV does not exist:\n'
        '$sourcePath',
      );
    }

    final timestamp =
        DateTime.now()
            .microsecondsSinceEpoch;

    final destination =
        '${Directory.systemTemp.path}\\'
        'lyrics_diagnostic_$timestamp.wav';

    final copied =
        await source.copy(
      destination,
    );

    return copied.path;
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
      // Temporary cleanup must never
      // interrupt recognition.
    }
  }

  void _ignoreFuture(
    Future<dynamic> future,
  ) {
    future
        .then<void>((_) {})
        .catchError((_) {});
  }
}

class _CapturedWindow {
  final SystemAudioCaptureResult result;
  final Duration elapsed;

  const _CapturedWindow({
    required this.result,
    required this.elapsed,
  });
}