import 'package:flutter/material.dart';

import '../services/system_audio_capture_service.dart';

class AudioCaptureTestScreen extends StatefulWidget {
  const AudioCaptureTestScreen({
    super.key,
  });

  @override
  State<AudioCaptureTestScreen> createState() =>
      _AudioCaptureTestScreenState();
}

class _AudioCaptureTestScreenState
    extends State<AudioCaptureTestScreen> {
  final SystemAudioCaptureService _captureService =
      SystemAudioCaptureService();

  bool _capturing = false;

  String _status =
      'Play something on YouTube or Spotify, then press the button.';

  Future<void> _capture() async {
    if (_capturing) return;

    setState(() {
      _capturing = true;
      _status = 'Capturing Windows system audio...';
    });

    try {
      final result = await _captureService.capture();

      if (!mounted) return;

      setState(() {
        _status =
            'Capture successful\n\n'
            'File:\n${result.filePath}\n\n'
            'Audio bytes: ${result.bytes}\n'
            'Sample rate: ${result.sampleRate} Hz\n'
            'Channels: ${result.channels}\n'
            'Bits: ${result.bitsPerSample}';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = 'Capture failed\n\n$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _capturing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090909),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 600,
            ),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.graphic_eq_rounded,
                    color: Colors.white,
                    size: 72,
                  ),
                  const SizedBox(height: 30),
                  const Text(
                    'System Audio Capture',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 40),
                  FilledButton.icon(
                    onPressed: _capturing
                        ? null
                        : _capture,
                    icon: const Icon(
                      Icons.radio_button_checked_rounded,
                    ),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 14,
                        horizontal: 12,
                      ),
                      child: Text(
                        _capturing
                            ? 'CAPTURING...'
                            : 'CAPTURE SYSTEM AUDIO',
                      ),
                    ),
                  ),
                  if (_capturing) ...[
                    const SizedBox(height: 30),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
