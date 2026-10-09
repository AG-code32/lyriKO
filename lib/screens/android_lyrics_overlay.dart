import 'package:flutter/material.dart';

/// The Android floating lyrics UI is now rendered by NativeLyricsOverlayService
/// through Android WindowManager. This widget remains only so old imports or
/// editor references do not break while the project is migrated.
class AndroidLyricsOverlay extends StatelessWidget {
  const AndroidLyricsOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
