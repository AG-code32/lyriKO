import 'package:flutter/material.dart';

import 'screens/song_detection_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    const LyricsApp(),
  );
}

class LyricsApp
    extends StatelessWidget {
  const LyricsApp({
    super.key,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      title: 'Lyrics',
      debugShowCheckedModeBanner:
          false,
      theme: ThemeData(
        brightness:
            Brightness.dark,
        useMaterial3: true,
      ),
      home:
          const SongDetectionScreen(),
    );
  }
}