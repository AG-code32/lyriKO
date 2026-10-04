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
      'Play a song, then press Start Diagnostic.';

  final List<DiagnosticWindowResult>
      _windows = [];

  String? _error;

  Future<void> _startDetection() async {
    if (_detecting) {
      return;
    }

    setState(() {
      _detecting = true;
      _error = null;
      _windows.clear();
      _status = 'Starting...';
    });

    try {
      await _detectionService.startDiagnostic(
        onStatus: (status) {
          if (!mounted) {
            return;
          }

          setState(() {
            _status = status;
          });
        },
        onWindowResult: (result) {
          if (!mounted) {
            return;
          }

          setState(() {
            _windows.insert(
              0,
              result,
            );
          });
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        if (_windows.isNotEmpty &&
            _windows.first.accepted) {
          _status = 'Song detected';
        } else {
          _status =
              'Diagnostic stopped.';
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = e.toString();
        _status =
            'Diagnostic failed';
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
    return Scaffold(
      backgroundColor:
          const Color(0xFF090909),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(
                28,
                28,
                28,
                18,
              ),
              child: Column(
                children: [
                  const Text(
                    'Accumulated Matcher',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),

                  const SizedBox(
                    height: 10,
                  ),

                  Text(
                    _status,
                    textAlign:
                        TextAlign.center,
                    style:
                        const TextStyle(
                      color:
                          Colors.white60,
                      fontSize: 15,
                    ),
                  ),

                  if (_detecting) ...[
                    const SizedBox(
                      height: 18,
                    ),
                    const LinearProgressIndicator(),
                  ],

                  const SizedBox(
                    height: 20,
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
                          const Text(
                        'START TEST',
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
                          const Text(
                        'STOP',
                      ),
                    ),

                  if (_error != null) ...[
                    const SizedBox(
                      height: 18,
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
                ],
              ),
            ),

            const Divider(
              color: Colors.white12,
            ),

            Expanded(
              child: _windows.isEmpty
                  ? const Center(
                      child: Text(
                        'No windows analyzed yet.',
                        style: TextStyle(
                          color:
                              Colors.white38,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding:
                          const EdgeInsets.all(
                        20,
                      ),
                      itemCount:
                          _windows.length,
                      itemBuilder:
                          (
                        context,
                        index,
                      ) {
                        return _buildWindowCard(
                          _windows[index],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowCard(
    DiagnosticWindowResult result,
  ) {
    final windowBest =
        result.windowBestMatch;

    final accumulatedBest =
        result.accumulatedBestMatch;

    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 16,
      ),
      padding:
          const EdgeInsets.all(
        20,
      ),
      decoration:
          BoxDecoration(
        color:
            Colors.white.withValues(
          alpha: result.accepted
              ? 0.10
              : 0.05,
        ),
        borderRadius:
            BorderRadius.circular(
          16,
        ),
        border: result.accepted
            ? Border.all(
                color:
                    Colors.white24,
              )
            : null,
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Window ${result.windowNumber}',
                  style:
                      const TextStyle(
                    color:
                        Colors.white,
                    fontSize: 20,
                    fontWeight:
                        FontWeight.w700,
                  ),
                ),
              ),

              if (result.accepted)
                const Text(
                  'ACCEPTED',
                  style: TextStyle(
                    color:
                        Colors.white,
                    fontSize: 12,
                    fontWeight:
                        FontWeight.w700,
                  ),
                ),
            ],
          ),

          const SizedBox(
            height: 14,
          ),

          const Text(
            'Whisper',
            style: TextStyle(
              color:
                  Colors.white38,
              fontSize: 12,
            ),
          ),

          const SizedBox(
            height: 5,
          ),

          Text(
            result.transcript.isEmpty
                ? '(no useful text)'
                : result.transcript,
            style:
                const TextStyle(
              color:
                  Colors.white70,
              fontSize: 15,
              height: 1.4,
            ),
          ),

          const Divider(
            height: 28,
            color: Colors.white12,
          ),

          const Text(
            'THIS WINDOW',
            style: TextStyle(
              color:
                  Colors.white38,
              fontSize: 11,
              fontWeight:
                  FontWeight.w700,
            ),
          ),

          const SizedBox(
            height: 8,
          ),

          if (windowBest != null) ...[
            _row(
              'Best',
              windowBest.title,
            ),
            _row(
              'Score',
              _percentage(
                windowBest.score,
              ),
            ),
            _row(
              'Second',
              _percentage(
                result.windowSecondScore,
              ),
            ),
            _row(
              'Lead',
              _percentage(
                result.windowLead,
              ),
            ),
          ] else
            const Text(
              'No usable window match',
              style: TextStyle(
                color:
                    Colors.white38,
              ),
            ),

          const Divider(
            height: 28,
            color: Colors.white12,
          ),

          const Text(
            'ACCUMULATED EVIDENCE',
            style: TextStyle(
              color:
                  Colors.white38,
              fontSize: 11,
              fontWeight:
                  FontWeight.w700,
            ),
          ),

          const SizedBox(
            height: 8,
          ),

          if (accumulatedBest !=
              null) ...[
            _row(
              'Best',
              accumulatedBest.title,
            ),
            _row(
              'Score',
              _percentage(
                result.accumulatedScore,
              ),
            ),
            _row(
              'Second',
              _percentage(
                result
                    .accumulatedSecondScore,
              ),
            ),
            _row(
              'Lead',
              _percentage(
                result.accumulatedLead,
              ),
            ),
            _row(
              'Evidence windows',
              '${result.evidenceWindows}',
            ),
            _row(
              'Same winner',
              '${result.winnerCount}',
            ),
          ] else
            const Text(
              'No accumulated evidence yet',
              style: TextStyle(
                color:
                    Colors.white38,
              ),
            ),

          const SizedBox(
            height: 10,
          ),

          Text(
            result.acceptanceReason,
            style:
                TextStyle(
              color: result.accepted
                  ? Colors.white
                  : Colors.white38,
              fontSize: 12,
              fontWeight:
                  result.accepted
                      ? FontWeight.w700
                      : FontWeight.normal,
            ),
          ),

          const Divider(
            height: 28,
            color: Colors.white12,
          ),

          _row(
            'Capture',
            _seconds(
              result.captureTime,
            ),
          ),

          _row(
            'FFmpeg',
            _seconds(
              result.preparationTime,
            ),
          ),

          _row(
            'Whisper',
            _seconds(
              result.whisperTime,
            ),
          ),

          _row(
            'Matcher',
            _seconds(
              result.matcherTime,
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
        vertical: 3,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style:
                  const TextStyle(
                color:
                    Colors.white38,
              ),
            ),
          ),
          Text(
            value,
            style:
                const TextStyle(
              color:
                  Colors.white70,
              fontWeight:
                  FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}