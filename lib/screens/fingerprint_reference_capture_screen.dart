import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/system_audio_capture_service.dart';

class FingerprintReferenceCaptureScreen extends StatefulWidget {
  const FingerprintReferenceCaptureScreen({
    super.key,
  });

  @override
  State<FingerprintReferenceCaptureScreen> createState() =>
      _FingerprintReferenceCaptureScreenState();
}

class _FingerprintReferenceCaptureScreenState
    extends State<FingerprintReferenceCaptureScreen> {
  final SystemAudioCaptureService _captureService =
      SystemAudioCaptureService();

  final TextEditingController _nameController =
      TextEditingController();

  final TextEditingController _durationController =
      TextEditingController(
    text: '300',
  );

  bool _capturing = false;

  int _elapsedSeconds = 0;

  Timer? _timer;

  String _status =
      'Enter the song name and duration, then start the song from the beginning.';

  Future<void> _captureReference() async {
    if (_capturing) {
      return;
    }

    final rawName =
        _nameController.text.trim();

    final durationSeconds =
        int.tryParse(
      _durationController.text.trim(),
    );

    if (rawName.isEmpty) {
      setState(() {
        _status =
            'Enter a song name first.';
      });

      return;
    }

    if (durationSeconds == null ||
        durationSeconds <= 0) {
      setState(() {
        _status =
            'Enter a valid duration in seconds.';
      });

      return;
    }

    final safeName =
        rawName
            .toLowerCase()
            .replaceAll(
              RegExp(r'[^a-z0-9]+'),
              '_',
            )
            .replaceAll(
              RegExp(r'^_+|_+$'),
              '',
            );

    if (safeName.isEmpty) {
      setState(() {
        _status =
            'The song name is not valid.';
      });

      return;
    }

    setState(() {
      _capturing = true;
      _elapsedSeconds = 0;
      _status =
          'Recording "$rawName"...';
    });

    _timer?.cancel();

    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        setState(() {
          _elapsedSeconds++;

          if (_elapsedSeconds >=
              durationSeconds) {
            _elapsedSeconds =
                durationSeconds;

            timer.cancel();
          }
        });
      },
    );

    try {
      final capture =
          await _captureService.capture(
        duration:
            Duration(
          seconds: durationSeconds,
        ),
      );

      final userProfile =
          Platform.environment[
              'USERPROFILE'];

      if (userProfile == null ||
          userProfile.isEmpty) {
        throw StateError(
          'Could not determine the Windows user folder.',
        );
      }

      final referencesDirectory =
          Directory(
        '$userProfile\\Downloads\\audfprint\\references',
      );

      if (!await referencesDirectory.exists()) {
        await referencesDirectory.create(
          recursive: true,
        );
      }

      final destinationPath =
          '${referencesDirectory.path}\\$safeName.wav';

      final source =
          File(
        capture.filePath,
      );

      if (!await source.exists()) {
        throw StateError(
          'Captured WAV was not found.',
        );
      }

      final destination =
          File(
        destinationPath,
      );

      if (await destination.exists()) {
        await destination.delete();
      }

      await source.copy(
        destinationPath,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _status =
            'Reference saved successfully\n\n'
            '$destinationPath';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status =
            'Capture failed\n\n$e';
      });
    } finally {
      _timer?.cancel();

      if (mounted) {
        setState(() {
          _capturing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();

    _nameController.dispose();
    _durationController.dispose();

    super.dispose();
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
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(
                maxWidth: 600,
              ),
              child: Padding(
                padding:
                    const EdgeInsets.all(
                  32,
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.fingerprint_rounded,
                      color: Colors.white,
                      size: 72,
                    ),

                    const SizedBox(
                      height: 24,
                    ),

                    const Text(
                      'Fingerprint Reference Recorder',
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        color:
                            Colors.white,
                        fontSize: 28,
                        fontWeight:
                            FontWeight.w700,
                      ),
                    ),

                    const SizedBox(
                      height: 30,
                    ),

                    TextField(
                      controller:
                          _nameController,
                      enabled:
                          !_capturing,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Song name',
                        hintText:
                            'Nobody',
                        border:
                            OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(
                      height: 18,
                    ),

                    TextField(
                      controller:
                          _durationController,
                      enabled:
                          !_capturing,
                      keyboardType:
                          TextInputType.number,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Duration in seconds',
                        hintText:
                            '300',
                        border:
                            OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(
                      height: 30,
                    ),

                    if (_capturing) ...[
                      Text(
                        '${_elapsedSeconds}s',
                        style:
                            const TextStyle(
                          color:
                              Colors.white,
                          fontSize: 40,
                          fontWeight:
                              FontWeight.w700,
                        ),
                      ),

                      const SizedBox(
                        height: 18,
                      ),

                      const LinearProgressIndicator(),

                      const SizedBox(
                        height: 25,
                      ),
                    ],

                    Text(
                      _status,
                      textAlign:
                          TextAlign.center,
                      style:
                          const TextStyle(
                        color:
                            Colors.white60,
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),

                    const SizedBox(
                      height: 35,
                    ),

                    FilledButton.icon(
                      onPressed:
                          _capturing
                              ? null
                              : _captureReference,
                      icon:
                          const Icon(
                        Icons
                            .radio_button_checked_rounded,
                      ),
                      label:
                          Padding(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          vertical: 16,
                          horizontal: 18,
                        ),
                        child: Text(
                          _capturing
                              ? 'RECORDING...'
                              : 'RECORD REFERENCE',
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
}