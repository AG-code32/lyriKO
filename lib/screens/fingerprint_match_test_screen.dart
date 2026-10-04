import 'dart:io';

import 'package:flutter/material.dart';

import '../services/fingerprint_match_service.dart';
import '../services/system_audio_capture_service.dart';

class FingerprintMatchTestScreen
    extends StatefulWidget {
  const FingerprintMatchTestScreen({
    super.key,
  });

  @override
  State<FingerprintMatchTestScreen>
      createState() =>
          _FingerprintMatchTestScreenState();
}

class _FingerprintMatchTestScreenState
    extends State<FingerprintMatchTestScreen> {
  final SystemAudioCaptureService
      _captureService =
      SystemAudioCaptureService();

  final FingerprintMatchService
      _fingerprintService =
      FingerprintMatchService();

  bool _running = false;

  String _status =
      'Play any song from the fingerprint database.';

  FingerprintMatchResult? _result;

  String? _error;

  Duration? _captureTime;

  Duration? _totalTime;

  Future<void> _runTest() async {
    if (_running) {
      return;
    }

    setState(() {
      _running = true;
      _status =
          'Capturing 8 seconds of system audio...';
      _result = null;
      _error = null;
      _captureTime = null;
      _totalTime = null;
    });

    String? capturedPath;

    final totalWatch =
        Stopwatch()..start();

    try {
      final captureWatch =
          Stopwatch()..start();

      final capture =
          await _captureService.capture(
        duration:
            const Duration(
          seconds: 8,
        ),
      );

      captureWatch.stop();

      capturedPath =
          capture.filePath;

      if (!mounted) {
        return;
      }

      setState(() {
        _captureTime =
            captureWatch.elapsed;

        _status =
            'Matching fingerprint...';
      });

      final result =
          await _fingerprintService
              .matchEightSeconds(
        capture.filePath,
      );

      totalWatch.stop();

      if (!mounted) {
        return;
      }

      setState(() {
        _result = result;
        _totalTime =
            totalWatch.elapsed;

        if (result.matched) {
          _status =
              'Song matched';
        } else {
          _status =
              'No match found';
        }
      });
    } catch (e) {
      totalWatch.stop();

      if (!mounted) {
        return;
      }

      setState(() {
        _error =
            e.toString();

        _totalTime =
            totalWatch.elapsed;

        _status =
            'Fingerprint test failed';
      });
    } finally {
      if (capturedPath != null) {
        try {
          final file =
              File(
            capturedPath,
          );

          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  String _seconds(
    Duration duration,
  ) {
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(3)} s';
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          const Color(0xFF090909),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(
              maxWidth: 700,
            ),
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.all(
                32,
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.fingerprint_rounded,
                    color: Colors.white,
                    size: 78,
                  ),

                  const SizedBox(
                    height: 24,
                  ),

                  const Text(
                    'Fingerprint Test',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),

                  const SizedBox(
                    height: 12,
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

                  if (_running) ...[
                    const SizedBox(
                      height: 24,
                    ),

                    const LinearProgressIndicator(),
                  ],

                  if (_captureTime != null) ...[
                    const SizedBox(
                      height: 28,
                    ),

                    _row(
                      'WASAPI capture',
                      _seconds(
                        _captureTime!,
                      ),
                    ),
                  ],

                  if (_result != null) ...[
                    const SizedBox(
                      height: 28,
                    ),

                    Container(
                      width:
                          double.infinity,
                      padding:
                          const EdgeInsets.all(
                        22,
                      ),
                      decoration:
                          BoxDecoration(
                        color:
                            Colors.white
                                .withValues(
                          alpha: 0.05,
                        ),
                        borderRadius:
                            BorderRadius.circular(
                          16,
                        ),
                      ),
                      child: Column(
                        children: [
                          _row(
                            'Result',
                            _result!.matched
                                ? 'MATCH'
                                : 'NO MATCH',
                          ),

                          if (_result!.matched) ...[
                            _row(
                              'Track',
                              _result!.trackName ??
                                  'Unknown',
                            ),

                            if (_result!
                                    .offsetSeconds !=
                                null)
                              _row(
                                'Offset',
                                '${_result!.offsetSeconds!.toStringAsFixed(2)} s',
                              ),

                            if (_result!
                                        .alignedHashes !=
                                    null &&
                                _result!
                                        .commonHashes !=
                                    null)
                              _row(
                                'Hashes',
                                '${_result!.alignedHashes}'
                                ' / '
                                '${_result!.commonHashes}',
                              ),
                          ],

                          _row(
                            'Fingerprint processing',
                            _seconds(
                              _result!
                                  .processingTime,
                            ),
                          ),

                          if (_totalTime != null)
                            _row(
                              'Total',
                              _seconds(
                                _totalTime!,
                              ),
                            ),

                          const SizedBox(
                            height: 12,
                          ),

                          ExpansionTile(
                            tilePadding:
                                EdgeInsets.zero,
                            title:
                                const Text(
                              'Raw audfprint output',
                              style:
                                  TextStyle(
                                color:
                                    Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            children: [
                              SelectableText(
                                _result!
                                    .rawOutput,
                                style:
                                    const TextStyle(
                                  color:
                                      Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(
                      height: 28,
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
                    height: 35,
                  ),

                  FilledButton.icon(
                    onPressed:
                        _running
                            ? null
                            : _runTest,
                    icon:
                        const Icon(
                      Icons
                          .hearing_rounded,
                    ),
                    label:
                        const Padding(
                      padding:
                          EdgeInsets.symmetric(
                        vertical: 16,
                        horizontal: 18,
                      ),
                      child: Text(
                        'TEST 8 SECONDS',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style:
                  const TextStyle(
                color:
                    Colors.white38,
              ),
            ),
          ),

          Expanded(
            child: Text(
              value,
              style:
                  const TextStyle(
                color:
                    Colors.white70,
                fontWeight:
                    FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}