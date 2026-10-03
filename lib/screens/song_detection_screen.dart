import 'package:flutter/material.dart';

import '../services/continuous_song_detection_service.dart';

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
  final ContinuousSongDetectionService
      _detectionService =
      ContinuousSongDetectionService();

  bool _detecting = false;

  String _status =
      'Play a song, then press Detect Song.';

  ContinuousDetectionResult? _result;

  String? _error;

  Future<void> _startDetection() async {
    if (_detecting) {
      return;
    }

    setState(() {
      _detecting = true;
      _result = null;
      _error = null;
      _status = 'Listening...';
    });

    try {
      final result =
          await _detectionService.start(
        onStatus: (status) {
          if (!mounted) return;

          setState(() {
            _status = status;
          });
        },
      );

      if (!mounted) {
        return;
      }

      if (result == null) {
        setState(() {
          _status =
              'Detection stopped.';
        });

        return;
      }

      setState(() {
        _result = result;
        _status = 'Song detected';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = e.toString();
        _status = 'Detection failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _detecting = false;
        });
      }
    }
  }

  void _stopDetection() {
    _detectionService.stop();

    setState(() {
      _status = 'Stopping...';
    });
  }

  String _percentage(
    double value,
  ) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }

  String _seconds(
    Duration duration,
  ) {
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(2)} s';
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final result = _result;

    return Scaffold(
      backgroundColor:
          const Color(0xFF090909),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(
                maxWidth: 650,
              ),
              child: Padding(
                padding:
                    const EdgeInsets.all(
                  32,
                ),
                child: Column(
                  children: [
                    Icon(
                      _detecting
                          ? Icons.graphic_eq_rounded
                          : Icons.music_note_rounded,
                      color: Colors.white,
                      size: 76,
                    ),

                    const SizedBox(
                      height: 28,
                    ),

                    const Text(
                      'Lyrics',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight:
                            FontWeight.w700,
                      ),
                    ),

                    const SizedBox(
                      height: 14,
                    ),

                    Text(
                      _status,
                      textAlign:
                          TextAlign.center,
                      style:
                          const TextStyle(
                        color:
                            Colors.white60,
                        fontSize: 16,
                      ),
                    ),

                    if (_detecting) ...[
                      const SizedBox(
                        height: 25,
                      ),
                      const LinearProgressIndicator(),
                    ],

                    if (result != null) ...[
                      const SizedBox(
                        height: 35,
                      ),

                      _buildResult(
                        result,
                      ),
                    ],

                    if (_error != null) ...[
                      const SizedBox(
                        height: 30,
                      ),

                      Text(
                        _error!,
                        textAlign:
                            TextAlign.center,
                        style:
                            const TextStyle(
                          color:
                              Colors.redAccent,
                        ),
                      ),
                    ],

                    const SizedBox(
                      height: 40,
                    ),

                    if (!_detecting)
                      FilledButton.icon(
                        onPressed:
                            _startDetection,
                        icon:
                            const Icon(
                          Icons
                              .hearing_rounded,
                        ),
                        label:
                            const Padding(
                          padding:
                              EdgeInsets
                                  .symmetric(
                            vertical: 16,
                            horizontal: 18,
                          ),
                          child: Text(
                            'DETECT SONG',
                          ),
                        ),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed:
                            _stopDetection,
                        icon:
                            const Icon(
                          Icons.stop_rounded,
                        ),
                        label:
                            const Padding(
                          padding:
                              EdgeInsets
                                  .symmetric(
                            vertical: 16,
                            horizontal: 18,
                          ),
                          child: Text(
                            'CANCEL',
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

  Widget _buildResult(
    ContinuousDetectionResult result,
  ) {
    final timings =
        result.timings;

    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.all(
        26,
      ),
      decoration:
          BoxDecoration(
        color:
            Colors.white.withValues(
          alpha: 0.06,
        ),
        borderRadius:
            BorderRadius.circular(
          20,
        ),
      ),
      child: Column(
        children: [
          Text(
            result.match.title,
            textAlign:
                TextAlign.center,
            style:
                const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight:
                  FontWeight.w700,
            ),
          ),

          const SizedBox(
            height: 14,
          ),

          _row(
            'Confidence',
            _percentage(
              result.match.score,
            ),
          ),

          _row(
            'Second candidate',
            _percentage(
              result.secondBestScore,
            ),
          ),

          _row(
            'Lead',
            _percentage(
              result.lead,
            ),
          ),

          const Divider(
            height: 30,
            color: Colors.white12,
          ),

          _row(
            'Windows analyzed',
            '${result.analyzedWindows}',
          ),

          _row(
            'Windows with voice',
            '${result.voiceWindows}',
          ),

          const Divider(
            height: 30,
            color: Colors.white12,
          ),

          const Text(
            'Development timings',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 13,
              fontWeight:
                  FontWeight.w600,
            ),
          ),

          const SizedBox(
            height: 12,
          ),

          _row(
            'Total',
            _seconds(
              timings.total,
            ),
          ),

          _row(
            'Audio capture',
            _seconds(
              timings.capture,
            ),
          ),

          _row(
            'FFmpeg',
            _seconds(
              timings.preparation,
            ),
          ),

          _row(
            'VAD',
            _seconds(
              timings.vad,
            ),
          ),

          _row(
            'Whisper',
            _seconds(
              timings.whisper,
            ),
          ),

          _row(
            'Matcher',
            _seconds(
              timings.matcher,
            ),
          ),

          const Divider(
            height: 30,
            color: Colors.white12,
          ),

          Align(
            alignment:
                Alignment.centerLeft,
            child: Text(
              'Recognized text:\n\n'
              '${result.accumulatedTranscript}',
              style:
                  const TextStyle(
                color:
                    Colors.white54,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    String label,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style:
                  const TextStyle(
                color:
                    Colors.white54,
              ),
            ),
          ),
          Text(
            value,
            style:
                const TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}