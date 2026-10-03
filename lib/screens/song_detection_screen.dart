import 'package:flutter/material.dart';

import '../services/lyrics_matcher_service.dart';
import '../services/system_audio_capture_service.dart';
import '../services/whisper_transcription_service.dart';

class SongDetectionScreen extends StatefulWidget {
  const SongDetectionScreen({
    super.key,
  });

  @override
  State<SongDetectionScreen> createState() =>
      _SongDetectionScreenState();
}

class _SongDetectionScreenState
    extends State<SongDetectionScreen> {
  final SystemAudioCaptureService _captureService =
      SystemAudioCaptureService();

  final WhisperTranscriptionService _whisperService =
      WhisperTranscriptionService();

  final LyricsMatcherService _matcher =
      LyricsMatcherService();

  bool _running = false;

  String _stage =
      'Play one of the test songs on YouTube or Spotify.';

  String? _transcript;

  LyricsMatchResult? _matchResult;

  String? _error;

  Future<void> _detectSong() async {
    if (_running) {
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _transcript = null;
      _matchResult = null;
      _stage = 'Listening to system audio...';
    });

    try {
      // We already verified experimentally
      // that 15 seconds works much better
      // than the original short sample.
      final capture =
          await _captureService.capture(
        duration:
            const Duration(seconds: 15),
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _stage =
            'Preparing audio for recognition...';
      });

      final transcription =
          await _whisperService.transcribe(
        capture.filePath,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _transcript =
            transcription.text;

        _stage =
            'Searching lyrics library...';
      });

      final match =
          await _matcher.match(
        transcription.text,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _matchResult = match;

        if (match.bestMatch == null) {
          _stage =
              'No matching song found.';
        } else {
          _stage =
              'Song detected';
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = e.toString();
        _stage =
            'Detection failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  String _formatScore(
    double score,
  ) {
    return '${(score * 100).toStringAsFixed(1)}%';
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final best =
        _matchResult?.bestMatch;

    return Scaffold(
      backgroundColor:
          const Color(0xFF090909),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(
                maxWidth: 700,
              ),
              child: Padding(
                padding:
                    const EdgeInsets.all(
                  32,
                ),
                child: Column(
                  children: [
                    Icon(
                      _running
                          ? Icons
                              .hearing_rounded
                          : Icons
                              .graphic_eq_rounded,
                      color: Colors.white,
                      size: 76,
                    ),

                    const SizedBox(
                      height: 28,
                    ),

                    const Text(
                      'Lyrics',
                      style: TextStyle(
                        color:
                            Colors.white,
                        fontSize: 34,
                        fontWeight:
                            FontWeight.w700,
                      ),
                    ),

                    const SizedBox(
                      height: 12,
                    ),

                    Text(
                      _stage,
                      textAlign:
                          TextAlign.center,
                      style:
                          const TextStyle(
                        color:
                            Colors.white60,
                        fontSize: 16,
                      ),
                    ),

                    if (_running) ...[
                      const SizedBox(
                        height: 28,
                      ),

                      const LinearProgressIndicator(),
                    ],

                    if (_transcript !=
                        null) ...[
                      const SizedBox(
                        height: 35,
                      ),

                      _section(
                        title:
                            'Whisper heard',
                        child: Text(
                          _transcript!,
                          textAlign:
                              TextAlign.center,
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                            fontSize: 18,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],

                    if (best !=
                        null) ...[
                      const SizedBox(
                        height: 24,
                      ),

                      _section(
                        title:
                            'Best match',
                        child: Column(
                          children: [
                            Text(
                              best.title,
                              textAlign:
                                  TextAlign
                                      .center,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                                fontSize: 30,
                                fontWeight:
                                    FontWeight
                                        .w700,
                              ),
                            ),

                            const SizedBox(
                              height: 8,
                            ),

                            Text(
                              'Confidence: '
                              '${_formatScore(best.score)}',
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white54,
                                fontSize: 15,
                              ),
                            ),

                            const SizedBox(
                              height: 6,
                            ),

                            Text(
                              'Lyric line: '
                              '${best.lineIndex}',
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white54,
                              ),
                            ),

                            const SizedBox(
                              height: 18,
                            ),

                            Text(
                              best.matchedText,
                              textAlign:
                                  TextAlign
                                      .center,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white70,
                                fontSize: 16,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(
                        height: 24,
                      ),

                      _buildCandidates(),
                    ],

                    if (_error !=
                        null) ...[
                      const SizedBox(
                        height: 30,
                      ),

                      Container(
                        width:
                            double.infinity,
                        padding:
                            const EdgeInsets
                                .all(18),
                        decoration:
                            BoxDecoration(
                          color:
                              Colors.red
                                  .withValues(
                            alpha: 0.12,
                          ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                        ),
                        child: Text(
                          _error!,
                          textAlign:
                              TextAlign
                                  .center,
                          style:
                              const TextStyle(
                            color: Colors
                                .redAccent,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(
                      height: 38,
                    ),

                    FilledButton.icon(
                      onPressed:
                          _running
                              ? null
                              : _detectSong,
                      icon: const Icon(
                        Icons
                            .music_note_rounded,
                      ),
                      label: Padding(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          vertical: 16,
                          horizontal: 20,
                        ),
                        child: Text(
                          _running
                              ? 'LISTENING...'
                              : 'DETECT SONG',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCandidates() {
    final result =
        _matchResult;

    if (result == null) {
      return const SizedBox.shrink();
    }

    return _section(
      title: 'Candidates',
      child: Column(
        children:
            result.candidates
                .map(
                  (candidate) =>
                      Padding(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            candidate
                                .title,
                            style:
                                const TextStyle(
                              color:
                                  Colors.white,
                            ),
                          ),
                        ),
                        Text(
                          _formatScore(
                            candidate
                                .score,
                          ),
                          style:
                              const TextStyle(
                            color:
                                Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
      ),
    );
  }

  Widget _section({
    required String title,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.all(
        22,
      ),
      decoration:
          BoxDecoration(
        color:
            Colors.white.withValues(
          alpha: 0.05,
        ),
        borderRadius:
            BorderRadius.circular(
          18,
        ),
      ),
      child: Column(
        children: [
          Text(
            title,
            style:
                const TextStyle(
              color:
                  Colors.white38,
              fontSize: 13,
            ),
          ),

          const SizedBox(
            height: 14,
          ),

          child,
        ],
      ),
    );
  }
}