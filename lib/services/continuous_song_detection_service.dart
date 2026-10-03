import 'dart:io';

import 'lyrics_matcher_service.dart';
import 'system_audio_capture_service.dart';
import 'voice_activity_service.dart';
import 'whisper_transcription_service.dart';

class DetectionTimings {
  final Duration total;
  final Duration capture;
  final Duration preparation;
  final Duration vad;
  final Duration whisper;
  final Duration matcher;

  const DetectionTimings({
    required this.total,
    required this.capture,
    required this.preparation,
    required this.vad,
    required this.whisper,
    required this.matcher,
  });
}

class ContinuousDetectionResult {
  final LyricsMatchCandidate match;
  final double secondBestScore;
  final double lead;
  final String accumulatedTranscript;
  final int analyzedWindows;
  final int voiceWindows;
  final DetectionTimings timings;

  const ContinuousDetectionResult({
    required this.match,
    required this.secondBestScore,
    required this.lead,
    required this.accumulatedTranscript,
    required this.analyzedWindows,
    required this.voiceWindows,
    required this.timings,
  });
}

class ContinuousSongDetectionService {
  final SystemAudioCaptureService _captureService =
      SystemAudioCaptureService();

  final VoiceActivityService _voiceActivityService =
      VoiceActivityService();

  final WhisperTranscriptionService _whisperService =
      WhisperTranscriptionService();

  final LyricsMatcherService _matcher =
      LyricsMatcherService();

  static const Duration _windowDuration =
      Duration(seconds: 8);

  // Provisional thresholds for the prototype.
  static const double _minimumScore = 0.50;
  static const double _minimumLead = 0.12;

  bool _stopRequested = false;

  void stop() {
    _stopRequested = true;
  }

  Future<ContinuousDetectionResult?> start({
    required void Function(String status) onStatus,
  }) async {
    _stopRequested = false;

    final totalWatch = Stopwatch()..start();

    var totalCaptureTime = Duration.zero;
    var totalPreparationTime = Duration.zero;
    var totalVadTime = Duration.zero;
    var totalWhisperTime = Duration.zero;
    var totalMatcherTime = Duration.zero;

    final recentTranscripts = <String>[];

    var analyzedWindows = 0;
    var voiceWindows = 0;

    onStatus('Listening...');

    //
    // First audio window.
    //
    final firstCaptureWatch = Stopwatch()..start();

    var currentCapture = await _captureService.capture(
      duration: _windowDuration,
    );

    firstCaptureWatch.stop();

    totalCaptureTime += firstCaptureWatch.elapsed;

    while (!_stopRequested) {
      analyzedWindows++;

      //
      // WASAPI always writes to the same temporary file,
      // so copy it before starting the next recording.
      //
      final chunkPath = await _copyCapture(
        currentCapture.filePath,
      );

      //
      // Immediately start capturing the next window.
      //
      final nextCaptureFuture = _captureNextWindow(
        duration: _windowDuration,
        onFinished: (elapsed) {
          totalCaptureTime += elapsed;
        },
      );

      String? preparedPath;

      try {
        onStatus(
          'Analyzing audio window $analyzedWindows...',
        );

        //
        // Convert captured WAV to the format Whisper uses.
        //
        final preparationWatch = Stopwatch()..start();

        preparedPath =
            await _whisperService.prepareAudio(
          chunkPath,
        );

        preparationWatch.stop();

        totalPreparationTime +=
            preparationWatch.elapsed;

        //
        // Voice detection.
        //
        final vadWatch = Stopwatch()..start();

        final voice =
            await _voiceActivityService.detectVoice(
          preparedPath,
        );

        vadWatch.stop();

        totalVadTime += vadWatch.elapsed;

        if (_stopRequested) {
          _ignoreFuture(nextCaptureFuture);
          return null;
        }

        if (voice.hasVoice) {
          voiceWindows++;

          onStatus(
            'Voice detected — transcribing...',
          );

          //
          // Whisper receives the complete prepared window.
          // VAD does not trim the singing audio.
          //
          final whisperWatch = Stopwatch()..start();

          final transcription =
              await _whisperService
                  .transcribePrepared(
            preparedPath,
          );

          whisperWatch.stop();

          totalWhisperTime +=
              whisperWatch.elapsed;

          final text =
              transcription.text.trim();

          if (text.isNotEmpty) {
            recentTranscripts.add(text);

            //
            // Keep only recent evidence.
            //
            if (recentTranscripts.length > 3) {
              recentTranscripts.removeAt(0);
            }

            final combinedText =
                recentTranscripts.join(' ');

            onStatus(
              'Comparing lyrics...',
            );

            //
            // Compare recognized text against lyrics.
            //
            final matcherWatch = Stopwatch()..start();

            final result =
                await _matcher.match(
              combinedText,
            );

            matcherWatch.stop();

            totalMatcherTime +=
                matcherWatch.elapsed;

            final best =
                result.bestMatch;

            if (best != null) {
              final secondScore =
                  result.candidates.length > 1
                      ? result.candidates[1].score
                      : 0.0;

              final lead =
                  best.score - secondScore;

              final confident =
                  best.score >= _minimumScore &&
                      lead >= _minimumLead;

              if (confident) {
                totalWatch.stop();

                _stopRequested = true;

                //
                // A next capture may already be running.
                // We simply ignore its result.
                //
                _ignoreFuture(
                  nextCaptureFuture,
                );

                return ContinuousDetectionResult(
                  match: best,
                  secondBestScore: secondScore,
                  lead: lead,
                  accumulatedTranscript:
                      combinedText,
                  analyzedWindows:
                      analyzedWindows,
                  voiceWindows:
                      voiceWindows,
                  timings: DetectionTimings(
                    total:
                        totalWatch.elapsed,
                    capture:
                        totalCaptureTime,
                    preparation:
                        totalPreparationTime,
                    vad:
                        totalVadTime,
                    whisper:
                        totalWhisperTime,
                    matcher:
                        totalMatcherTime,
                  ),
                );
              }
            }
          }
        } else {
          onStatus(
            'No vocals detected — continuing...',
          );
        }
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

        return null;
      }

      //
      // The next capture started while VAD/Whisper
      // were processing the previous window.
      //
      currentCapture =
          await nextCaptureFuture;
    }

    return null;
  }

  Future<SystemAudioCaptureResult> _captureNextWindow({
    required Duration duration,
    required void Function(Duration elapsed)
        onFinished,
  }) async {
    final watch = Stopwatch()..start();

    final result =
        await _captureService.capture(
      duration: duration,
    );

    watch.stop();

    onFinished(
      watch.elapsed,
    );

    return result;
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
        'lyrics_chunk_$timestamp.wav';

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
      final file = File(path);

      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Failure deleting a temporary file
      // should not stop recognition.
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